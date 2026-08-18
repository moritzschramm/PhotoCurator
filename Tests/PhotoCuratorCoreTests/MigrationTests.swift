import XCTest
import GRDB
@testable import PhotoCuratorCore

final class MigrationTests: XCTestCase {
    func testMigrationCreatesAllTables() throws {
        let db = try makeInMemoryDatabase()
        let tableNames = try db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
            )
        }
        let expected = ["photos", "representations", "exif", "albums", "photo_albums", "exports", "thumbnails", "app_state"]
        for table in expected {
            XCTAssertTrue(tableNames.contains(table), "Missing table \(table)")
        }
    }

    func testMigratorCanRunTwiceWithoutError() throws {
        let db = try makeInMemoryDatabase()
        XCTAssertNoThrow(try AppMigrations.makeMigrator().migrate(db))
    }

    func testLegacyPhotoFolderBookmarkMigratesIntoFirstPhotoLibrary() throws {
        let dbQueue = try DatabaseQueue()
        // Stop right before v3, so the legacy single-bookmark app_state row can be
        // seeded exactly as it would exist on an install that predates multi-library
        // support, then let v3 pick it up.
        try AppMigrations.makeMigrator().migrate(dbQueue, upTo: "v2_photo_album_position")

        let bookmarkBytes = Data("fake bookmark bytes".utf8)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO app_state (key, value) VALUES ('photo_folder_bookmark', ?)",
                arguments: [bookmarkBytes.base64EncodedString()]
            )
        }

        try AppMigrations.makeMigrator().migrate(dbQueue)

        try dbQueue.read { db in
            let libraries = try PhotoLibrary.fetchAll(db)
            XCTAssertEqual(libraries.count, 1)
            XCTAssertEqual(libraries.first?.id, 1)
            XCTAssertEqual(libraries.first?.bookmarkData, bookmarkBytes)

            let remainingBookmarkRow = try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'photo_folder_bookmark'")
            XCTAssertNil(remainingBookmarkRow, "the legacy row should be cleared once migrated into photo_libraries")
        }
    }

    func testFreshInstallHasNoPhotoLibrariesToMigrate() throws {
        let dbQueue = try DatabaseQueue()
        try AppMigrations.makeMigrator().migrate(dbQueue)
        let count = try dbQueue.read { db in try PhotoLibrary.fetchCount(db) }
        XCTAssertEqual(count, 0, "a fresh install has no legacy bookmark, so nothing to migrate")
    }

    func testDeletingPhotoCascadesRepresentation() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            var photo = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var rep = Representation(
                libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", fileSize: 100, fileMtime: 1, isLocal: true, indexedAt: 1
            )
            try rep.insert(db)

            _ = try Photo.deleteOne(db, key: photo.id!)

            XCTAssertEqual(try Representation.fetchCount(db), 0)
        }
    }

    func testDeletingRepresentationCascadesExifAndThumbnails() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            var photo = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var rep = Representation(
                libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", isLocal: true, indexedAt: 1
            )
            try rep.insert(db)
            try ExifRecord(representationId: rep.id!, cameraModel: "Test Camera").insert(db)
            try ThumbnailRecord(representationId: rep.id!, sizeClass: .grid, cachePath: "/tmp/x.jpg").insert(db)

            _ = try Representation.deleteOne(db, key: rep.id!)

            XCTAssertEqual(try ExifRecord.fetchCount(db), 0)
            XCTAssertEqual(try ThumbnailRecord.fetchCount(db), 0)
        }
    }

    func testSourceDirBasenameUniqueConstraint() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            var photo1 = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo1.insert(db)
        }
        try db.inTransaction { db in
            var photo2 = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 2, updatedAt: 2)
            XCTAssertThrowsError(try photo2.insert(db))
            return .rollback
        }
    }

    func testRelativePathUniqueConstraint() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            var photo = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var rep1 = Representation(
                libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", isLocal: true, indexedAt: 1
            )
            try rep1.insert(db)
        }
        try db.inTransaction { db in
            let photo = try Photo.fetchOne(db)!
            var rep2 = Representation(
                libraryId: 1, photoId: photo.id!, kind: .raw, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", isLocal: true, indexedAt: 2
            )
            XCTAssertThrowsError(try rep2.insert(db))
            return .rollback
        }
    }

    func testLegacyPublishedLifecycleStateBecomesAccepted() throws {
        let dbQueue = try DatabaseQueue()
        // Stop right before v4, so a `'published'` row can be seeded exactly as it
        // would exist on an install that predates the accepted/exported split.
        try AppMigrations.makeMigrator().migrate(dbQueue, upTo: "v3_multi_photo_library")

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at) VALUES (1, 'Test', X'00', 0, 0)"
            )
            try db.execute(
                sql: """
                    INSERT INTO photos (id, library_id, basename, source_dir, lifecycle_state, created_at, updated_at)
                    VALUES (1, 1, 'IMG_0001', '', 'published', 1, 1)
                    """
            )
        }

        try AppMigrations.makeMigrator().migrate(dbQueue)

        try dbQueue.read { db in
            let photo = try Photo.fetchOne(db, key: 1)
            XCTAssertEqual(photo?.lifecycleState, .accepted)
        }
    }
}
