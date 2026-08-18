import XCTest
@testable import PhotoCuratorCore

/// Exercises `ExportService`'s album plan/apply flow against real files on a real
/// temp directory — the filesystem-existence dedup check in particular needs actual
/// files on disk to mean anything.
final class ExportServiceIntegrationTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    private func makeService(database: AppDatabase) throws -> ExportService {
        let thumbDir = try makeTempDirectory()
        let derivation = DerivationService(database: database, thumbnailCacheDirectory: thumbDir)
        let queue = DerivationQueue(database: database, derivationService: derivation)
        return ExportService(database: database, derivationQueue: queue)
    }

    @discardableResult
    private func makePhoto(
        libraryId: Int64,
        basename: String,
        jpgURL: URL,
        contents: Data,
        lifecycleState: LifecycleState = .accepted,
        database: AppDatabase
    ) async throws -> Int64 {
        try contents.write(to: jpgURL)
        return try await database.write { db in
            var photo = try PhotoRepository.upsertPhoto(libraryId: libraryId, basename: basename, sourceDir: "", captureDate: nil, now: 1, in: db)
            photo.lifecycleState = lifecycleState
            try photo.update(db)
            try PhotoRepository.insertRepresentation(
                Representation(
                    libraryId: libraryId, photoId: photo.id!, kind: .jpg, relativePath: jpgURL.lastPathComponent,
                    filename: jpgURL.lastPathComponent, fileSize: Int64(contents.count),
                    // A pre-set content hash means `exportOnePhoto` never needs to
                    // materialize/derive the file — these fake bytes aren't a real
                    // decodable image, which would otherwise fail thumbnail generation.
                    contentHash: "hash-\(basename)", isLocal: true, indexedAt: 1
                ),
                in: db
            )
            return photo.id!
        }
    }

    func testPlanBucketsAcceptedUnexportedPhotoAsToExport() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in
            try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id!
        }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001",
            jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
            contents: Data("fake jpg bytes".utf8), database: database
        )
        let albumId = try await database.write { db in
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: photoId, albumId: album.id!, now: 1, in: db)
            return album.id!
        }

        let service = try makeService(database: database)
        let plan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(plan.toExport.map(\.photoId), [photoId])
        XCTAssertTrue(plan.toSkip.isEmpty)
        XCTAssertTrue(plan.toRemove.isEmpty)
    }

    func testApplyExportsThenSubsequentPlanSkipsUpToDateFile() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in
            try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id!
        }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001",
            jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
            contents: Data("fake jpg bytes".utf8), database: database
        )
        let albumId = try await database.write { db in
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: photoId, albumId: album.id!, now: 1, in: db)
            return album.id!
        }

        let service = try makeService(database: database)
        let plan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        let results = await service.applyAlbumExportPlan(plan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.skippedAsDuplicate, false)

        let filesInCategory = try FileManager.default.contentsOfDirectory(atPath: exportRoot.appendingPathComponent("Landscapes").path)
        XCTAssertEqual(filesInCategory, ["IMG_0001.jpg"])

        // Simulate the `exports` log drifting from what's actually on disk (e.g. a
        // fresh install) — the filesystem check should still recognize the file.
        try await database.write { db in try db.execute(sql: "DELETE FROM exports") }

        let secondPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(secondPlan.toSkip.map(\.photoId), [photoId], "should recognize the file already at the destination even with no log entry")
        XCTAssertTrue(secondPlan.toExport.isEmpty)
    }

    func testDowngradedPhotoIsRemovedFromDiskOnNextExport() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in
            try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id!
        }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001",
            jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
            contents: Data("fake jpg bytes".utf8), database: database
        )
        let albumId = try await database.write { db in
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: photoId, albumId: album.id!, now: 1, in: db)
            return album.id!
        }

        let service = try makeService(database: database)
        let firstPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        _ = await service.applyAlbumExportPlan(firstPlan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })

        // Downgraded from accepted to candidate after being exported — the whole
        // point of this feature: the export folder must stop reflecting it.
        try await database.write { db in
            try PhotoRepository.setLifecycleState(photoId: photoId, state: .candidate, now: 2, in: db)
        }

        let secondPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(secondPlan.toRemove.map(\.photoId), [photoId])
        XCTAssertTrue(secondPlan.toExport.isEmpty)
        XCTAssertTrue(secondPlan.toSkip.isEmpty)

        let removeResults = await service.applyAlbumExportPlan(secondPlan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })
        XCTAssertEqual(removeResults.first?.wasRemoved, true)

        let filesInCategory = try FileManager.default.contentsOfDirectory(atPath: exportRoot.appendingPathComponent("Landscapes").path)
        XCTAssertTrue(filesInCategory.isEmpty, "the file must actually be deleted from the export folder")

        let remainingRecords = try await database.read { db in try ExportRepository.fetchAll(category: "Landscapes", in: db) }
        XCTAssertTrue(remainingRecords.isEmpty, "the log entry must be cleaned up too")
    }

    func testRemovedFromAlbumPhotoIsAlsoRemovedFromDisk() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in
            try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id!
        }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001",
            jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
            contents: Data("fake jpg bytes".utf8), database: database
        )
        let albumId = try await database.write { db in
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: photoId, albumId: album.id!, now: 1, in: db)
            return album.id!
        }

        let service = try makeService(database: database)
        let firstPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        _ = await service.applyAlbumExportPlan(firstPlan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })

        // Still accepted, but no longer in the album at all.
        try await database.write { db in try AlbumRepository.removePhoto(photoId: photoId, albumId: albumId, in: db) }

        let secondPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(secondPlan.toRemove.map(\.photoId), [photoId])
    }

    func testExportDoesNotSkipDifferentPhotoWithCollidingFilename() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        // Pre-populate the destination with an unrelated file that happens to share
        // the exact filename, but a different size — e.g. a different camera's own
        // IMG_0001.jpg exported previously.
        let categoryDir = exportRoot.appendingPathComponent("Landscapes", isDirectory: true)
        try FileManager.default.createDirectory(at: categoryDir, withIntermediateDirectories: true)
        try Data("unrelated existing file".utf8).write(to: categoryDir.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        let libraryId = try await database.write { db in
            try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id!
        }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001",
            jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
            contents: Data("different camera's IMG_0001.jpg".utf8), database: database
        )
        let albumId = try await database.write { db in
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: photoId, albumId: album.id!, now: 1, in: db)
            return album.id!
        }

        let service = try makeService(database: database)
        let plan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(plan.toExport.map(\.photoId), [photoId], "a different photo with a colliding filename must not be treated as a duplicate")

        let results = await service.applyAlbumExportPlan(plan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.skippedAsDuplicate, false)

        let filesInCategory = try FileManager.default.contentsOfDirectory(atPath: categoryDir.path).sorted()
        XCTAssertEqual(filesInCategory, ["IMG_0001-2.jpg", "IMG_0001.jpg"], "the new photo should land under a disambiguated name, not overwrite or get skipped")
    }
}
