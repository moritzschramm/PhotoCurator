import XCTest
import GRDB
@testable import PhotoCuratorCore

final class PhotoRepositoryTests: XCTestCase {
    func testUpsertPhotoDoesNotDuplicateSameBasenameAndSourceDir() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let first = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let second = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 2, in: db)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(try Photo.fetchCount(db), 1)
        }
    }

    func testUpsertPhotoBackfillsCaptureDateOnlyWhenMissing() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            _ = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let filled = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: 500, now: 2, in: db)
            XCTAssertEqual(filled.captureDate, 500)

            let unchanged = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: 999, now: 3, in: db)
            XCTAssertEqual(unchanged.captureDate, 500, "an existing capture date must not be overwritten")
        }
    }

    func testBackfillMissingCaptureDatesFromMtimeFillsFromEarliestRepresentation() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try PhotoRepository.insertRepresentation(
                Representation(libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", fileMtime: 500, isLocal: true, indexedAt: 1),
                in: db
            )
            try PhotoRepository.insertRepresentation(
                Representation(libraryId: 1, photoId: photo.id!, kind: .raw, relativePath: "Cam/A.CR3", filename: "A.CR3", fileMtime: 300, isLocal: true, indexedAt: 1),
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
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: 999, now: 1, in: db)
            try PhotoRepository.insertRepresentation(
                Representation(libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", fileMtime: 500, isLocal: true, indexedAt: 1),
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
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraB", captureDate: nil, now: 1, in: db)
            XCTAssertNotEqual(a.id, b.id)
        }
    }

    func testBaselineMarksOnlyNewPhotosAsAccepted() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            _ = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            var alreadyRejected = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            alreadyRejected.lifecycleState = .rejected
            try alreadyRejected.update(db)

            let count = try PhotoRepository.markAllAsAcceptedBaseline(now: 2, in: db)
            XCTAssertEqual(count, 1)
        }
        try db.read { db in
            let photos = try Photo.order(Column("basename")).fetchAll(db)
            XCTAssertEqual(photos.map(\.lifecycleState), [.accepted, .rejected])
        }
    }

    func testDeleteRepresentationCascadingEmptyPhotoRemovesPhotoOnlyWhenLastRepresentation() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let jpg = try PhotoRepository.insertRepresentation(
                Representation(libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", isLocal: true, indexedAt: 1),
                in: db
            )
            let raw = try PhotoRepository.insertRepresentation(
                Representation(libraryId: 1, photoId: photo.id!, kind: .raw, relativePath: "Cam/A.CR3", filename: "A.CR3", isLocal: true, indexedAt: 1),
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

    func testAlbumPhotosDefaultToAddOrderNotCaptureDate() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)

            // Added to the album in an order that's the *reverse* of their capture
            // dates, so a passing test can only mean the default order is really
            // add order (position), not capture date.
            let older = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: 100, now: 1, in: db)
            let newer = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: 200, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: newer.id!, albumId: album.id!, now: 2, in: db)
            try AlbumRepository.addPhoto(photoId: older.id!, albumId: album.id!, now: 3, in: db)

            let photos = try AlbumRepository.photos(albumId: album.id!, in: db)
            XCTAssertEqual(photos.map(\.photo.basename), ["B", "A"], "photos should default to the order they were added, not capture date")
        }
    }

    func testAddPhotosBatchSortsAlphabeticallyByFilenameRegardlessOfInputOrder() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)
            let c = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "C", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)

            // Passed in selection order (C, A, B), not filename order.
            try AlbumRepository.addPhotos(photoIds: [c.id!, a.id!, b.id!], albumId: album.id!, now: 2, in: db)

            let photos = try AlbumRepository.photos(albumId: album.id!, in: db)
            XCTAssertEqual(photos.map(\.photo.basename), ["A", "B", "C"], "a batch add's initial relative order should be alphabetical by filename")
        }
    }

    func testAddPhotosBatchAppendsAfterPhotosAlreadyInAlbum() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)
            let existing = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "Z", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: existing.id!, albumId: album.id!, now: 2, in: db)

            // Alphabetically these would sort before "Z", but they're a later batch
            // and must land after everything already in the album.
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try AlbumRepository.addPhotos(photoIds: [b.id!, a.id!], albumId: album.id!, now: 3, in: db)

            let photos = try AlbumRepository.photos(albumId: album.id!, in: db)
            XCTAssertEqual(photos.map(\.photo.basename), ["Z", "A", "B"], "new photos should be appended after existing ones, not interleaved by filename")
        }
    }

    func testAddPhotosBatchLeavesExistingMembersUntouched() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: b.id!, albumId: album.id!, now: 2, in: db)
            try AlbumRepository.addPhoto(photoId: a.id!, albumId: album.id!, now: 3, in: db)

            // Re-adding both (one already present, one new) as a batch shouldn't
            // reshuffle the already-present photo's position.
            let c = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "C", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try AlbumRepository.addPhotos(photoIds: [a.id!, c.id!], albumId: album.id!, now: 4, in: db)

            let photos = try AlbumRepository.photos(albumId: album.id!, in: db)
            XCTAssertEqual(photos.map(\.photo.basename), ["B", "A", "C"])
        }
    }

    func testReorderPhotosPersistsCustomOrder() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let c = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "C", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            try AlbumRepository.addPhotos(photoIds: [a.id!, b.id!, c.id!], albumId: album.id!, now: 2, in: db)

            try AlbumRepository.reorderPhotos(albumId: album.id!, orderedPhotoIds: [c.id!, a.id!, b.id!], in: db)

            let photos = try AlbumRepository.photos(albumId: album.id!, in: db)
            XCTAssertEqual(photos.map(\.photo.basename), ["C", "A", "B"], "a drag-and-drop reorder should persist and be reflected on the next fetch")
        }
    }

    func testToggleMembershipAddsThenRemoves() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)

            let addedNowIn = try AlbumRepository.toggleMembership(photoId: photo.id!, albumId: album.id!, now: 2, in: db)
            XCTAssertTrue(addedNowIn)
            XCTAssertEqual(try AlbumRepository.albumIds(photoId: photo.id!, in: db), [album.id!])

            let removedNowOut = try AlbumRepository.toggleMembership(photoId: photo.id!, albumId: album.id!, now: 3, in: db)
            XCTAssertFalse(removedNowOut)
            XCTAssertEqual(try AlbumRepository.albumIds(photoId: photo.id!, in: db), [])
        }
    }

    func testBatchAlbumIdsReturnsMembershipPerPhoto() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let c = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "C", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album1 = try AlbumRepository.createAlbum(name: "One", now: 1, in: db)
            let album2 = try AlbumRepository.createAlbum(name: "Two", now: 1, in: db)

            try AlbumRepository.addPhoto(photoId: a.id!, albumId: album1.id!, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: a.id!, albumId: album2.id!, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: b.id!, albumId: album1.id!, now: 1, in: db)
            // c is in neither album.

            let result = try AlbumRepository.albumIds(photoIds: [a.id!, b.id!, c.id!], in: db)
            XCTAssertEqual(result[a.id!], [album1.id!, album2.id!])
            XCTAssertEqual(result[b.id!], [album1.id!])
            XCTAssertNil(result[c.id!], "a photo in no albums shouldn't appear in the result at all")
        }
    }

    func testRemovePhotosRemovesOnlyTheGivenPhotosFromOneAlbum() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: a.id!, albumId: album.id!, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: b.id!, albumId: album.id!, now: 1, in: db)

            try AlbumRepository.removePhotos(photoIds: [a.id!], albumId: album.id!, in: db)

            XCTAssertEqual(try AlbumRepository.albumIds(photoId: a.id!, in: db), [])
            XCTAssertEqual(try AlbumRepository.albumIds(photoId: b.id!, in: db), [album.id!])
        }
    }

    func testAddPhotoIsIdempotent() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)

            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album.id!, now: 2, in: db)
            try AlbumRepository.addPhoto(photoId: photo.id!, albumId: album.id!, now: 3, in: db)

            XCTAssertEqual(try AlbumRepository.photoCount(albumId: album.id!, in: db), 1)
        }
    }

    func testPhotoCanBelongToMultipleAlbums() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
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
            let photo = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let rep = try PhotoRepository.insertRepresentation(
                Representation(libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "Cam/A.jpg", filename: "A.jpg", isLocal: true, indexedAt: 1),
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

final class PhotoLibraryScopingTests: XCTestCase {
    func testUpsertPhotoScopesUniquenessPerLibraryNotGlobally() throws {
        let db = try makeInMemoryDatabase() // seeds library id 1
        try db.write { db in
            let library2 = try PhotoLibraryRepository.create(name: "Second", bookmarkData: Data(), now: 1, in: db)
            let a = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            let b = try PhotoRepository.upsertPhoto(libraryId: library2.id!, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            XCTAssertNotEqual(a.id, b.id, "identical basename+sourceDir under two different libraries must not collide")
            XCTAssertEqual(try Photo.fetchCount(db), 2)
        }
    }

    func testFetchAllPhotosWithRepresentationsFiltersByLibraryId() throws {
        let db = try makeInMemoryDatabase() // seeds library id 1
        try db.write { db in
            let library2 = try PhotoLibraryRepository.create(name: "Second", bookmarkData: Data(), now: 1, in: db)
            _ = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            _ = try PhotoRepository.upsertPhoto(libraryId: library2.id!, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)

            let all = try PhotoRepository.fetchAllPhotosWithRepresentations(db)
            XCTAssertEqual(all.count, 2, "nil libraryId means every library")

            let library1Only = try PhotoRepository.fetchAllPhotosWithRepresentations(db, libraryId: 1)
            XCTAssertEqual(library1Only.map(\.photo.basename), ["A"])

            let library2Only = try PhotoRepository.fetchAllPhotosWithRepresentations(db, libraryId: library2.id!)
            XCTAssertEqual(library2Only.map(\.photo.basename), ["B"])
        }
    }

    func testLibraryHasRootLevelPhotos() throws {
        let db = try makeInMemoryDatabase() // seeds library id 1
        try db.write { db in
            let library2 = try PhotoLibraryRepository.create(name: "Second", bookmarkData: Data(), now: 1, in: db)
            XCTAssertFalse(try PhotoRepository.libraryHasRootLevelPhotos(libraryId: 1, in: db))

            _ = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "", captureDate: nil, now: 1, in: db)
            XCTAssertTrue(try PhotoRepository.libraryHasRootLevelPhotos(libraryId: 1, in: db))

            _ = try PhotoRepository.upsertPhoto(libraryId: library2.id!, basename: "B", sourceDir: "CameraA", captureDate: nil, now: 1, in: db)
            XCTAssertFalse(
                try PhotoRepository.libraryHasRootLevelPhotos(libraryId: library2.id!, in: db),
                "a photo in a subdirectory in a different library must not affect this one"
            )
        }
    }

    func testFetchUnassignedGridEntriesExcludesAlbumMembersAndUnreviewedAndRejected() throws {
        let db = try makeInMemoryDatabase()
        try db.write { db in
            let unassignedAccepted = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "A", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let unassignedCandidate = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "B", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let inAlbum = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "C", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let unreviewed = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "D", sourceDir: "Cam", captureDate: nil, now: 1, in: db)
            let rejected = try PhotoRepository.upsertPhoto(libraryId: 1, basename: "E", sourceDir: "Cam", captureDate: nil, now: 1, in: db)

            try PhotoRepository.setLifecycleState(photoId: unassignedAccepted.id!, state: .accepted, now: 1, in: db)
            try PhotoRepository.setLifecycleState(photoId: unassignedCandidate.id!, state: .candidate, now: 1, in: db)
            try PhotoRepository.setLifecycleState(photoId: inAlbum.id!, state: .accepted, now: 1, in: db)
            try PhotoRepository.setLifecycleState(photoId: rejected.id!, state: .rejected, now: 1, in: db)
            // `unreviewed` stays at the default `.new`.

            let album = try AlbumRepository.createAlbum(name: "Favorites", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: inAlbum.id!, albumId: album.id!, now: 1, in: db)

            let entries = try PhotoRepository.fetchUnassignedGridEntries(db)
            XCTAssertEqual(Set(entries.map(\.id)), [unassignedAccepted.id!, unassignedCandidate.id!])
        }
    }
}
