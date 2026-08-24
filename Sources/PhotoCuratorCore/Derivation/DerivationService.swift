import Foundation
import GRDB

/// Derives thumbnails, EXIF, and content hash for one representation whose bytes are
/// already available locally, and persists everything in a single batched write
/// (spec §7.3). Callers are responsible for only pointing this at local/materialized
/// files — this type does no online-only checks itself.
public final class DerivationService: @unchecked Sendable {
    private let database: AppDatabase
    private let thumbnailCacheDirectory: URL

    public init(database: AppDatabase, thumbnailCacheDirectory: URL) {
        self.database = database
        self.thumbnailCacheDirectory = thumbnailCacheDirectory
    }

    /// Everything derived from the file's bytes in one off-thread pass, before any of
    /// it touches the database.
    private struct DerivedArtifacts: Sendable {
        var hash: String
        var gridURL: URL
        var previewURL: URL
        var exif: ExtractedExif?
    }

    @discardableResult
    public func derive(
        representationId: Int64,
        fileURL: URL,
        kind: RepresentationKind,
        knownContentHash: String? = nil
    ) async throws -> String {
        let cacheDirectory = thumbnailCacheDirectory
        // Hashing and ImageIO decoding are blocking CPU work with no suspension
        // points. Left on the cooperative pool, the backlog's four concurrent
        // derivations tie up most of its threads and stall every unrelated `await` in
        // the app — including the database observations the UI renders from.
        let artifacts = try await BackgroundWork.run { () throws -> DerivedArtifacts in
            let hash = try knownContentHash ?? ContentHasher.sha256(ofFileAt: fileURL)
            let gridURL = try ThumbnailGenerator.generate(
                from: fileURL, kind: kind, size: .grid, destinationDirectory: cacheDirectory
            )
            let previewURL = try ThumbnailGenerator.generate(
                from: fileURL, kind: kind, size: .preview, destinationDirectory: cacheDirectory
            )
            return DerivedArtifacts(
                hash: hash,
                gridURL: gridURL,
                previewURL: previewURL,
                exif: try? ExifExtractor.extract(from: fileURL)
            )
        }
        let hash = artifacts.hash
        let gridURL = artifacts.gridURL
        let previewURL = artifacts.previewURL
        let exif = artifacts.exif

        let supersededCachePaths = try await database.write { db -> [String] in
            let now = Int64(Date().timeIntervalSince1970)

            // `ThumbnailGenerator` writes to a fresh UUID filename every time, and
            // `saveThumbnail` upserts on (representation_id, size_class) — so
            // re-deriving a representation silently strands whatever file the row
            // used to point at. Collected here, deleted after the write commits.
            var superseded: [String] = []
            for sizeClass in [ThumbnailSizeClass.grid, .preview] {
                if let existing = try PhotoRepository.fetchThumbnail(
                    representationId: representationId, sizeClass: sizeClass, in: db
                ) {
                    superseded.append(existing.cachePath)
                }
            }

            try PhotoRepository.markDerived(representationId: representationId, contentHash: hash, in: db)

            try PhotoRepository.saveThumbnail(
                ThumbnailRecord(representationId: representationId, sizeClass: .grid, cachePath: gridURL.path),
                in: db
            )
            try PhotoRepository.saveThumbnail(
                ThumbnailRecord(representationId: representationId, sizeClass: .preview, cachePath: previewURL.path),
                in: db
            )

            if let exif {
                try PhotoRepository.saveExif(
                    ExifRecord(
                        representationId: representationId,
                        cameraModel: exif.cameraModel,
                        lens: exif.lens,
                        iso: exif.iso,
                        aperture: exif.aperture,
                        shutter: exif.shutter,
                        focalLength: exif.focalLength,
                        orientation: exif.orientation,
                        gpsLat: exif.gpsLat,
                        gpsLng: exif.gpsLng
                    ),
                    in: db
                )

                if let captureDate = exif.captureDate,
                   let rep = try PhotoRepository.fetchRepresentation(id: representationId, in: db) {
                    try PhotoRepository.backfillCaptureDate(
                        photoId: rep.photoId,
                        captureDate: Int64(captureDate.timeIntervalSince1970),
                        now: now,
                        in: db
                    )
                }
            }

            return superseded
        }

        // Only after the write commits: a rolled-back transaction would leave the
        // old rows in place, and they must not be left pointing at deleted files.
        // Deliberately not extended to rows that *cascade* away (a representation
        // deleted by reconciliation or by removing a library) — undo of a library
        // removal restores those rows verbatim and relies on their cached files
        // still being there (see `PhotoLibraryRepository.snapshot`).
        for path in supersededCachePaths where path != gridURL.path && path != previewURL.path {
            try? FileManager.default.removeItem(atPath: path)
        }

        return hash
    }
}
