import XCTest
@testable import PhotoCuratorCore

/// Exercises `ExportService.undoExport`/`redoExport` against real files on a real
/// temp directory — the three `ExportUndoRecord` cases (exported/renamed/removed)
/// each have distinct file-move semantics that only mean something with actual files
/// on disk.
final class ExportUndoRedoTests: XCTestCase {
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
        libraryId: Int64, basename: String, jpgURL: URL, contents: Data, database: AppDatabase
    ) async throws -> Int64 {
        try contents.write(to: jpgURL)
        return try await database.write { db in
            var photo = try PhotoRepository.upsertPhoto(libraryId: libraryId, basename: basename, sourceDir: "", captureDate: nil, now: 1, in: db)
            photo.lifecycleState = .accepted
            try photo.update(db)
            try PhotoRepository.insertRepresentation(
                Representation(
                    libraryId: libraryId, photoId: photo.id!, kind: .jpg, relativePath: jpgURL.lastPathComponent,
                    filename: jpgURL.lastPathComponent, fileSize: Int64(contents.count),
                    contentHash: "hash-\(basename)", isLocal: true, indexedAt: 1
                ),
                in: db
            )
            return photo.id!
        }
    }

    func testUndoOfExportTrashesFileAndRemovesRecordThenRedoRestoresBoth() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id! }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001", jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
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
        let undoRecords = results.compactMap(\.undoInfo)
        XCTAssertEqual(undoRecords.count, 1)

        let categoryDir = exportRoot.appendingPathComponent("Landscapes", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: categoryDir.path), ["Landscapes-1.jpg"])

        let (_, trashedURLs) = await service.undoExport(undoRecords, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: categoryDir.path).isEmpty, "undo must trash the exported file")
        let remainingRecords = try await database.read { db in try ExportRepository.fetchAll(category: "Landscapes", in: db) }
        XCTAssertTrue(remainingRecords.isEmpty, "undo must remove the log row")
        XCTAssertEqual(trashedURLs.count, 1)

        _ = await service.redoExport(undoRecords, trashedURLs: trashedURLs, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: categoryDir.path), ["Landscapes-1.jpg"], "redo must restore the file")
        let restoredRecords = try await database.read { db in try ExportRepository.fetchAll(category: "Landscapes", in: db) }
        XCTAssertEqual(restoredRecords.map(\.photoId), [photoId])
    }

    func testUndoOfSwapRenameReversesBothWithoutDuplicating() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id! }
        let firstPhotoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001", jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
            contents: Data("first photo".utf8), database: database
        )
        let secondPhotoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0002", jpgURL: libraryRoot.appendingPathComponent("IMG_0002.jpg"),
            contents: Data("second photo".utf8), database: database
        )
        let albumId = try await database.write { db in
            let album = try AlbumRepository.createAlbum(name: "Landscapes", now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: firstPhotoId, albumId: album.id!, now: 1, in: db)
            try AlbumRepository.addPhoto(photoId: secondPhotoId, albumId: album.id!, now: 2, in: db)
            return album.id!
        }

        let service = try makeService(database: database)
        let firstPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        _ = await service.applyAlbumExportPlan(firstPlan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })

        try await database.write { db in
            try AlbumRepository.reorderPhotos(albumId: albumId, orderedPhotoIds: [secondPhotoId, firstPhotoId], in: db)
        }
        let secondPlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        let renameResults = await service.applyAlbumExportPlan(secondPlan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })
        let undoRecords = renameResults.compactMap(\.undoInfo)
        XCTAssertEqual(undoRecords.count, 2)

        let categoryDir = exportRoot.appendingPathComponent("Landscapes", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: categoryDir.appendingPathComponent("Landscapes-1.jpg")), Data("second photo".utf8))
        XCTAssertEqual(try Data(contentsOf: categoryDir.appendingPathComponent("Landscapes-2.jpg")), Data("first photo".utf8))

        let (undoOutcome, _) = await service.undoExport(undoRecords, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(undoOutcome.filter(\.success).count, 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: categoryDir.path).sorted(),
            ["Landscapes-1.jpg", "Landscapes-2.jpg"], "still exactly two files after reversing the swap"
        )
        XCTAssertEqual(try Data(contentsOf: categoryDir.appendingPathComponent("Landscapes-1.jpg")), Data("first photo".utf8))
        XCTAssertEqual(try Data(contentsOf: categoryDir.appendingPathComponent("Landscapes-2.jpg")), Data("second photo".utf8))

        // Redo re-applies the swap — reconstructed from the same original
        // `undoRecords` (no trashedURLs needed, renames never touch the Trash).
        let redoOutcome = await service.redoExport(undoRecords, trashedURLs: [:], category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(redoOutcome.filter(\.success).count, 2)
        XCTAssertEqual(try Data(contentsOf: categoryDir.appendingPathComponent("Landscapes-1.jpg")), Data("second photo".utf8))
        XCTAssertEqual(try Data(contentsOf: categoryDir.appendingPathComponent("Landscapes-2.jpg")), Data("first photo".utf8))
    }

    func testUndoOfRemoveRestoresFileAndRecordThenRedoRemovesAgain() async throws {
        let libraryRoot = try makeTempDirectory()
        let exportRoot = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        let database = try makeDatabase()
        let libraryId = try await database.write { db in try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id! }
        let photoId = try await makePhoto(
            libraryId: libraryId, basename: "IMG_0001", jpgURL: libraryRoot.appendingPathComponent("IMG_0001.jpg"),
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

        try await database.write { db in try PhotoRepository.setLifecycleState(photoId: photoId, state: .candidate, now: 2, in: db) }
        let removePlan = await service.planAlbumExport(albumId: albumId, category: "Landscapes", exportFolderURL: exportRoot)
        let removeResults = await service.applyAlbumExportPlan(removePlan, category: "Landscapes", exportFolderURL: exportRoot, libraryRootURL: { _ in libraryRoot })
        let undoRecords = removeResults.compactMap(\.undoInfo)
        XCTAssertEqual(undoRecords.count, 1)

        let categoryDir = exportRoot.appendingPathComponent("Landscapes", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: categoryDir.path).isEmpty)

        _ = await service.undoExport(undoRecords, category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: categoryDir.path), ["Landscapes-1.jpg"], "undo must restore the removed file")
        let restoredRecords = try await database.read { db in try ExportRepository.fetchAll(category: "Landscapes", in: db) }
        XCTAssertEqual(restoredRecords.map(\.photoId), [photoId])

        _ = await service.redoExport(undoRecords, trashedURLs: [:], category: "Landscapes", exportFolderURL: exportRoot)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: categoryDir.path).isEmpty, "redo must remove it again")
        let finalRecords = try await database.read { db in try ExportRepository.fetchAll(category: "Landscapes", in: db) }
        XCTAssertTrue(finalRecords.isEmpty)
    }
}
