import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCuratorCore

final class DerivationServiceTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    /// `ThumbnailGenerator` writes a fresh UUID filename on every run and
    /// `saveThumbnail` upserts on (representation_id, size_class), so re-deriving the
    /// same representation used to strand the previous pair of cached JPEGs on disk
    /// forever, with nothing left pointing at them.
    func testRederivingARepresentationDeletesTheCacheFilesItSuperseded() async throws {
        let cacheDirectory = try makeTempDirectory()
        let sourceDirectory = try makeTempDirectory()
        defer {
            for url in [cacheDirectory, sourceDirectory] { try? FileManager.default.removeItem(at: url) }
        }

        let fileURL = sourceDirectory.appendingPathComponent("IMG_0001.jpg")
        try writeJPEG(to: fileURL, gray: 0.2)

        let database = try makeDatabase()
        let representationId = try await database.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at) VALUES (1, 'L', X'00', 0, 0)"
            )
            let photo = try PhotoRepository.upsertPhoto(
                libraryId: 1, basename: "IMG_0001", sourceDir: "", captureDate: nil, now: 0, in: db
            )
            let representation = try PhotoRepository.insertRepresentation(
                Representation(
                    libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "IMG_0001.jpg",
                    filename: "IMG_0001.jpg", fileSize: nil, fileMtime: nil, contentHash: nil,
                    isLocal: true, derivationState: .underived, indexedAt: 0
                ),
                in: db
            )
            return representation.id!
        }

        let service = DerivationService(database: database, thumbnailCacheDirectory: cacheDirectory)
        _ = try await service.derive(representationId: representationId, fileURL: fileURL, kind: .jpg)

        let firstPaths = try await database.read { db in
            try [ThumbnailSizeClass.grid, .preview].compactMap {
                try PhotoRepository.fetchThumbnail(representationId: representationId, sizeClass: $0, in: db)?.cachePath
            }
        }
        XCTAssertEqual(firstPaths.count, 2)
        XCTAssertTrue(firstPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })

        // Same representation, new bytes — exactly what happens when a file is edited
        // outside the app and reconciliation re-derives it.
        try writeJPEG(to: fileURL, gray: 0.8)
        _ = try await service.derive(representationId: representationId, fileURL: fileURL, kind: .jpg)

        let secondPaths = try await database.read { db in
            try [ThumbnailSizeClass.grid, .preview].compactMap {
                try PhotoRepository.fetchThumbnail(representationId: representationId, sizeClass: $0, in: db)?.cachePath
            }
        }
        XCTAssertEqual(Set(secondPaths).intersection(firstPaths), [], "re-derivation writes to fresh paths")
        XCTAssertTrue(secondPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        for path in firstPaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "superseded cache file should be deleted")
        }

        let cachedFiles = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        XCTAssertEqual(cachedFiles.count, 2, "cache should hold only the current grid + preview thumbnails")
    }
}
