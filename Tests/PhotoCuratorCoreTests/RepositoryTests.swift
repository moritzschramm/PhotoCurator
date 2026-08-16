import XCTest
import GRDB
@testable import PhotoCuratorCore

final class PhotoRepositoryTests: XCTestCase {
    func testUpsertPhotoDoesNotDuplicateSameBasenameAndSourceDir() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let first = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let second = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 2, in: db)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(try Photo.fetchCount(db), 1)
        }
    }

    func testUpsertPhotoBackfillsCaptureDateOnlyWhenMissing() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            _ = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let filled = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraA", captureDate: 500, now: 2, in: db)
            XCTAssertEqual(filled.captureDate, 500)

            let unchanged = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraA", captureDate: 999, now: 3, in: db)
            XCTAssertEqual(unchanged.captureDate, 500, "an existing capture date must not be overwritten")
        }
    }

    func testBackfillMissingCaptureDatesFromMtimeFillsFromEarliestRepresentation() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try PhotoRepository.insertRepresentation(
                Representation(photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", fileMtime: 500, isLocal: true, indexedAt: 1),
                in: db
            )
            try PhotoRepository.insertRepresentation(
                Representation(photoId: photo.id!, kind: .raw, relativePath: "Cam/A.CR3", filename: "A.CR3", fileMtime: 300, isLocal: true, indexedAt: 1),
                in: db
            )

            let count = try PhotoRepository.backfillMissingCaptureDatesFromMtime(now: 2, in: db)
            XCTAssertEqual(count, 1)

            let updated = try PhotoRepository.fetchPhoto(id: photo.id!, in: db)
            XCTAssertEqual(updated?.captureDate, 300, "should use the earliest mtime among representations")
        }
    }

    func testBackfillMissingCaptureDatesFromMtimeSkipsPhotosThatAlreadyHaveOne() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: 999, now: 1, in: db)
            try PhotoRepository.insertRepresentation(
                Representation(photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", fileMtime: 500, isLocal: true, indexedAt: 1),
                in: db
            )

            let count = try PhotoRepository.backfillMissingCaptureDatesFromMtime(now: 2, in: db)
            XCTAssertEqual(count, 0)

            let updated = try PhotoRepository.fetchPhoto(id: photo.id!, in: db)
            XCTAssertEqual(updated?.captureDate, 999, "must not overwrite an existing capture date")
        }
    }

    func testSameBasenameDifferentSourceDirCreatesSeparatePhotos() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let a = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(basename: "IMG_0001", sourceDir: "CameraB", captureDate: nil, now: 1, in: db)
            XCTAssertNotEqual(a.id, b.id)
        }
    }

    func testBaselineMarksOnlyNewPhotosAsReviewed() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            _ = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            var alreadyPublished = try PhotoRepository.upsertPhoto(basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            alreadyPublished.lifecycleState = .published
            try alreadyPublished.update(db)

            let count = try PhotoRepository.markAllAsReviewedBaseline(now: 2, in: db)
            XCTAssertEqual(count, 1)
        }
        try db.read { db in
            let photos = try Photo.order(Column("basename")).fetchAll(db)
            XCTAssertEqual(photos.map(\.lifecycleState), [.reviewed, .published])
        }
    }

    func testDeleteRepresentationCascadingEmptyPhotoRemovesPhotoOnlyWhenLastRepresentation() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let jpg = try PhotoRepository.insertRepresentation(
                Representation(photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", isLocal: true, indexedAt: 1),
                in: db
            )
            let raw = try PhotoRepository.insertRepresentation(
                Representation(photoId: photo.id!, kind: .raw, relativePath: "Cam/A.CR3", filename: "A.CR3", isLocal: true, indexedAt: 1),
                in: db
            )

            try PhotoRepository.deleteRepresentationCascadingEmptyPhoto(id: jpg.id!, in: db)
            XCTAssertNotNil(try PhotoRepository.fetchPhoto(id: photo.id!, in: db), "photo should survive while it still has a representation")

            try PhotoRepository.deleteRepresentationCascadingEmptyPhoto(id: raw.id!, in: db)
            XCTAssertNil(try PhotoRepository.fetchPhoto(id: photo.id!, in: db), "photo should be removed once its last representation is gone")
        }
    }
}

