import Foundation
import GRDB

public struct ExportItemResult: Sendable {
    public var photoId: Int64
    public var success: Bool
    public var skippedAsDuplicate: Bool
    public var wasRemoved: Bool
    public var errorDescription: String?

    public init(photoId: Int64, success: Bool, skippedAsDuplicate: Bool, wasRemoved: Bool = false, errorDescription: String?) {
        self.photoId = photoId
        self.success = success
        self.skippedAsDuplicate = skippedAsDuplicate
        self.wasRemoved = wasRemoved
        self.errorDescription = errorDescription
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

    public var toExport: [Item]
    public var toSkip: [Item]
    public var toRemove: [Item]

    public init(toExport: [Item] = [], toSkip: [Item] = [], toRemove: [Item] = []) {
        self.toExport = toExport
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
public actor ExportService {
    private let database: AppDatabase
    private let derivationQueue: DerivationQueue

    public init(database: AppDatabase, derivationQueue: DerivationQueue) {
        self.database = database
        self.derivationQueue = derivationQueue
    }

    /// Dry run: buckets an album's photos into what a subsequent
    /// `applyAlbumExportPlan` call would export/skip/remove, without touching disk
    /// or the database. `category` is always the album's current name.
    public func planAlbumExport(albumId: Int64, category: String, exportFolderURL: URL) async -> AlbumExportPlan {
        do {
            let photos = try await database.read { db in try AlbumRepository.photos(albumId: albumId, in: db) }
            let existingExports = try await database.read { db in try ExportRepository.fetchAll(category: category, in: db) }
            let categoryDirectory = exportFolderURL.appendingPathComponent(category, isDirectory: true)

            var toExport: [AlbumExportPlan.Item] = []
            var toSkip: [AlbumExportPlan.Item] = []
            // Keyed only by currently-accepted members — anything exported whose
            // photo isn't in here (not accepted anymore, or no longer in the album
            // at all) belongs in `toRemove` below.
            var acceptedFilenameById: [Int64: String] = [:]

            for pwr in photos where pwr.photo.lifecycleState == .accepted {
                guard let photoId = pwr.photo.id, let jpg = pwr.jpg else { continue }
                acceptedFilenameById[photoId] = jpg.filename
                let item = AlbumExportPlan.Item(photoId: photoId, filename: jpg.filename)
                if Self.destinationLooksUpToDate(jpg: jpg, in: categoryDirectory) {
                    toSkip.append(item)
                } else {
                    toExport.append(item)
                }
            }

            var toRemove: [AlbumExportPlan.Item] = []
            for record in existingExports where acceptedFilenameById[record.photoId] == nil {
                let filename = (record.destinationPath as NSString).lastPathComponent
                toRemove.append(.init(photoId: record.photoId, filename: filename))
            }

            return AlbumExportPlan(toExport: toExport, toSkip: toSkip, toRemove: toRemove)
        } catch {
            return AlbumExportPlan()
        }
    }

    /// Carries out a plan from `planAlbumExport` — copies `toExport`, deletes
    /// `toRemove`'s files and log rows, and leaves `toSkip` untouched.
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
                photoId: item.photoId, category: category, exportFolderURL: exportFolderURL, libraryRootURL: libraryRootURL
            ))
        }
        for item in plan.toRemove {
            results.append(await removeExportedPhoto(photoId: item.photoId, category: category, exportFolderURL: exportFolderURL))
        }

        return results
    }

    private func exportOnePhoto(
        photoId: Int64,
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
            if Self.destinationLooksUpToDate(jpg: jpg, in: categoryDirectory) {
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

            // Secondary check: same bytes already logged under this category but
            // under a different filename (e.g. the photo was renamed in the
            // library since a previous export) — still shouldn't produce a
            // redundant second copy.
            let alreadyExported = try await database.read { db in
                try ExportRepository.alreadyExported(contentHash: contentHash, category: category, in: db)
            }
            if alreadyExported {
                return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: true, errorDescription: nil)
            }

            let sourceURL = jpg.fileURL(photoRoot: photoLibraryRootURL)
            let destinationURL = try Self.uniqueDestination(for: jpg.filename, in: categoryDirectory)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let now = Int64(Date().timeIntervalSince1970)
            let relativeDestination = destinationURL.relativePath(from: exportFolderURL)

            try await database.write { db in
                try ExportRepository.logExport(
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
            }

            return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: false, errorDescription: nil)
        } catch {
            return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription)
        }
    }

    private func removeExportedPhoto(photoId: Int64, category: String, exportFolderURL: URL) async -> ExportItemResult {
        do {
            try await database.write { db in
                let records = try ExportRepository.fetchAll(category: category, in: db).filter { $0.photoId == photoId }
                for record in records {
                    guard let id = record.id else { continue }
                    try ExportRepository.deleteExportAndFile(id: id, exportFolderURL: exportFolderURL, in: db)
                }
            }
            return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: false, wasRemoved: true, errorDescription: nil)
        } catch {
            return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription)
        }
    }

    /// Matching by filename + size (not just filename) keeps this from misfiring
    /// when two genuinely different photos from different cameras happen to share a
    /// filename like IMG_0001.jpg — that case still falls through to
    /// `uniqueDestination` and gets its own disambiguated name.
    private static func destinationLooksUpToDate(jpg: Representation, in categoryDirectory: URL) -> Bool {
        let expectedDestination = categoryDirectory.appendingPathComponent(jpg.filename)
        guard FileManager.default.fileExists(atPath: expectedDestination.path) else { return false }
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: expectedDestination.path))?[.size] as? Int64
        return existingSize != nil && existingSize == jpg.fileSize
    }

    /// Never overwrites an existing file at the destination — appends `-2`, `-3`, ...
    /// if the plain filename is already taken (e.g. two cameras both producing
    /// `IMG_0001.jpg`, exported into the same category).
    private static func uniqueDestination(for filename: String, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let candidate = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var counter = 2
        while true {
            let newName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            let next = directory.appendingPathComponent(newName)
            if !fileManager.fileExists(atPath: next.path) { return next }
            counter += 1
        }
    }
}
