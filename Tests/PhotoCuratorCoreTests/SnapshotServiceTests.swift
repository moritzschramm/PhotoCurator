import XCTest
import GRDB
@testable import PhotoCuratorCore

/// `VACUUM INTO` cannot run inside a transaction, which is exactly what GRDB's
/// `write` opens — so every snapshot used to fail with "cannot VACUUM from within a
/// transaction", and the failure was swallowed by the service's best-effort error
/// handling. Nothing noticed because nothing asserted that a file appeared.
final class SnapshotServiceTests: XCTestCase {
    private func makeDatabase(in directory: URL) throws -> AppDatabase {
        try AppDatabase(path: directory.appendingPathComponent("live.sqlite"))
    }

    func testWriteSnapshotProducesAReadableBackupFile() async throws {
        let supportDirectory = try makeTempDirectory()
        let protonFolder = try makeTempDirectory()
        defer {
            for url in [supportDirectory, protonFolder] { try? FileManager.default.removeItem(at: url) }
        }

        let database = try makeDatabase(in: supportDirectory)
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at) VALUES (1, 'L', X'00', 0, 0)"
            )
            let photo = try PhotoRepository.upsertPhoto(
                libraryId: 1, basename: "IMG_0001", sourceDir: "CameraA", captureDate: nil, now: 0, in: db
            )
            try PhotoRepository.insertRepresentation(
                Representation(
                    libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "CameraA/IMG_0001.jpg",
                    filename: "IMG_0001.jpg", isLocal: true, indexedAt: 0
                ),
                in: db
            )
        }

        let service = SnapshotService(database: database)
        try await service.writeSnapshot(protonFolderURL: protonFolder)

        let snapshotURL = protonFolder.appendingPathComponent(AppPaths.snapshotFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "a snapshot file must actually be written")

        // Readable as a database, with the live content in it — not just a file of
        // the right name.
        let restored = try DatabaseQueue(path: snapshotURL.path)
        let photoCount = try await restored.read { db in try Photo.fetchCount(db) }
        XCTAssertEqual(photoCount, 1)

        let lastSnapshotAt = try await database.read { db in
            try AppStateRepository.getInt64(AppStateKey.lastSnapshotAt, in: db)
        }
        XCTAssertNotNil(lastSnapshotAt, "a successful snapshot records when it happened")
    }

    /// `VACUUM INTO` refuses to write to an existing path, so a second snapshot has to
    /// go through the temp-file-and-replace dance rather than targeting the final name.
    func testSnapshottingTwiceReplacesThePreviousBackup() async throws {
        let supportDirectory = try makeTempDirectory()
        let protonFolder = try makeTempDirectory()
        defer {
            for url in [supportDirectory, protonFolder] { try? FileManager.default.removeItem(at: url) }
        }

        let database = try makeDatabase(in: supportDirectory)
        let service = SnapshotService(database: database)
        try await service.writeSnapshot(protonFolderURL: protonFolder)

        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at) VALUES (7, 'Added later', X'00', 0, 0)"
            )
        }
        try await service.writeSnapshot(protonFolderURL: protonFolder)

        let snapshotURL = protonFolder.appendingPathComponent(AppPaths.snapshotFilename)
        let restored = try DatabaseQueue(path: snapshotURL.path)
        let libraryCount = try await restored.read { db in try PhotoLibrary.fetchCount(db) }
        XCTAssertEqual(libraryCount, 1, "the second snapshot should reflect the newer state")

        // No leftover `.PhotoCurator-backup.sqlite.tmp-…` staging files.
        let strays = try FileManager.default.contentsOfDirectory(atPath: protonFolder.path)
            .filter { $0.hasPrefix(".") && $0.contains("tmp-") }
        XCTAssertTrue(strays.isEmpty, "temp snapshot files should not be left behind: \(strays)")
    }
}