final class AlbumRepositoryTests: XCTestCase {
    func testFetchAllAlbumsSortsCaseInsensitivelyAndNaturally() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            // SQLite's default BINARY collation would sort all-uppercase names
            // before any lowercase one (e.g. "Vacation" before "family photos"),
            // and lexically rather than numerically (e.g. "Trip 10" before "Trip 2").
            _ = try AlbumRepository.createAlbum(name: "Vacation", now: 1, in: db)
            _ = try AlbumRepository.createAlbum(name: "family photos", now: 1, in: db)
            _ = try AlbumRepository.createAlbum(name: "Trip 2", now: 1, in: db)
            _ = try AlbumRepository.createAlbum(name: "Trip 10", now: 1, in: db)

            let names = try AlbumRepository.fetchAllAlbums(in: db).map(\.name)
            XCTAssertEqual(names, ["family photos", "Trip 2", "Trip 10", "Vacation"])
        }
    }

    func testAlbumPhotosSortByCaptureDateNewestFirstNotByWhenAdded() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)

            // Added to the album in an order that's the *reverse* of their capture
            // dates, so a passing test can only mean sorting is really by capture
            // date, not by when each photo was added.
            let older = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: 100, now: 1, in: db)
            let newer = try PhotoRepository.upsertPhoto(basename: "B", sourceDir: "Cam", captureDate: 200, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: newer.id!, albumId: album.id!, now: 2, in: db)
            try AlbumRepository.addPhoto(photoId: older.id!, albumId: album.id!, now: 3, in: db)

            let photos = try AlbumRepository.photos(albumId: album.id!, in: db)
            XCTAssertEqual(photos.map(\.photo.basename), ["B", "A"], "newest capture date should come first")
        }
    }

    func testToggleMembershipAddsThenRemoves() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)

            let addedNowIn = try AlbumRepository.toggleMembership(photoId: photo.id!, albumId: album.id!, now: 2, in: db)
            XCTAssertTrue(addedNowIn)
            XCTAssertEqual(try AlbumRepository.albumIds(photoId: photo.id!, in: db), [album.id!])

            let removedNowOut = try AlbumRepository.toggleMembership(photoId: photo.id!, albumId: album.id!, now: 3, in: db)
            XCTAssertFalse(removedNowOut)
            XCTAssertEqual(try AlbumRepository.albumIds(photoId: photo.id!, in: db), [])
        }
    }

    func testAddPhotoIsIdempotent() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)

            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album.id!, now: 2, in: db)
            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album.id!, now: 3, in: db)

            XCTAssertEqual(try AlbumRepository.photoCount(albumId: album.id!, in: db), 1)
        }
    }

    func testPhotoCanBelongToMultipleAlbums() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album1 = try AlbumRepository.createAlbum(name: "One", now: 1, in: db)
            let album2 = try AlbumRepository.createAlbum(name: "Two", now: 1, in: db)

            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album1.id!, now: 2, in: db)
            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album2.id!, now: 2, in: db)

            XCTAssertEqual(try AlbumRepository.albumIds(photoId: photo.id!, in: db), [album1.id!, album2.id!])
        }
    }
}

final class ExportRepositoryTests: XCTestCase {
    func testDedupIsScopedByContentHashAndCategory() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let rep = try PhotoRepository.insertRepresentation(
                Representation(photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", isLocal: true, indexedAt: 1),
                in: db
            )

            XCTAssertFalse(try ExportRepository.alreadyExported(contentHash: "abc", category: "Landscapes", in: db))

            try ExportRepository.logExport(
                ExportRecord(
                    photoId: photo.id!, representationId: rep.id!, contentHash: "abc",
                    category: "Landscapes", destinationPath: "Landscapes/A.jpg", exportedAt: 1
                ),
                in: db
            )

            XCTAssertTrue(try ExportRepository.alreadyExported(contentHash: "abc", category: "Landscapes", in: db))
            XCTAssertFalse(
                try ExportRepository.alreadyExported(contentHash: "abc", category: "Portraits", in: db),
                "the same photo exported under a different category is not a duplicate"
            )
        }
    }
}
