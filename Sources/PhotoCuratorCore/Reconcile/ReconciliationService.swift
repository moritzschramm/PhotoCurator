import Foundation
import GRDB

public enum ReconciliationError: Error {
    case alreadyRunning
}

/// One registered photo-library root to reconcile against.
public struct LibrarySource: Sendable {
    public var id: Int64
    public var url: URL

    public init(id: Int64, url: URL) {
        self.id = id
        self.url = url
    }
}

/// Startup reconciliation (spec §7.1): enumerates every registered photo library and
/// the export target, diffs each against the database, and reconciles rather than
/// duplicates. Runs off the main thread by construction — every step here is `async`
/// and does its own batched, transactional writes, so it is safe to call from a
/// background `Task`.
public actor ReconciliationService {
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            case enumeratingPhotoLibrary
            case reconcilingPhotoLibrary
            case enumeratingExportTarget
            case reconcilingExportTarget
            case establishingBaseline
            case done
        }
        public var phase: Phase
        public var processed: Int
        public var total: Int

        public init(phase: Phase, processed: Int = 0, total: Int = 0) {
            self.phase = phase
            self.processed = processed
            self.total = total
        }
    }

    private let database: AppDatabase
    private var isRunning = false

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Reconciles every entry in `photoLibraries` in turn (each fully isolated by its
    /// own `libraryId`, so two libraries never cross-match each other's files as
    /// "moved"), then the single export target once, then establishes the baseline
    /// once total — not once per library.
    public func reconcile(
        photoLibraries: [LibrarySource],
        exportFolder: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        guard !isRunning else { throw ReconciliationError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        for library in photoLibraries {
            onProgress?(Progress(phase: .enumeratingPhotoLibrary))
            let photoFiles = try DirectoryEnumerator.enumerateFiles(under: library.url)

            onProgress?(Progress(phase: .reconcilingPhotoLibrary, total: photoFiles.count))
            try await reconcilePhotoLibrary(photoFiles, libraryId: library.id) { processed in
                onProgress?(Progress(phase: .reconcilingPhotoLibrary, processed: processed, total: photoFiles.count))
            }
        }

        // Retroactively fixes sort order for photos indexed before capture-date
        // seeding existed, or still waiting on EXIF derivation — cheap, so it just
        // runs as part of every reconcile rather than needing a separate migration.
        try await database.write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try PhotoRepository.backfillMissingCaptureDatesFromMtime(now: now, in: db)
        }

        onProgress?(Progress(phase: .enumeratingExportTarget))
        let exportFiles = try DirectoryEnumerator.enumerateFiles(under: exportFolder)

        onProgress?(Progress(phase: .reconcilingExportTarget, total: exportFiles.count))
        try await reconcileExportTarget(exportFiles)

        onProgress?(Progress(phase: .establishingBaseline))
        try await establishBaselineIfNeeded()

        onProgress?(Progress(phase: .done))
    }

    // MARK: Photo library

    private func reconcilePhotoLibrary(_ files: [EnumeratedFile], libraryId: Int64, onBatch: @Sendable (Int) -> Void) async throws {
        let existing = try await database.read { db in
            try Representation.filter(Representation.Columns.libraryId == libraryId).fetchAll(db)
        }
        let plan = ReconciliationPlanner.diff(files: files, existing: existing)

        var processed = 0

        for batch in plan.localStatusChanges.chunked(into: 500) {
            try await database.write { db in
                for change in batch {
                    try PhotoRepository.updateLocalStatus(
                        representationId: change.representationId,
                        isLocal: change.isLocal,
                        in: db
                    )
                }
            }
            processed += batch.count
            onBatch(processed)
        }

        for batch in plan.moved.chunked(into: 200) {
            try await database.write { db in
                let now = Int64(Date().timeIntervalSince1970)
                for move in batch {
                    guard let existingRep = try PhotoRepository.fetchRepresentation(id: move.representationId, in: db) else {
                        continue
                    }
                    try Self.reassignRepresentation(existingRep, libraryId: libraryId, to: move.file, now: now, in: db)
                }
            }
            processed += batch.count
            onBatch(processed)
        }

        var stillMissing = plan.unmatchedExistingIds
        for batch in plan.newFiles.chunked(into: 100) {
            // Each new-file write reports back the id of any existing representation
            // it turned out to be a hash-based rescue for; `stillMissing` is only
            // mutated back here in actor-isolated code, never inside the `@Sendable`
            // write closure itself.
            let rescuedIds = try await database.write { db -> [Int64] in
                let now = Int64(Date().timeIntervalSince1970)
                var rescued: [Int64] = []
                for newFile in batch {
                    if let rescuedId = try Self.applyNewFile(newFile, libraryId: libraryId, now: now, in: db) {
                        rescued.append(rescuedId)
                    }
                }
                return rescued
            }
            for id in rescuedIds {
                stillMissing.remove(id)
            }
            processed += batch.count
            onBatch(processed)
        }

        // Anything never matched by path, provisional key, or (for local new-file
        // candidates) content hash is gone from disk — the app never deletes or moves
        // originals itself, so this only fires when the file genuinely disappeared
        // (e.g. removed outside the app, or renamed while online-only — see planner).
        for batch in Array(stillMissing).chunked(into: 200) {
            try await database.write { db in
                for id in batch {
                    try PhotoRepository.deleteRepresentationCascadingEmptyPhoto(id: id, in: db)
                }
            }
        }
    }

    /// A file that didn't match by path or provisional key. If it's already local, we
    /// can freely hash it (no cloud cost) to catch a rename-and-move that changed both
    /// path and mtime/size bookkeeping (spec §5). Otherwise it's simply new.
    /// Returns the id of an existing representation this file turned out to be a
    /// hash-based rescue for, so the caller can strike it off `stillMissing` — or nil
    /// if this really is a brand new representation.
    @discardableResult
    private static func applyNewFile(
        _ newFile: ReconciliationPlanner.Plan.NewFile,
        libraryId: Int64,
        now: Int64,
        in db: Database
    ) throws -> Int64? {
        var computedHash: String?
        if newFile.file.isLocal {
            computedHash = try? ContentHasher.sha256(ofFileAt: newFile.file.url)
        }

        // Scoped to the library being reconciled. This rescue exists to recognize a
        // file that moved/was renamed *within* one library; matching across
        // libraries instead makes two registered roots that each hold a copy of the
        // same photo fight over the single representation row — each reconcile pass
        // repoints it at whichever library ran last, and `reassignRepresentation`'s
        // `deletePhotoIfEmpty` then drops the photo row the other library was using,
        // cascading away its album membership and resetting its review verdict to
        // `new`. Two copies under two roots are two real files, and each library
        // keeps its own row for its own copy.
        if let hash = computedHash,
           let match = try PhotoRepository.findRepresentation(contentHash: hash, libraryId: libraryId, in: db) {
            try reassignRepresentation(match, libraryId: libraryId, to: newFile.file, now: now, in: db)
            return match.id
        }

        let photo = try PhotoRepository.upsertPhoto(
            libraryId: libraryId,
            basename: newFile.basename,
            sourceDir: newFile.file.sourceDir,
            // Provisional sort key until EXIF derivation backfills the real
            // DateTimeOriginal — mtime is available immediately at index time,
            // EXIF isn't until the (async, potentially slow-for-large-libraries)
            // derivation pass catches up.
            captureDate: newFile.file.fileMtimeEpoch,
            now: now,
            in: db
        )
        guard let photoId = photo.id else { return nil }
        let rep = Representation(
            libraryId: libraryId,
            photoId: photoId,
            kind: newFile.kind,
            relativePath: newFile.file.relativePath,
            filename: newFile.file.filename,
            fileSize: newFile.file.fileSize,
            fileMtime: newFile.file.fileMtimeEpoch,
            contentHash: computedHash,
            isLocal: newFile.file.isLocal,
            derivationState: .underived,
            indexedAt: now
        )
        try PhotoRepository.insertRepresentation(rep, in: db)
        return nil
    }

    /// Repoints an existing representation row at its new location, re-deriving which
    /// Photo it groups under (source dir / basename may have changed), and cleans up
    /// the old Photo if this was its last remaining representation. `libraryId` is the
    /// library currently being reconciled — both the path/provisional-key matches and
    /// the hash rescue in `applyNewFile` are scoped to it, so a representation being
    /// "moved" always stays within the library it already belonged to.
    private static func reassignRepresentation(
        _ existing: Representation,
        libraryId: Int64,
        to file: EnumeratedFile,
        now: Int64,
        in db: Database
    ) throws {
        guard let kind = RepresentationFileType.kind(forExtension: file.fileExtension) else { return }
        let oldPhotoId = existing.photoId
        let photo = try PhotoRepository.upsertPhoto(
            libraryId: libraryId,
            basename: ReconciliationPlanner.basename(for: file.filename),
            sourceDir: file.sourceDir,
            captureDate: file.fileMtimeEpoch,
            now: now,
            in: db
        )
        guard let photoId = photo.id else { return }

        var rep = existing
        rep.libraryId = libraryId
        rep.photoId = photoId
        rep.kind = kind
        rep.relativePath = file.relativePath
        rep.filename = file.filename
        rep.fileSize = file.fileSize
        rep.fileMtime = file.fileMtimeEpoch
        rep.isLocal = file.isLocal
        rep.indexedAt = now
        try PhotoRepository.updateRepresentation(rep, in: db)

        if oldPhotoId != photoId {
            try PhotoRepository.deletePhotoIfEmpty(photoId: oldPhotoId, in: db)
        }
    }

    // MARK: Export target

    /// The export log is never re-hashed against target files (spec §7.6). Reconciling
    /// just means noticing when a previously exported file has disappeared from the
    /// target — e.g. pruned by the external gallery-builder — so it can be exported
    /// again if the user asks.
    private func reconcileExportTarget(_ files: [EnumeratedFile]) async throws {
        let existingExports = try await database.read { db in try ExportRepository.fetchAll(in: db) }
        let presentPaths = Set(files.map(\.relativePath))
        let goneExports = existingExports.filter { !presentPaths.contains($0.destinationPath) }

        for batch in goneExports.chunked(into: 200) {
            try await database.write { db in
                for export in batch {
                    if let id = export.id {
                        try ExportRepository.deleteExport(id: id, in: db)
                    }
                }
            }
        }
    }

    // MARK: Baseline

    private func establishBaselineIfNeeded() async throws {
        let alreadyEstablished = try await database.read { db in
            try AppStateRepository.getBool(AppStateKey.baselineEstablished, in: db)
        }
        guard !alreadyEstablished else { return }
        try await database.write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try PhotoRepository.markAllAsAcceptedBaseline(now: now, in: db)
            try AppStateRepository.setBool(true, forKey: AppStateKey.baselineEstablished, in: db)
        }
    }
}
