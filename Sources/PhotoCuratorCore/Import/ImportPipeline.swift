import Foundation
import GRDB

public struct ImportCandidateFile: Sendable, Equatable {
    public var sourceURL: URL
    public var kind: RepresentationKind
    public var filename: String
    public var fileSize: Int64?
    public var fileMtime: Int64?
    public var isAlreadyImported: Bool
}

/// One shot, grouped by basename, so a RAW+JPG pair is reviewed and filed together —
/// they must land in the same per-camera subdirectory or they'd split into two
/// Photos (spec §4).
public struct ImportGroup: Sendable, Equatable, Identifiable {
    public var basename: String
    public var files: [ImportCandidateFile]
    public var suggestedSubdirectory: String

    public var id: String { basename }
    public var isFullyDuplicate: Bool { !files.isEmpty && files.allSatisfy(\.isAlreadyImported) }
    public var newFileCount: Int { files.filter { !$0.isAlreadyImported }.count }
}

public struct ImportFileOutcome: Sendable {
    public var sourceURL: URL
    public var success: Bool
    public var skippedAsDuplicate: Bool
    public var errorDescription: String?
    /// Populated only when `success && !skippedAsDuplicate` — the file and row this
    /// import actually created, for undo to reverse.
    public var undoInfo: ImportUndoRecord?

    public init(sourceURL: URL, success: Bool, skippedAsDuplicate: Bool, errorDescription: String?, undoInfo: ImportUndoRecord? = nil) {
        self.sourceURL = sourceURL
        self.success = success
        self.skippedAsDuplicate = skippedAsDuplicate
        self.errorDescription = errorDescription
        self.undoInfo = undoInfo
    }
}

/// What a single successful, non-duplicate import created — enough for undo to
/// trash the file and remove the row(s), and for redo to bring both back.
///
/// Deliberately doesn't record whether *this call* created the shared `photos` row
/// (a RAW+JPG pair can share one) — whether a photo row needs deleting is instead
/// resolved dynamically at undo time via `PhotoRepository.deletePhotoIfEmpty`'s own
/// remaining-representations check, since with a same-batch sibling, either side's
/// undo could end up being the one that actually empties it, not necessarily
/// whichever side created it.
public struct ImportUndoRecord: Sendable {
    public var representation: Representation
    public var destinationFileURL: URL

    public init(representation: Representation, destinationFileURL: URL) {
        self.representation = representation
        self.destinationFileURL = destinationFileURL
    }
}

enum ImportFileError: Error, LocalizedError {
    case checksumMismatch
    case destinationOccupied
    case missingPhotoId

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: return "Checksum mismatch after copy"
        case .destinationOccupied: return "A different file already exists at the destination"
        case .missingPhotoId: return "Could not create a database row for this photo"
        }
    }
}

