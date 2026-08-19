import XCTest
import GRDB
@testable import PhotoCuratorCore

/// Exercises the repository-level primitives import undo/redo is built on
/// (`deleteRepresentation`, `deletePhotoIfEmpty`, `restorePhoto`,
/// `restoreRepresentation`) directly against a real migrated schema — in particular
/// the RAW+JPG shared-photo-row case, where two representations from the same import
/// batch share one `photos` row and only *one* of their individual undos should end
/// up being the one that empties (and later restores) it, regardless of processing
/// order. The full `AppEnvironment`-level batching lives in `PhotoCuratorUI`, not
/// reachable from this target, so this covers the correctness-critical data layer on
/// its own.
final class ImportUndoRepositoryTests: XCTestCase {
    func testDeletingBothSiblingRepresentationsEmptiesPhotoExactlyOnce() throws {
        let db = try makeInMemoryDatabase()

        var photo = Photo(libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", createdAt: 1, updatedAt: 1)
        var jpg: Representation!
        var raw: Representation!
        try db.write { db in
            try photo.insert(db)
            var jpgRep = Representation(
                libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                filename: "IMG_0001.jpg", isLocal: true, indexedAt: 1
            )
            try jpgRep.insert(db)
            jpg = jpgRep
            var rawRep = Representation(
                libraryId: 1, photoId: photo.id!, kind: .raw, relativePath: "CameraA/IMG_0001.CR3",
                filename: "IMG_0001.CR3", isLocal: true, indexedAt: 1
            )
            try rawRep.insert(db)
            raw = rawRep
        }

        // Delete the JPG side first — the photo still has the RAW representation, so
        // it must survive.
        let photoAfterFirstDelete = try db.write { db -> Photo? in
            try PhotoRepository.deleteRepresentation(id: jpg.id!, in: db)
            return try PhotoRepository.deletePhotoIfEmpty(photoId: photo.id!, in: db)
        }
        XCTAssertNil(photoAfterFirstDelete, "the photo has one representation left, it must not be deleted yet")
        try db.read { db in
            XCTAssertNotNil(try Photo.fetchOne(db, key: photo.id!))
            XCTAssertEqual(try Representation.fetchCount(db), 1)
        }

        // Delete the RAW side second — now the photo is genuinely empty.
        let photoAfterSecondDelete = try db.write { db -> Photo? in
            try PhotoRepository.deleteRepresentation(id: raw.id!, in: db)
            return try PhotoRepository.deletePhotoIfEmpty(photoId: photo.id!, in: db)
        }
        let deletedPhoto = try XCTUnwrap(photoAfterSecondDelete, "the second, last representation's own undo must be the one that empties the photo")
        try db.read { db in
            XCTAssertNil(try Photo.fetchOne(db, key: photo.id!))
            XCTAssertEqual(try Representation.fetchCount(db), 0)
        }

        // Redo (in the same order undo ran): restore the emptied photo alongside the
        // RAW representation, then restore the JPG representation on its own — the
        // shared photo row must not be double-inserted.
        try db.write { db in
            try PhotoRepository.restorePhoto(deletedPhoto, in: db)
            try PhotoRepository.restoreRepresentation(raw, in: db)
            try PhotoRepository.restoreRepresentation(jpg, in: db)
        }

        try db.read { db in
            XCTAssertEqual(try Photo.fetchAll(db), [photo])
            XCTAssertEqual(Set(try Representation.fetchAll(db).compactMap(\.id)), Set([jpg.id!, raw.id!]))
        }
    }
}
