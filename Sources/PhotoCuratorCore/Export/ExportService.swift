import Foundation
import GRDB

public struct ExportItemResult: Sendable {
    public var photoId: Int64
    public var success: Bool
    public var skippedAsDuplicate: Bool
    public var errorDescription: String?
}

/// Export / publish (spec §7.6): copies the JPG representation of selected photos
/// into per-category subdirectories of the gallery target, dedups against the
/// `exports` log by content hash (never by re-hashing target files, since the
/// separate gallery-builder may rewrite them), and marks exported photos `published`.
public actor ExportService {
    private let database: AppDatabase
    private let derivationQueue: DerivationQueue

    public init(database: AppDatabase, derivationQueue: DerivationQueue) {
        self.database = database
        self.derivationQueue = derivationQueue
    }

    @discardableResult
    public func exportPhotos(
        photoIds: [Int64],
        category: String?,
        exportFolderURL: URL,
        photoLibraryRootURL: URL
    ) async -> [ExportItemResult] {
        var results: [ExportItemResult] = []
        for photoId in photoIds {
            let result = await exportOnePhoto(
                photoId: photoId,
                category: category,
                exportFolderURL: exportFolderURL,
                photoLibraryRootURL: photoLibraryRootURL
            )
            results.append(result)
        }
        return results
    }

    private func exportOnePhoto(
        photoId: Int64,
        category: String?,
        exportFolderURL: URL,
        photoLibraryRootURL: URL
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

            var contentHash = jpg.contentHash
            if !jpg.isLocal || contentHash == nil {
                // Exporting is the user explicitly acting on this file, so it's safe
                // to materialize an online-only JPG on demand here (spec §2, §7.3).
                contentHash = try await derivationQueue.deriveOnDemand(representation: jpg, photoRoot: photoLibraryRootURL)
            }
            guard let contentHash else {
                return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: "Could not materialize JPG for export")
            }

            let alreadyExported = try await database.read { db in
                try ExportRepository.alreadyExported(contentHash: contentHash, category: category, in: db)
            }
            if alreadyExported {
                // Still counts as published even if this particular call didn't copy
                // anything new — a prior export already put it in this category.
                let now = Int64(Date().timeIntervalSince1970)
                try await database.write { db in
                    try PhotoRepository.setLifecycleState(photoId: photoId, state: .published, now: now, in: db)
                }
                return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: true, errorDescription: nil)
            }

            let categoryDirectory = category.map { exportFolderURL.appendingPathComponent($0, isDirectory: true) } ?? exportFolderURL
            try FileManager.default.createDirectory(at: categoryDirectory, withIntermediateDirectories: true)

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
                try PhotoRepository.setLifecycleState(photoId: photoId, state: .published, now: now, in: db)
            }

            return ExportItemResult(photoId: photoId, success: true, skippedAsDuplicate: false, errorDescription: nil)
        } catch {
            return ExportItemResult(photoId: photoId, success: false, skippedAsDuplicate: false, errorDescription: error.localizedDescription)
        }
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