/// SD-card import (spec §7.2): copy → verify → derive → place, per file, so a crash
/// or card ejection mid-batch never leaves a half-imported file visible to the rest
/// of the app — and re-running the same import is safe, since already-committed
/// files are skipped by dedup.
public actor ImportPipeline {
    private let database: AppDatabase
    private let derivationService: DerivationService

    public init(database: AppDatabase, derivationService: DerivationService) {
        self.database = database
        self.derivationService = derivationService
    }

    /// Scans a source folder (typically a mounted SD card) for candidate photo files
    /// and flags ones already known to the database by provisional key (spec §7.2
    /// step 2). Enumeration plus metadata-only EXIF reads — SD cards are local
    /// removable media, so this carries none of the Proton "mass download" risk, but
    /// we still avoid decoding full pixel data just to suggest a subdirectory.
    ///
    /// `targetLibraryId` decides the *default* per-group subdirectory suggestion: if
    /// that library already has photos sitting directly in its root, new imports
    /// default to landing there too (flat) rather than guessing an EXIF-camera-model
    /// subdirectory — importing into a folder that's already organized flat shouldn't
    /// start nesting new subdirectories into it. Either way, still overridable per
    /// group by the caller via `importGroups(chosenSubdirectories:)`.
    public func scan(sourceFolder: URL, targetLibraryId: Int64) async throws -> [ImportGroup] {
        let files = try DirectoryEnumerator.enumerateFiles(under: sourceFolder)
        let preferFlatImport = try await database.read { db in
            try PhotoRepository.libraryHasRootLevelPhotos(libraryId: targetLibraryId, in: db)
        }

        // Deliberately drops mtime from this match (unlike `ProvisionalKey`'s
        // other use in `ReconciliationPlanner`, which keeps it — a stricter
        // match makes sense there since a full content-hash rescue is always
        // available as a backup for local files). Here, the library-side
        // counterpart may be online-only and therefore has no content hash on
        // record at all (`DerivationService` only ever hashes local files), so
        // filename+size — the two fields least likely to drift between the SD
        // card's copy and a library copy that arrived by some other route
        // (e.g. a cloud upload/sync that didn't preserve capture-time mtime) —
        // is the most reliable signal available without downloading anything.
        // A same-name, same-byte-size *different* photo is not a realistic risk
        // for camera-originated RAW/JPEG output.
        //
        // Scoped to the destination library, matching how reconciliation treats
        // two registered roots (see `ReconciliationService.applyNewFile`): a copy
        // living under a *different* root is a separate real file with its own row,
        // so its presence there says nothing about whether this library already has
        // this shot. Matching globally made importing a card into a second library
        // silently report every file as "already imported".
        let knownProvisionalKeys = try await database.read { db -> Set<ProvisionalKey> in
            let all = try Representation
                .filter(Representation.Columns.libraryId == targetLibraryId)
                .fetchAll(db)
            return Set(all.map { ProvisionalKey(filename: $0.filename, fileSize: $0.fileSize, fileMtime: nil) })
        }

        var groups: [String: [ImportCandidateFile]] = [:]
        var order: [String] = []

        for file in files {
            guard let kind = RepresentationFileType.kind(forExtension: file.fileExtension) else { continue }
            let basename = ReconciliationPlanner.basename(for: file.filename)
            let provisional = ProvisionalKey(filename: file.filename, fileSize: file.fileSize, fileMtime: nil)
            let candidate = ImportCandidateFile(
                sourceURL: file.url,
                kind: kind,
                filename: file.filename,
                fileSize: file.fileSize,
                fileMtime: file.fileMtimeEpoch,
                isAlreadyImported: knownProvisionalKeys.contains(provisional)
            )
            if groups[basename] == nil {
                order.append(basename)
            }
            groups[basename, default: []].append(candidate)
        }

        return order.map { basename in
            let files = groups[basename] ?? []
            let suggestedSubdirectory: String
            if preferFlatImport {
                suggestedSubdirectory = ""
            } else {
                let representative = files.first { !$0.isAlreadyImported } ?? files.first
                var cameraModel: String?
                if let representative, let exif = try? ExifExtractor.extract(from: representative.sourceURL) {
                    cameraModel = exif.cameraModel
                }
                suggestedSubdirectory = CameraSubdirectoryNaming.suggestedSubdirectory(cameraModel: cameraModel)
            }
            return ImportGroup(basename: basename, files: files, suggestedSubdirectory: suggestedSubdirectory)
        }
    }

    /// Runs the full pipeline for every non-duplicate file in `groups`, filing each
    /// basename group into `chosenSubdirectories[basename]` (falling back to the
    /// group's own EXIF-derived suggestion). Files are processed with bounded
    /// concurrency; each one only ever reaches the database after its bytes are
    /// verified and safely renamed into place at their final path.
    public func importGroups(
        _ groups: [ImportGroup],
        chosenSubdirectories: [String: String] = [:],
        targetLibraryId: Int64,
        protonFolderURL: URL,
        maxConcurrent: Int = 3,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [ImportFileOutcome] {
        let allFiles: [(basename: String, file: ImportCandidateFile, subdirectory: String)] = groups.flatMap { group in
            let subdirectory = chosenSubdirectories[group.basename] ?? group.suggestedSubdirectory
            return group.files.filter { !$0.isAlreadyImported }.map { (group.basename, $0, subdirectory) }
        }
        let total = allFiles.count
        guard total > 0 else { return [] }

        var outcomes: [ImportFileOutcome] = []
        outcomes.reserveCapacity(total)
        var processed = 0

        await withTaskGroup(of: ImportFileOutcome.self) { group in
            var iterator = allFiles.makeIterator()

            func startNext() {
                guard let entry = iterator.next() else { return }
                group.addTask {
                    await self.importOneFile(
                        basename: entry.basename,
                        file: entry.file,
                        subdirectory: entry.subdirectory,
                        targetLibraryId: targetLibraryId,
                        protonFolderURL: protonFolderURL
                    )
                }
            }

            for _ in 0..<max(1, maxConcurrent) { startNext() }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                processed += 1
                onProgress?(processed, total)
                startNext()
            }
        }

        return outcomes
    }

    /// Not actor-isolated on purpose: the heavy work here (file copy, two full-file
    /// hash reads, thumbnail generation) has no shared mutable state to protect, so
    /// letting several of these run truly in parallel is what makes `maxConcurrent`
    /// in `importGroups` meaningful. The only shared resource, `database`, is already
    /// safely serialized by GRDB's single writer.
    nonisolated private func importOneFile(
        basename: String,
        file: ImportCandidateFile,
        subdirectory: String,
        targetLibraryId: Int64,
        protonFolderURL: URL
    ) async -> ImportFileOutcome {
        let fileManager = FileManager.default
        let targetDirectory = protonFolderURL.appendingPathComponent(subdirectory, isDirectory: true)
        let finalURL = targetDirectory.appendingPathComponent(file.filename)
        let tempURL = targetDirectory.appendingPathComponent(".importing-\(UUID().uuidString)-\(file.filename)")

        do {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

            // Never overwrite something already at the destination name.
            guard !fileManager.fileExists(atPath: finalURL.path) else {
                throw ImportFileError.destinationOccupied
            }

            // Copy and verify on a dedicated queue: this is blocking file I/O plus
            // two full passes of SHA-256, and `maxConcurrent` of them running on the
            // cooperative pool would occupy most of its threads and stall unrelated
            // `await`s across the app.
            let sourceURL = file.sourceURL
            let sourceHash = try await BackgroundWork.run { () throws -> String in
                // One pass, not two: the source is hashed as its bytes stream into
                // the copy, instead of copying and then re-reading the whole file
                // just to digest it. The destination is still read back and hashed
                // independently — that comparison is the actual copy verification
                // (spec §7.2), so it has to see what really landed on disk.
                let hash = try ContentHasher.copy(from: sourceURL, to: tempURL)
                guard try ContentHasher.sha256(ofFileAt: tempURL) == hash else {
                    throw ImportFileError.checksumMismatch
                }
                return hash
            }

            // `ContentHasher.copy` writes bytes only — unlike `FileManager.copyItem`
            // it doesn't carry the source's attributes over, and mtime is what seeds
            // the provisional capture date below until EXIF derivation backfills the
            // real one.
            if let mtime = file.fileMtime {
                try? fileManager.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))],
                    ofItemAtPath: tempURL.path
                )
            }

            // Scoped to the destination library, for the same reason the scan's
            // provisional-key check above is.
            if try await database.read({ db in
                try PhotoRepository.findRepresentation(contentHash: sourceHash, libraryId: targetLibraryId, in: db)
            }) != nil {
                // Byte-identical to a file already in this library under a different
                // name/location — don't duplicate the original on disk either.
                try? fileManager.removeItem(at: tempURL)
                return ImportFileOutcome(sourceURL: file.sourceURL, success: true, skippedAsDuplicate: true, errorDescription: nil)
            }

            try fileManager.moveItem(at: tempURL, to: finalURL)

            let relativePath = finalURL.relativePath(from: protonFolderURL)
            let attributes = try? fileManager.attributesOfItem(atPath: finalURL.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            let mtime = (attributes?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }

            let representationId = try await database.write { db -> Int64 in
                let now = Int64(Date().timeIntervalSince1970)
                let photo = try PhotoRepository.upsertPhoto(
                    libraryId: targetLibraryId,
                    basename: basename,
                    sourceDir: subdirectory,
                    // Provisional sort key until EXIF derivation backfills the real
                    // DateTimeOriginal — see ReconciliationService for the same pattern.
                    captureDate: mtime,
                    now: now,
                    in: db
                )
                guard let photoId = photo.id else { throw ImportFileError.missingPhotoId }
                let rep = Representation(
                    libraryId: targetLibraryId,
                    photoId: photoId,
                    kind: file.kind,
                    relativePath: relativePath,
                    filename: file.filename,
                    fileSize: fileSize,
                    fileMtime: mtime,
                    contentHash: sourceHash,
                    isLocal: true,
                    derivationState: .underived,
                    indexedAt: now
                )
                let inserted = try PhotoRepository.insertRepresentation(rep, in: db)
                guard let repId = inserted.id else { throw ImportFileError.missingPhotoId }
                return repId
            }

            let insertedRepresentation = try await database.read { db in
                try Representation.fetchOne(db, key: representationId)
            }

            _ = try? await derivationService.derive(
                representationId: representationId,
                fileURL: finalURL,
                kind: file.kind,
                knownContentHash: sourceHash
            )

            let undoInfo = insertedRepresentation.map {
                ImportUndoRecord(representation: $0, destinationFileURL: finalURL)
            }
            return ImportFileOutcome(sourceURL: file.sourceURL, success: true, skippedAsDuplicate: false, errorDescription: nil, undoInfo: undoInfo)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return ImportFileOutcome(
                sourceURL: file.sourceURL,
                success: false,
                skippedAsDuplicate: false,
                errorDescription: error.localizedDescription
            )
        }
    }
}
