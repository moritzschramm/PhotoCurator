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

    @discardableResult
    public func derive(
        representationId: Int64,
        fileURL: URL,
        kind: RepresentationKind,
        knownContentHash: String? = nil
    ) async throws -> String {
        let hash = try knownContentHash ?? ContentHasher.sha256(ofFileAt: fileURL)
        let gridURL = try ThumbnailGenerator.generate(
            from: fileURL, kind: kind, size: .grid, destinationDirectory: thumbnailCacheDirectory
        )
        let previewURL = try ThumbnailGenerator.generate(
            from: fileURL, kind: kind, size: .preview, destinationDirectory: thumbnailCacheDirectory
        )
        let exif = try? ExifExtractor.extract(from: fileURL)

        try await database.write { db in
            let now = Int64(Date().timeIntervalSince1970)

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
        }

        return hash
    }
}
