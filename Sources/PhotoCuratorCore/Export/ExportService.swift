import Foundation
import GRDB

/// What a single successful export-plan item changed — enough for undo to reverse
/// it (and redo to reapply it) without re-deriving anything.
public enum ExportUndoRecord: Sendable {
    /// `replacedStaleRecords` were already deleted by the time this photo's fresh
    /// copy was logged — captured so undo can bring them back exactly, alongside
    /// deleting the new record and trashing the new file.
    case exported(newRecord: ExportRecord, newFileURL: URL, replacedStaleRecords: [ExportRecord])
    case renamed(photoId: Int64, category: String, oldFileURL: URL, newFileURL: URL, oldDestinationPath: String, newDestinationPath: String)
    case removed(deletedRecord: ExportRecord, trashedFileURL: URL?)
}

public struct ExportItemResult: Sendable {
    public var photoId: Int64
    public var success: Bool
    public var skippedAsDuplicate: Bool
    public var wasRemoved: Bool
    public var wasRenamed: Bool
    public var errorDescription: String?
    public var undoInfo: ExportUndoRecord?

    public init(
        photoId: Int64, success: Bool, skippedAsDuplicate: Bool, wasRemoved: Bool = false, wasRenamed: Bool = false,
        errorDescription: String?, undoInfo: ExportUndoRecord? = nil
    ) {
        self.photoId = photoId
        self.success = success
        self.skippedAsDuplicate = skippedAsDuplicate
        self.wasRemoved = wasRemoved
        self.wasRenamed = wasRenamed
        self.errorDescription = errorDescription
        self.undoInfo = undoInfo
    }
}

/// One planned action for a single photo in an album export — computed by
/// `planAlbumExport`, shown to the user for confirmation, then carried out by
/// `applyAlbumExportPlan`.
public struct AlbumExportPlan: Sendable {
    public struct Item: Sendable {
        public var photoId: Int64
        public var filename: String

        public init(photoId: Int64, filename: String) {
            self.photoId = photoId
            self.filename = filename
        }
    }

    /// A photo that's already exported under `oldFilename` but whose position in
    /// the album has since changed, so its export needs to be renamed in place to
    /// `newFilename` rather than re-exported or left stale.
    public struct RenameItem: Sendable {
        public var photoId: Int64
        public var oldFilename: String
        public var newFilename: String

        public init(photoId: Int64, oldFilename: String, newFilename: String) {
            self.photoId = photoId
            self.oldFilename = oldFilename
            self.newFilename = newFilename
        }
    }

    public var toExport: [Item]
    public var toRename: [RenameItem]
    public var toSkip: [Item]
    public var toRemove: [Item]

    public init(toExport: [Item] = [], toRename: [RenameItem] = [], toSkip: [Item] = [], toRemove: [Item] = []) {
        self.toExport = toExport
        self.toRename = toRename
        self.toSkip = toSkip
        self.toRemove = toRemove
    }
}

