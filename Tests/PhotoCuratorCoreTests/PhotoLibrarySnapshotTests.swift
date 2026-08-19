import XCTest
import GRDB
@testable import PhotoCuratorCore

/// Exercises `PhotoLibraryRepository.snapshot(id:in:)`/`restore(_:in:)` against the
/// real migrated schema's actual FK graph — the mechanism `removePhotoLibrary`'s undo
/// relies on to bring back everything `delete(id:in:)`'s cascade removes.
final class PhotoLibrarySnapshotTests: XCTestCase {
    func testSnapshotThenDeleteThenRestoreRoundTrips() throws {
        let db = try makeInMemoryDatabase()

        try db.write { db in
            var photo = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
            try photo.insert(db)
            var jpg = Representation(
                libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", fileSize: 100, isLocal: true, indexedAt: 1
            )
            try jpg.insert(db)
            try ExifRecord(representationId: jpg.id!, cameraModel: "Test Camera").insert(db)
            try ThumbnailRecord(representationId: jpg.id!, sizeClass: .grid, cachePath: "/tmp/x.jpg").insert(db)

            var album = Album(name: "Landscapes", coverPhotoId: photo.id, createdAt: 1)
            try album.insert(db)
            try PhotoAlbum(photoId: photo.id!, albumId: album.id!, addedAt: 1, position: 0).insert(db)

            var export = ExportRecord(
                photoId: photo.id!, representationId: jpg.id!, contentHash: "hash-1",
                category: "Landscapes", destinationPath: "Landscapes/Landscapes-1.jpg", exportedAt: 1
            )
            try export.insert(db)
        }

        let snapshot = try db.read { db in try PhotoLibraryRepository.snapshot(id: 1, in: db) }
        let unwrappedSnapshot = try XCTUnwrap(snapshot)
        XCTAssertEqual(unwrappedSnapshot.photos.count, 1)
        XCTAssertEqual(unwrappedSnapshot.representations.count, 1)
        XCTAssertEqual(unwrappedSnapshot.exifRecords.count, 1)
        XCTAssertEqual(unwrappedSnapshot.thumbnails.count, 1)
        XCTAssertEqual(unwrappedSnapshot.photoAlbums.count, 1)
        XCTAssertEqual(unwrappedSnapshot.exports.count, 1)
        XCTAssertEqual(unwrappedSnapshot.nulledCoverPhotoIds.count, 1)

        try db.write { db in try PhotoLibraryRepository.delete(id: 1, in: db) }

        try db.read { db in
            XCTAssertEqual(try Photo.fetchCount(db), 0, "cascade should have removed the photo")
            XCTAssertEqual(try Representation.fetchCount(db), 0)
            XCTAssertEqual(try ExifRecord.fetchCount(db), 0)
            XCTAssertEqual(try ThumbnailRecord.fetchCount(db), 0)
            XCTAssertEqual(try PhotoAlbum.fetchCount(db), 0)
            XCTAssertEqual(try ExportRecord.fetchCount(db), 0)
            let album = try Album.fetchOne(db)
            XCTAssertNotNil(album, "the album itself must survive — only its cover reference is cleared")
            XCTAssertNil(album?.coverPhotoId, "ON DELETE SET NULL should have cleared the cover reference")
        }

        try db.write { db in try PhotoLibraryRepository.restore(unwrappedSnapshot, in: db) }

        try db.read { db in
            XCTAssertEqual(try Photo.fetchAll(db), unwrappedSnapshot.photos)
            XCTAssertEqual(try Representation.fetchAll(db), unwrappedSnapshot.representations)
            XCTAssertEqual(try ExifRecord.fetchAll(db), unwrappedSnapshot.exifRecords)
            XCTAssertEqual(try ThumbnailRecord.fetchAll(db), unwrappedSnapshot.thumbnails)
            XCTAssertEqual(try PhotoAlbum.fetchAll(db), unwrappedSnapshot.photoAlbums)
            XCTAssertEqual(try ExportRecord.fetchAll(db), unwrappedSnapshot.exports)
            let restoredAlbum = try XCTUnwrap(try Album.fetchOne(db))
            XCTAssertEqual(restoredAlbum.coverPhotoId, unwrappedSnapshot.photos.first?.id, "the cover reference must be restored, not left null")
        }
    }

    func testSnapshotOfNonexistentLibraryReturnsNil() throws {
        let db = try makeInMemoryDatabase()
        let snapshot = try db.read { db in try PhotoLibraryRepository.snapshot(id: 999, in: db) }
        XCTAssertNil(snapshot)
    }
}
