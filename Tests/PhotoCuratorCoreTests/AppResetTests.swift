import XCTest
import GRDB
@testable import PhotoCuratorCore

final class AppResetTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    func testResetDatabaseClearsEveryTable() async throws {
        let database = try makeDatabase()

        try await database.write { db in
            let library = try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db)
            var photo = try PhotoRepository.upsertPhoto(libraryId: library.id!, basename: "IMG_0001", sourceDir: "", captureDate: nil, now: 1, in: db)
            photo.lifecycleState = .accepted
            try photo.update(db)
            let rep = try PhotoRepository.insertRepresentation(
                Representation(
                    libraryId: library.id!, photoId: photo.id!, kind: .jpg, relativePath: "IMG_0001.jpg",
                    filename: "IMG_0001.jpg", isLocal: true, indexedAt: 1
                ),
                in: db
            )
            try ExifRecord(representationId: rep.id!, cameraModel: "Test Camera").insert(db)
            try ThumbnailRecord(representationId: rep.id!, sizeClass: .grid, cachePath: "/tmp/x.jpg").insert(db)
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album.id!, now: 1, in: db)
            try ExportRepository.logExport(
                ExportRecord(
                    photoId: photo.id!, representationId: rep.id!, contentHash: "hash",
                    category: "Landscapes", destinationPath: "Landscapes/Landscapes-1.jpg", exportedAt: 1
                ),
                in: db
            )
            try AppStateRepository.setString("some-value", forKey: "some_key", in: db)
        }

        try await AppReset.resetDatabase(database)

        try await database.read { db in
            XCTAssertEqual(try PhotoLibrary.fetchCount(db), 0)
            XCTAssertEqual(try Photo.fetchCount(db), 0)
            XCTAssertEqual(try Representation.fetchCount(db), 0)
            XCTAssertEqual(try ExifRecord.fetchCount(db), 0)
            XCTAssertEqual(try ThumbnailRecord.fetchCount(db), 0)
            XCTAssertEqual(try Album.fetchCount(db), 0)
            XCTAssertEqual(try PhotoAlbum.fetchCount(db), 0)
            XCTAssertEqual(try ExportRecord.fetchCount(db), 0)
            XCTAssertEqual(try AppStateEntry.fetchCount(db), 0)
        }
    }

    func testResetOnAlreadyEmptyDatabaseDoesNotThrow() async throws {
        let database = try makeDatabase()
        try await AppReset.resetDatabase(database)
    }

    func testResetThumbnailCacheRemovesDirectory() throws {
        let directory = try makeTempDirectory()
        try Data("thumbnail bytes".utf8).write(to: directory.appendingPathComponent("thumb.jpg"))

        try AppReset.resetThumbnailCache(directory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testResetThumbnailCacheOnMissingDirectoryDoesNotThrow() throws {
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertNoThrow(try AppReset.resetThumbnailCache(directory: missingDirectory))
    }
}
