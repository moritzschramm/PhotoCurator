import XCTest
@testable import PhotoCuratorCore

/// Import dedup is per destination library, matching how reconciliation treats two
/// registered roots: a byte-identical copy under a *different* root is a separate
/// real file with its own row, so its existence says nothing about whether the
/// library being imported into already holds this shot. Matching globally made
/// importing a card into a second library report every file as already imported.
final class ImportScopingTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    private func makePipeline(database: AppDatabase, cacheDirectory: URL) -> ImportPipeline {
        ImportPipeline(
            database: database,
            derivationService: DerivationService(database: database, thumbnailCacheDirectory: cacheDirectory)
        )
    }

    func testAFileAlreadyPresentInAnotherLibraryStillCountsAsNew() async throws {
        let cardFolder = try makeTempDirectory()
        let cacheDirectory = try makeTempDirectory()
        defer {
            for url in [cardFolder, cacheDirectory] { try? FileManager.default.removeItem(at: url) }
        }

        let contents = Data("some photo bytes".utf8)
        try contents.write(to: cardFolder.appendingPathComponent("IMG_0001.jpg"))

        let database = try makeDatabase()
        try await database.write { db in
            for id in 1...2 {
                try db.execute(
                    sql: "INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at) VALUES (?, ?, X'00', ?, 0)",
                    arguments: [id, "Library \(id)", id]
                )
            }
            // Library 1 already holds this exact file; library 2 does not.
            let photo = try PhotoRepository.upsertPhoto(
                libraryId: 1, basename: "IMG_0001", sourceDir: "", captureDate: nil, now: 0, in: db
            )
            try PhotoRepository.insertRepresentation(
                Representation(
                    libraryId: 1, photoId: photo.id!, kind: .jpg, relativePath: "IMG_0001.jpg",
                    filename: "IMG_0001.jpg", fileSize: Int64(contents.count), fileMtime: 1,
                    isLocal: true, indexedAt: 0
                ),
                in: db
            )
        }

        let pipeline = makePipeline(database: database, cacheDirectory: cacheDirectory)

        let intoLibrary1 = try await pipeline.scan(sourceFolder: cardFolder, targetLibraryId: 1)
        XCTAssertEqual(intoLibrary1.first?.files.first?.isAlreadyImported, true,
                       "the library that already holds this file should report it as a duplicate")

        let intoLibrary2 = try await pipeline.scan(sourceFolder: cardFolder, targetLibraryId: 2)
        XCTAssertEqual(intoLibrary2.first?.files.first?.isAlreadyImported, false,
                       "a copy under a different library must not mark this one as already imported")
        XCTAssertEqual(intoLibrary2.first?.newFileCount, 1)
    }

    /// The copy step hashes the source as it streams the bytes through rather than
    /// re-reading the file, then verifies by hashing what actually landed on disk.
    func testCopyAndHashMatchesAPlainHashOfTheSameBytes() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately larger than the 1 MiB streaming chunk, so the multi-chunk path
        // is what's exercised.
        let sourceURL = directory.appendingPathComponent("source.bin")
        var bytes = Data()
        bytes.reserveCapacity(3_000_000)
        for index in 0..<3_000_000 { bytes.append(UInt8(index % 251)) }
        try bytes.write(to: sourceURL)

        let destinationURL = directory.appendingPathComponent("copy.bin")
        let streamedHash = try ContentHasher.copy(from: sourceURL, to: destinationURL)

        XCTAssertEqual(streamedHash, try ContentHasher.sha256(ofFileAt: sourceURL))
        XCTAssertEqual(streamedHash, try ContentHasher.sha256(ofFileAt: destinationURL))
        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)
    }
}
