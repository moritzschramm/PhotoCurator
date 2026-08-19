import XCTest
@testable import PhotoCuratorCore

final class ThumbnailCacheMaintenanceTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    func testSweepRemovesOnlyFilesNoThumbnailRowPointsAt() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let live = cacheDirectory.appendingPathComponent("live.jpg")
        let orphan = cacheDirectory.appendingPathComponent("orphan.jpg")
        try Data("live".utf8).write(to: live)
        try Data("orphan".utf8).write(to: orphan)

        let database = try makeDatabase()
        try await database.write { db in
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
                    isLocal: true, derivationState: .derived, indexedAt: 0
                ),
                in: db
            )
            try PhotoRepository.saveThumbnail(
                ThumbnailRecord(representationId: representation.id!, sizeClass: .grid, cachePath: live.path), in: db
            )
        }

        let removed = await ThumbnailCacheMaintenance.sweepOrphans(directory: cacheDirectory, database: database)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a referenced thumbnail must be kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "an unreferenced file must be reclaimed")
    }

    /// A fresh install has no cache directory at all yet — the sweep must not treat
    /// that as an error or, worse, report phantom deletions.
    func testSweepIsANoOpForAMissingDirectory() async throws {
        let database = try makeDatabase()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let removed = await ThumbnailCacheMaintenance.sweepOrphans(directory: missing, database: database)
        XCTAssertEqual(removed, 0)
    }
}
