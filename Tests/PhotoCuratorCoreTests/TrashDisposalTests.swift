import XCTest
@testable import PhotoCuratorCore

/// These tests genuinely move a scratch file into and out of the real macOS Trash —
/// there's no way to sandbox `FileManager.trashItem`. They never assume a fixed Trash
/// path (that varies by volume), only that the URL the API itself reports back is
/// where the file actually landed.
final class TrashDisposalTests: XCTestCase {
    func testMoveToTrashThenRestoreRoundTrips() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("trash-disposal-test-\(UUID().uuidString).jpg")
        let contents = Data("some photo bytes".utf8)
        try contents.write(to: originalURL)

        let trashedURL = try TrashDisposal.moveToTrash(originalURL)
        defer { try? FileManager.default.removeItem(at: trashedURL) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path), "the original path must no longer have a file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path), "the file must exist at the URL the API reported")

        let restoredURL = directory.appendingPathComponent("restored-\(UUID().uuidString).jpg")
        try TrashDisposal.restore(from: trashedURL, to: restoredURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedURL.path), "restore should move, not copy, out of the Trash")
        XCTAssertEqual(try Data(contentsOf: restoredURL), contents)
    }

    func testRestoreRecreatesMissingIntermediateDirectories() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("nested-source-\(UUID().uuidString).jpg")
        try Data("bytes".utf8).write(to: originalURL)
        let trashedURL = try TrashDisposal.moveToTrash(originalURL)
        defer { try? FileManager.default.removeItem(at: trashedURL) }

        let nestedDestination = directory
            .appendingPathComponent("does-not-exist-yet", isDirectory: true)
            .appendingPathComponent("restored.jpg")
        try TrashDisposal.restore(from: trashedURL, to: nestedDestination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedDestination.path))
    }
}
