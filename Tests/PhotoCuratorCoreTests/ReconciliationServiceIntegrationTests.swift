import XCTest
@testable import PhotoCuratorCore

/// Exercises `ReconciliationService` against real files on a real temp directory —
/// the pure `ReconciliationPlannerTests` cover the diff logic in isolation, this
/// covers the enumeration → diff → apply → baseline pipeline end to end.
final class ReconciliationServiceIntegrationTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    /// Registers a `photo_libraries` row for `url` and returns the matching
    /// `LibrarySource` to pass to `reconcile(photoLibraries:...)`.
    private func registerLibrary(at url: URL, database: AppDatabase, name: String = "Test Library") async throws -> LibrarySource {
        let library = try await database.write { db in
            try PhotoLibraryRepository.create(name: name, bookmarkData: Data(), now: 0, in: db)
        }
        return LibrarySource(id: library.id!, url: url)
    }

    func testFirstRunIndexesFilesGroupsSiblingsAndEstablishesBaseline() async throws {
        let photoRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: photoRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let cameraDir = photoRoot.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDir, withIntermediateDirectories: true)
        try Data("fake jpg bytes".utf8).write(to: cameraDir.appendingPathComponent("IMG_0001.jpg"))
        try Data("fake raw bytes".utf8).write(to: cameraDir.appendingPathComponent("IMG_0001.CR3"))
        try Data("fake jpg bytes 2".utf8).write(to: cameraDir.appendingPathComponent("IMG_0002.jpg"))

        let database = try makeDatabase()
        let library = try await registerLibrary(at: photoRoot, database: database)
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 2)

        let img1 = photos.first { $0.photo.basename == "IMG_0001" }
        XCTAssertEqual(img1?.representations.count, 2, "RAW+JPG siblings must group under one Photo")
        XCTAssertNotNil(img1?.jpg)
        XCTAssertNotNil(img1?.raw)
        // Indexing deliberately reads no file bytes: the only thing a hash buys at
        // this stage is rescuing a row whose file went missing, and a first index has
        // no such rows. Content hashes are filled in by the derivation pass that runs
        // after reconciliation (see `DerivationQueue.processLocalBacklog`).
        XCTAssertNil(img1?.jpg?.contentHash)

        // First-run baseline (spec §6): everything from the initial index is
        // `reviewed`, not `new`.
        XCTAssertTrue(photos.allSatisfy { $0.photo.lifecycleState == .accepted })
        let baselineFlag = try await database.read { db in
            try AppStateRepository.getBool(AppStateKey.baselineEstablished, in: db)
        }
        XCTAssertTrue(baselineFlag)
    }

    func testFilesDiscoveredAfterBaselineAreMarkedNew() async throws {
        let photoRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: photoRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let cameraDir = photoRoot.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDir, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: cameraDir.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        let library = try await registerLibrary(at: photoRoot, database: database)
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        try Data("second".utf8).write(to: cameraDir.appendingPathComponent("IMG_0002.jpg"))
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.first { $0.photo.basename == "IMG_0001" }?.photo.lifecycleState, .accepted)
        XCTAssertEqual(photos.first { $0.photo.basename == "IMG_0002" }?.photo.lifecycleState, .new)
    }

    func testRemovedFileIsDeletedOnNextReconcile() async throws {
        let photoRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: photoRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let cameraDir = photoRoot.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDir, withIntermediateDirectories: true)
        let fileURL = cameraDir.appendingPathComponent("IMG_0001.jpg")
        try Data("first".utf8).write(to: fileURL)

        let database = try makeDatabase()
        let library = try await registerLibrary(at: photoRoot, database: database)
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        try FileManager.default.removeItem(at: fileURL)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertTrue(photos.isEmpty, "a photo whose only file disappeared should be removed, not left dangling")
    }

    /// Deleting a row takes its review verdict, album membership and export history
    /// with it, and there's no way back. A library that suddenly appears mostly empty
    /// is far more often a folder that didn't mount (or a sync client that hasn't
    /// populated it yet) than a user deleting most of their photos behind the app's
    /// back, so a pass like that is left alone entirely. Ordinary deletions, and
    /// libraries below the size floor, still reconcile immediately — see
    /// `testRemovedFileIsDeletedOnNextReconcile`.
    func testAnImplausibleMassDisappearanceDoesNotDeleteRows() async throws {
        let photoRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: photoRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let cameraDir = photoRoot.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDir, withIntermediateDirectories: true)
        let fileURLs = (1...25).map { cameraDir.appendingPathComponent("IMG_\($0).jpg") }
        for (index, url) in fileURLs.enumerated() {
            try Data("photo \(index)".utf8).write(to: url)
        }

        let database = try makeDatabase()
        let library = try await registerLibrary(at: photoRoot, database: database)
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        // A plausible deletion — a fifth of the library — is applied as usual.
        for url in fileURLs.prefix(5) { try FileManager.default.removeItem(at: url) }
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)
        var photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 20, "an ordinary deletion should still be reconciled")

        // Most of what's left vanishing at once is not treated as a deletion.
        for url in fileURLs.dropFirst(5).prefix(15) { try FileManager.default.removeItem(at: url) }
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)
        photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 20, "a mass disappearance should be ignored, not applied")
    }

    func testMovingAFileToADifferentSubdirectoryReconcilesRatherThanDuplicates() async throws {
        let photoRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: photoRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let cameraADir = photoRoot.appendingPathComponent("CameraA", isDirectory: true)
        let cameraBDir = photoRoot.appendingPathComponent("CameraB", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cameraBDir, withIntermediateDirectories: true)
        let originalURL = cameraADir.appendingPathComponent("IMG_0001.jpg")
        try Data("first".utf8).write(to: originalURL)

        let database = try makeDatabase()
        let library = try await registerLibrary(at: photoRoot, database: database)
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        // Preserve mtime so the provisional key (filename+size+mtime) still matches
        // after the move, exactly like a Finder move would.
        let attributes = try FileManager.default.attributesOfItem(atPath: originalURL.path)
        let movedURL = cameraBDir.appendingPathComponent("IMG_0001.jpg")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: movedURL.path)

        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 1, "a move must reconcile the existing row, not create a duplicate")
        XCTAssertEqual(photos.first?.photo.sourceDir, "CameraB")
        XCTAssertEqual(photos.first?.jpg?.relativePath, "CameraB/IMG_0001.jpg")
    }

    func testReconcileIsIdempotentWhenNothingChanged() async throws {
        let photoRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: photoRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let cameraDir = photoRoot.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDir, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: cameraDir.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        let library = try await registerLibrary(at: photoRoot, database: database)
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)
        try await service.reconcile(photoLibraries: [library], exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.representations.count, 1)
    }

    func testTwoLibrariesWithIdenticalRelativePathsDoNotCrossMatch() async throws {
        let libraryARoot = try makeTempDirectory()
        let libraryBRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryARoot)
            try? FileManager.default.removeItem(at: libraryBRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let cameraDirA = libraryARoot.appendingPathComponent("CameraA", isDirectory: true)
        let cameraDirB = libraryBRoot.appendingPathComponent("CameraA", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cameraDirB, withIntermediateDirectories: true)
        // Same relative path ("CameraA/IMG_0001.jpg") and same basename in both
        // libraries — only `library_id` scoping keeps these from colliding or being
        // mistaken for a move of one another.
        try Data("library A bytes".utf8).write(to: cameraDirA.appendingPathComponent("IMG_0001.jpg"))
        try Data("library B bytes, different content".utf8).write(to: cameraDirB.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        let libraryA = try await registerLibrary(at: libraryARoot, database: database, name: "Library A")
        let libraryB = try await registerLibrary(at: libraryBRoot, database: database, name: "Library B")
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoLibraries: [libraryA, libraryB], exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 2, "identical relative paths under two different libraries must not collide into one Photo")

        let libraryIds = Set(photos.map(\.photo.libraryId))
        XCTAssertEqual(libraryIds, [libraryA.id, libraryB.id], "each photo must be tagged with its own library, not the other's")
    }
}
