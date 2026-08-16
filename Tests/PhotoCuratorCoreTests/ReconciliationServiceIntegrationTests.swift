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
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 2)

        let img1 = photos.first { $0.photo.basename == "IMG_0001" }
        XCTAssertEqual(img1?.representations.count, 2, "RAW+JPG siblings must group under one Photo")
        XCTAssertNotNil(img1?.jpg)
        XCTAssertNotNil(img1?.raw)
        // Local files are hashed opportunistically as part of indexing, so this
        // should already carry a content hash without a separate derivation pass.
        XCTAssertNotNil(img1?.jpg?.contentHash)

        // First-run baseline (spec §6): everything from the initial index is
        // `reviewed`, not `new`.
        XCTAssertTrue(photos.allSatisfy { $0.photo.lifecycleState == .reviewed })
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
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        try Data("second".utf8).write(to: cameraDir.appendingPathComponent("IMG_0002.jpg"))
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.first { $0.photo.basename == "IMG_0001" }?.photo.lifecycleState, .reviewed)
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
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        try FileManager.default.removeItem(at: fileURL)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertTrue(photos.isEmpty, "a photo whose only file disappeared should be removed, not left dangling")
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
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        // Preserve mtime so the provisional key (filename+size+mtime) still matches
        // after the move, exactly like a Finder move would.
        let attributes = try FileManager.default.attributesOfItem(atPath: originalURL.path)
        let movedURL = cameraBDir.appendingPathComponent("IMG_0001.jpg")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: movedURL.path)

        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

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
        let service = ReconciliationService(database: database)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)
        try await service.reconcile(photoFolder: photoRoot, exportFolder: exportRoot)

        let photos = try await database.read { db in try PhotoRepository.fetchAllPhotosWithRepresentations(db) }
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.representations.count, 1)
    }
}
