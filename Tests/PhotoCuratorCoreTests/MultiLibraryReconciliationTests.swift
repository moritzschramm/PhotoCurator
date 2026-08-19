import XCTest
@testable import PhotoCuratorCore

/// Reconciliation across *several* registered libraries at once — specifically that
/// two roots holding byte-identical copies of the same photo stay independent.
/// `ReconciliationServiceIntegrationTests` covers the single-library pipeline.
final class MultiLibraryReconciliationTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    private func registerLibrary(at url: URL, database: AppDatabase, name: String) async throws -> LibrarySource {
        let library = try await database.write { db in
            try PhotoLibraryRepository.create(name: name, bookmarkData: Data(), now: 0, in: db)
        }
        return LibrarySource(id: library.id!, url: url)
    }

    /// Each registered root holding its own copy of the same shot is two real files,
    /// so each library keeps its own row. When the content-hash rescue in
    /// `applyNewFile` wasn't scoped by library, the two roots fought over a single
    /// representation row: every reconcile pass repointed it at whichever library
    /// ran last, and `reassignRepresentation`'s `deletePhotoIfEmpty` then dropped the
    /// photo row the other library had been using — silently cascading away album
    /// membership and resetting the review verdict to `new` on every launch.
    func testTwoLibrariesHoldingTheSamePhotoKeepIndependentRowsAcrossRepeatedReconciles() async throws {
        let rootA = try makeTempDirectory()
        let rootB = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            for url in [rootA, rootB, exportRoot] { try? FileManager.default.removeItem(at: url) }
        }

        try Data("identical photo bytes".utf8).write(to: rootA.appendingPathComponent("IMG_0001.jpg"))
        try Data("identical photo bytes".utf8).write(to: rootB.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        let libraryA = try await registerLibrary(at: rootA, database: database, name: "A")
        let libraryB = try await registerLibrary(at: rootB, database: database, name: "B")
        let service = ReconciliationService(database: database)

        try await service.reconcile(photoLibraries: [libraryA, libraryB], exportFolder: exportRoot)

        let afterFirstPass = try await database.read { db in try Photo.fetchAll(db) }
        XCTAssertEqual(
            Set(afterFirstPass.map(\.libraryId)), [libraryA.id, libraryB.id],
            "each library should end up with its own photo row"
        )

        // Curate the copy in library A, then reconcile again the way the next app
        // launch would — the user's verdict and filing must survive it.
        let photoIdInA = afterFirstPass.first { $0.libraryId == libraryA.id }!.id!
        let albumId = try await database.write { db -> Int64 in
            let album = try AlbumRepository.createAlbum(name: "Keepers", now: 0, in: db)
            try AlbumRepository.addPhoto(photoId: photoIdInA, albumId: album.id!, now: 0, in: db)
            try PhotoRepository.setLifecycleState(photoId: photoIdInA, state: .candidate, now: 0, in: db)
            return album.id!
        }

        try await service.reconcile(photoLibraries: [libraryA, libraryB], exportFolder: exportRoot)

        let afterSecondPass = try await database.read { db in try Photo.fetchAll(db) }
        XCTAssertEqual(afterSecondPass.count, 2, "reconciling again must not collapse the two copies")

        let curated = try await database.read { db in try Photo.fetchOne(db, key: photoIdInA) }
        XCTAssertEqual(curated?.lifecycleState, .candidate, "review verdict must survive reconciliation")
        XCTAssertEqual(curated?.libraryId, libraryA.id, "the photo must stay in the library it was found in")

        let memberships = try await database.read { db in try AlbumRepository.orderedPhotoIds(albumId: albumId, in: db) }
        XCTAssertEqual(memberships, [photoIdInA], "album membership must survive reconciliation")
    }

    /// A file genuinely moved *within* one library is still recognized by content
    /// hash rather than re-indexed as a new photo — the behaviour the (previously
    /// unscoped) rescue exists for, which scoping it by library must not break.
    func testAMoveWithinOneLibraryIsStillRescuedByContentHash() async throws {
        let root = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            for url in [root, exportRoot] { try? FileManager.default.removeItem(at: url) }
        }

        let originalDir = root.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)
        try Data("some photo bytes".utf8).write(to: originalDir.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        let library = try await registerLibrary(at: root, database: database, name: "A")
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let representationId = try await database.read { db in try Representation.fetchAll(db).first!.id! }

        // Move and rename it — both the path and the provisional key change, so only
        // the content hash can still tie it to the existing row.
        let movedDir = root.appendingPathComponent("CameraB", isDirectory: true)
        try FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: originalDir.appendingPathComponent("IMG_0001.jpg"),
            to: movedDir.appendingPathComponent("RENAMED_0009.jpg")
        )

        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let representations = try await database.read { db in try Representation.fetchAll(db) }
        XCTAssertEqual(representations.count, 1, "the moved file must not be indexed as a second representation")
        XCTAssertEqual(representations.first?.id, representationId, "it must reuse the same row, not a new one")
        XCTAssertEqual(representations.first?.relativePath, "CameraB/RENAMED_0009.jpg")
    }
}