/// Export / publish (spec §7.6): copies the JPG representation of an album's
/// currently-accepted photos into a per-album subdirectory of the gallery target —
/// and, symmetrically, removes anything there whose photo is no longer accepted (or
/// no longer even in the album), so the export folder always mirrors the album's
/// *current* accepted set rather than everything ever exported. This never touches
/// `lifecycleState`: "is this exported" lives entirely in the `exports` log,
/// independent of whatever review verdict a photo currently carries.
///
/// Exported files are named `{category}-{position}.jpg`, `position` being 1-based
/// and reflecting each photo's order among the album's *other currently-accepted*
/// photos (not raw album position, so gaps from candidate/rejected photos don't
/// show up in the numbering) — never the original filename, both because two
/// cameras can produce colliding names and because the number is meant to convey
/// the curated order. Reordering the album and re-exporting renames the affected
/// files in place rather than re-copying them.
public actor ExportService {
    private let database: AppDatabase
    private let derivationQueue: DerivationQueue

    public init(database: AppDatabase, derivationQueue: DerivationQueue) {
        self.database = database
        self.derivationQueue = derivationQueue
    }

    /// Dry run: buckets an album's photos into what a subsequent
    /// `applyAlbumExportPlan` call would export/rename/skip/remove, without
    /// touching disk or the database. `category` is always the album's current name.
    public func planAlbumExport(albumId: Int64, category: String, exportFolderURL: URL) async -> AlbumExportPlan {
        do {
            let photos = try await database.read { db in try AlbumRepository.photos(albumId: albumId, in: db) }
            let existingExports = try await database.read { db in try ExportRepository.fetchAll(category: category, in: db) }
            // Built with a loop rather than `uniqueKeysWithValues:` since a photo
            // could in principle have more than one lingering record under the
            // same category (e.g. from a bug in an earlier version) — first one
            // wins rather than crashing on the duplicate key.
            var existingByPhotoId: [Int64: ExportRecord] = [:]
            for record in existingExports where existingByPhotoId[record.photoId] == nil {
                existingByPhotoId[record.photoId] = record
            }
            let categoryDirectory = exportFolderURL.appendingPathComponent(category, isDirectory: true)

            var toExport: [AlbumExportPlan.Item] = []
            var toRename: [AlbumExportPlan.RenameItem] = []
            var toSkip: [AlbumExportPlan.Item] = []
            // Keyed only by currently-accepted members — anything exported whose
            // photo isn't in here (not accepted anymore, or no longer in the album
            // at all) belongs in `toRemove` below.
            var acceptedPhotoIds: Set<Int64> = []

            var position = 0
            for pwr in photos where pwr.photo.lifecycleState == .accepted {
                guard let photoId = pwr.photo.id, let jpg = pwr.jpg else { continue }
                position += 1
                acceptedPhotoIds.insert(photoId)
                let expectedFilename = "\(category)-\(position).jpg"

                // Recognized purely from the filesystem, independent of the log —
                // covers a fresh install (or a lost/cleared log) where the exported
                // files are still sitting at their correct, already-current names.
                if Self.fileMatchesSize(filename: expectedFilename, expectedSize: jpg.fileSize, in: categoryDirectory) {
                    toSkip.append(.init(photoId: photoId, filename: expectedFilename))
                    continue
                }

                if let existing = existingByPhotoId[photoId] {
                    let existingFilename = (existing.destinationPath as NSString).lastPathComponent
                    if existingFilename != expectedFilename,
                       FileManager.default.fileExists(atPath: categoryDirectory.appendingPathComponent(existingFilename).path) {
                        toRename.append(.init(photoId: photoId, oldFilename: existingFilename, newFilename: expectedFilename))
                        continue
                    }
                }

                toExport.append(.init(photoId: photoId, filename: expectedFilename))
            }

            var toRemove: [AlbumExportPlan.Item] = []
            for record in existingExports where !acceptedPhotoIds.contains(record.photoId) {
                let filename = (record.destinationPath as NSString).lastPathComponent
                toRemove.append(.init(photoId: record.photoId, filename: filename))
            }

            return AlbumExportPlan(toExport: toExport, toRename: toRename, toSkip: toSkip, toRemove: toRemove)
        } catch {
            return AlbumExportPlan()
        }
    }

    /// Carries out a plan from `planAlbumExport` — copies `toExport`, renames
    /// `toRename` in place, deletes `toRemove`'s files and log rows, and leaves
    /// `toSkip` untouched.
    @discardableResult
    public func applyAlbumExportPlan(
        _ plan: AlbumExportPlan,
        category: String,
        exportFolderURL: URL,
        libraryRootURL: @Sendable (Int64) -> URL?
    ) async -> [ExportItemResult] {
        var results: [ExportItemResult] = []

        for item in plan.toExport {
            results.append(await exportOnePhoto(
                photoId: item.photoId, filename: item.filename, category: category,
                exportFolderURL: exportFolderURL, libraryRootURL: libraryRootURL
            ))
        }
        results.append(contentsOf: await renameExportedPhotos(plan.toRename, category: category, exportFolderURL: exportFolderURL))
        for item in plan.toRemove {
            results.append(await removeExportedPhoto(photoId: item.photoId, category: category, exportFolderURL: exportFolderURL))
        }

        return results
    }

    private func exportOnePhoto(
        photoId: Int64,
        filename: String,
        category: String,
        exportFolderURL: URL,
        libraryRootURL: @Sendable (Int64) -> URL?
    ) async -> ExportItemResult {
        do {
            guard let jpg = try await database.read({ db in
                try PhotoRepository.fetchPhotoWithRepresentations(id: photoId, in: db)?.jpg
            }) else {
                return ExportItemResult(
                    photoId: photoId, success: false, skippedAsDuplicate: false,
                    errorDescription: "This photo has no JPG representation to export (RAW-only, v1 exports JPG)"
                )
            }
            guard let representationId = jpg.id else {
                return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: "Missing representation id")
            }
            guard let photoLibraryRootURL = libraryRootURL(jpg.libraryId) else {
                return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: "This photo's library is no longer accessible")
            }

            let categoryDirectory = exportFolderURL.appendingPathComponent(category, isDirectory: true)
            try FileManager.default.createDirectory(at: categoryDirectory, withIntermediateDirectories: true)

            // Checked before anything else — cheap, and avoids materializing an
            // online-only JPG (a real download, spec §2/§7.3) just to find out the
            // destination already has this exact file. `planAlbumExport` already
            // checked this to decide toExport-vs-toSkip, but re-checking here keeps
            // this function safe to call on its own and covers the race where the
            // plan is stale by the time it's applied.
            if Self.fileMatchesSize(filename: filename, expectedSize: jpg.fileSize, in: categoryDirectory) {
                return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: true, errorDescription: nil)
            }

            var contentHash = jpg.contentHash
            if !jpg.isLocal || contentHash == nil {
                // Exporting is the user explicitly acting on this file, so it's safe
                // to materialize an online-only JPG on demand here (spec §2, §7.3).
                contentHash = try await derivationQueue.deriveOnDemand(representation: jpg, photoRoot: photoLibraryRootURL)
            }
            guard let contentHash else {
                return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: "Could not materialize JPG for export")
            }

            let sourceURL = jpg.fileURL(photoRoot: photoLibraryRootURL)
            // The destination name is deterministic (derived from this photo's
            // position, not its original filename), so unlike a plain filename
            // copy there's no cross-photo collision to disambiguate — any file
            // already occupying this exact slot belongs to a stale export of this
            // same position and is meant to be replaced.
            let destinationURL = categoryDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let now = Int64(Date().timeIntervalSince1970)
            let relativeDestination = destinationURL.relativePath(from: exportFolderURL)

            let (newRecord, staleRecords) = try await database.write { db -> (ExportRecord, [ExportRecord]) in
                // A prior export record for this photo/category (e.g. one whose
                // file went missing and got re-planned as toExport rather than
                // toRename) must be replaced, not duplicated. Captured before
                // deleting so undo can bring them back.
                let staleRecords = try ExportRecord
                    .filter(ExportRecord.Columns.photoId == photoId && ExportRecord.Columns.category == category)
                    .fetchAll(db)
                for record in staleRecords {
                    guard let id = record.id else { continue }
                    try ExportRepository.deleteExport(id: id, in: db)
                }
                let logged = try ExportRepository.logExport(
                    ExportRecord(
                        photoId: photoId,
                        representationId: representationId,
                        contentHash: contentHash,
                        category: category,
                        destinationPath: relativeDestination,
                        exportedAt: now
                    ),
                    in: db
                )
                return (logged, staleRecords)
            }

            let undoInfo = ExportUndoRecord.exported(
                newRecord: newRecord, newFileURL: destinationURL, replacedStaleRecords: staleRecords
            )
            return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: false, errorDescription: nil, undoInfo: undoInfo)
        } catch {
            return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription)
        }
    }

    /// Renames a batch of already-exported files to reflect new album positions.
    /// Done in two passes — every source is first moved to a unique staging name,
    /// then every staged file is moved to its final destination — because two
    /// photos can swap positions in the same plan (A's new name is B's old name
    /// and vice versa); renaming them one at a time in a single pass would have
    /// the second rename clobber the first's not-yet-processed source file.
    private func renameExportedPhotos(
        _ items: [AlbumExportPlan.RenameItem],
        category: String,
        exportFolderURL: URL
    ) async -> [ExportItemResult] {
        guard !items.isEmpty else { return [] }
        let categoryDirectory = exportFolderURL.appendingPathComponent(category, isDirectory: true)
        var results: [ExportItemResult] = []
        var staged: [(item: AlbumExportPlan.RenameItem, stagingURL: URL)] = []

        for item in items {
            let oldURL = categoryDirectory.appendingPathComponent(item.oldFilename)
            guard FileManager.default.fileExists(atPath: oldURL.path) else {
                results.append(ExportItemResult(photoId: item.photoId, success: false, skippedAsDuplicate: false, errorDescription: "\(item.oldFilename) is missing, can't rename it"))
                continue
            }
            let stagingURL = categoryDirectory.appendingPathComponent(".export-rename-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: oldURL, to: stagingURL)
                staged.append((item, stagingURL))
            } catch {
                results.append(ExportItemResult(photoId: item.photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription))
            }
        }

        for (item, stagingURL) in staged {
            do {
                let newURL = categoryDirectory.appendingPathComponent(item.newFilename)
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: stagingURL, to: newURL)

                let oldDestinationPath = "\(category)/\(item.oldFilename)"
                let newDestinationPath = newURL.relativePath(from: exportFolderURL)
                try await database.write { db in
                    guard var record = try ExportRecord
                        .filter(ExportRecord.Columns.photoId == item.photoId && ExportRecord.Columns.category == category)
                        .fetchOne(db) else { return }
                    record.destinationPath = newDestinationPath
                    try record.update(db)
                }
                let undoInfo = ExportUndoRecord.renamed(
                    photoId: item.photoId, category: category,
                    oldFileURL: categoryDirectory.appendingPathComponent(item.oldFilename),
                    newFileURL: newURL,
                    oldDestinationPath: oldDestinationPath, newDestinationPath: newDestinationPath
                )
                results.append(ExportItemResult(photoId: item.photoId, success: true, skippedAsDuplicate: false, wasRenamed: true, errorDescription: nil, undoInfo: undoInfo))
            } catch {
                results.append(ExportItemResult(photoId: item.photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription))
            }
        }

        return results
    }

    private func removeExportedPhoto(photoId: Int64, category: String, exportFolderURL: URL) async -> ExportItemResult {
        do {
            // Normally exactly one record; if more than one somehow exist for this
            // photo/category (see `planAlbumExport`'s own first-wins comment about
            // this edge case), the last one deleted is what undo captures — losing
            // undo for an earlier duplicate here is an acceptable simplification for
            // a case that shouldn't occur outside a bug in an older version.
            let lastDeleted = try await database.write { db -> (record: ExportRecord, trashedFileURL: URL?)? in
                let records = try ExportRepository.fetchAll(category: category, in: db).filter { $0.photoId == photoId }
                var lastDeleted: (record: ExportRecord, trashedFileURL: URL?)?
                for record in records {
                    guard let id = record.id else { continue }
                    if let deleted = try ExportRepository.deleteExportAndFile(id: id, exportFolderURL: exportFolderURL, in: db) {
                        lastDeleted = deleted
                    }
                }
                return lastDeleted
            }
            let undoInfo = lastDeleted.map { ExportUndoRecord.removed(deletedRecord: $0.record, trashedFileURL: $0.trashedFileURL) }
            return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: false, wasRemoved: true, errorDescription: nil, undoInfo: undoInfo)
        } catch {
            return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription)
        }
    }

    private static func fileMatchesSize(filename: String, expectedSize: Int64?, in categoryDirectory: URL) -> Bool {
        guard let expectedSize else { return false }
        let expectedDestination = categoryDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: expectedDestination.path) else { return false }
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: expectedDestination.path))?[.size] as? Int64
        return existingSize == expectedSize
    }

    // MARK: Undo/redo of a prior apply

    /// Reverses a batch of `ExportItemResult.undoInfo` records from a prior
    /// `applyAlbumExportPlan` call: trashes what it exported (restoring any records
    /// it had replaced), restores what it removed, and moves back what it renamed —
    /// renames go through the same staged two-pass `renameExportedPhotos` machinery
    /// as the forward direction, so a batch containing a position swap doesn't
    /// clobber itself. Returns where each trashed file landed (keyed by the record's
    /// index in `records`), for a later `redoExport` call to restore from.
    ///
    /// Each record's captured URLs were computed against the export folder at the
    /// time of the original action — if the export target has since changed, undoing
    /// an old action will still look for its file at the old location. A narrow,
    /// accepted edge case for a session-scoped undo history, not worth guarding.
    public func undoExport(
        _ records: [ExportUndoRecord], category: String, exportFolderURL: URL
    ) async -> (results: [ExportItemResult], trashedURLs: [Int: URL]) {
        var results: [ExportItemResult] = []
        var trashedURLs: [Int: URL] = [:]
        var reverseRenames: [AlbumExportPlan.RenameItem] = []

        for (index, record) in records.enumerated() {
            switch record {
            case .exported(let newRecord, let newFileURL, let replacedStaleRecords):
                if let trashedURL = try? TrashDisposal.moveToTrash(newFileURL) {
                    trashedURLs[index] = trashedURL
                }
                _ = try? await database.write { db in
                    if let id = newRecord.id { try ExportRepository.deleteExport(id: id, in: db) }
                    for var stale in replacedStaleRecords { try stale.insert(db) }
                }
                results.append(ExportItemResult(photoId: newRecord.photoId, success: true, skippedAsDuplicate: false, errorDescription: nil))

            case .renamed(let photoId, _, _, _, let oldDestinationPath, let newDestinationPath):
                reverseRenames.append(.init(
                    photoId: photoId,
                    oldFilename: (newDestinationPath as NSString).lastPathComponent,
                    newFilename: (oldDestinationPath as NSString).lastPathComponent
                ))

            case .removed(let deletedRecord, let trashedFileURL):
                if let trashedFileURL, FileManager.default.fileExists(atPath: trashedFileURL.path) {
                    let destinationURL = exportFolderURL.appendingPathComponent(deletedRecord.destinationPath)
                    try? TrashDisposal.restore(from: trashedFileURL, to: destinationURL)
                }
                _ = try? await database.write { db in
                    var record = deletedRecord
                    try record.insert(db)
                }
                results.append(ExportItemResult(photoId: deletedRecord.photoId, success: true, skippedAsDuplicate: false, errorDescription: nil))
            }
        }
        if !reverseRenames.isEmpty {
            results.append(contentsOf: await renameExportedPhotos(reverseRenames, category: category, exportFolderURL: exportFolderURL))
        }
        return (results, trashedURLs)
    }

    /// Reapplies a batch previously reversed by `undoExport` — restores each trashed
    /// file from where `trashedURLs` says it landed, reinserts the log rows,
    /// re-removes whatever `undoExport` had restored, and redoes renames the same
    /// staged way. Skips a record's file+row entirely (rather than reinserting a row
    /// pointing at nothing) if its trashed file no longer exists, e.g. the user
    /// emptied Trash mid-session.
    public func redoExport(
        _ records: [ExportUndoRecord], trashedURLs: [Int: URL], category: String, exportFolderURL: URL
    ) async -> [ExportItemResult] {
        var results: [ExportItemResult] = []
        var forwardRenames: [AlbumExportPlan.RenameItem] = []

        for (index, record) in records.enumerated() {
            switch record {
            case .exported(let newRecord, let newFileURL, let replacedStaleRecords):
                guard let trashedURL = trashedURLs[index], FileManager.default.fileExists(atPath: trashedURL.path) else { continue }
                guard (try? TrashDisposal.restore(from: trashedURL, to: newFileURL)) != nil else { continue }
                _ = try? await database.write { db in
                    for stale in replacedStaleRecords {
                        guard let id = stale.id else { continue }
                        try ExportRepository.deleteExport(id: id, in: db)
                    }
                    var record = newRecord
                    try record.insert(db)
                }
                results.append(ExportItemResult(photoId: newRecord.photoId, success: true, skippedAsDuplicate: false, errorDescription: nil))

            case .renamed(let photoId, _, _, _, let oldDestinationPath, let newDestinationPath):
                forwardRenames.append(.init(
                    photoId: photoId,
                    oldFilename: (oldDestinationPath as NSString).lastPathComponent,
                    newFilename: (newDestinationPath as NSString).lastPathComponent
                ))

            case .removed(let deletedRecord, _):
                // Re-trashing produces a fresh Trash location — it doesn't need to
                // match wherever undo's restore came from, only to remove the row
                // undo had just brought back.
                guard let id = deletedRecord.id else { continue }
                _ = try? await database.write { db in
                    try ExportRepository.deleteExportAndFile(id: id, exportFolderURL: exportFolderURL, in: db)
                }
                results.append(ExportItemResult(photoId: deletedRecord.photoId, success: true, skippedAsDuplicate: false, wasRemoved: true, errorDescription: nil))
            }
        }
        if !forwardRenames.isEmpty {
            results.append(contentsOf: await renameExportedPhotos(forwardRenames, category: category, exportFolderURL: exportFolderURL))
        }
        return results
    }
}
