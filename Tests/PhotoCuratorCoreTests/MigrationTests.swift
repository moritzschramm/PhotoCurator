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

    func testDeletingPhotoCascadesRepresentation() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            var photo = Photo(basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var rep = Representation(
                photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
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
            var photo = Photo(basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var rep = Representation(
                photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
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
            var photo1 = Photo(basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo1.insert(db)
        }
        try db.inTransaction { db in
            var photo2 = Photo(basename: "IMG_0001", sourceDir: "CameraA", createdAt: 2, updatedAt: 2)
            XCTAssertThrowsError(try photo2.insert(db))
            return .rollback
        }
    }

    func testRelativePathUniqueConstraint() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            var photo = Photo(basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var rep1 = Representation(
                photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", isLocal: true, indexedAt: 1
            )
            try rep1.insert(db)
        }
        try db.inTransaction { db in
            let photo = try Photo.fetchOne(db)!
            var rep2 = Representation(
                photoId: photo.id!, kind: .raw, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", isLocal: true, indexedAt: 2
            )
            XCTAssertThrowsError(try rep2.insert(db))
            return .rollback
        }
    }
}
