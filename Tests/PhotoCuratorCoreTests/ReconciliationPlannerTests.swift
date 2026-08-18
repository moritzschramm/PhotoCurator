import XCTest
@testable import PhotoCuratorCore

final class ReconciliationPlannerTests: XCTestCase {
    private func makeFile(
        relativePath: String,
        filename: String,
        size: Int64 = 100,
        mtime: Int64 = 1000,
        isLocal: Bool = true
    ) -> EnumeratedFile {
        EnumeratedFile(
            url: URL(fileURLWithPath: "/tmp/photos/\(relativePath)"),
            relativePath: relativePath,
            filename: filename,
            fileSize: size,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime)),
            isUbiquitous: !isLocal,
            downloadingStatus: isLocal ? nil : .notDownloaded
        )
    }

    private func makeExisting(
        id: Int64 = 1,
        relativePath: String,
        filename: String,
        size: Int64 = 100,
        mtime: Int64 = 1000,
        isLocal: Bool = true
    ) -> Representation {
        Representation(
            id: id, libraryId: 1, photoId: id, kind: .jpg, relativePath: relativePath, filename: filename,
            fileSize: size, fileMtime: mtime, isLocal: isLocal, indexedAt: 1
        )
    }

    func testNewFileWithNoExistingRepresentations() {
        let file = makeFile(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg")
        let plan = ReconciliationPlanner.diff(files: [file], existing: [])

        XCTAssertEqual(plan.newFiles.count, 1)
        XCTAssertEqual(plan.newFiles.first?.basename, "IMG_0001")
        XCTAssertEqual(plan.newFiles.first?.kind, .jpg)
        XCTAssertTrue(plan.moved.isEmpty)
        XCTAssertTrue(plan.localStatusChanges.isEmpty)
        XCTAssertTrue(plan.unmatchedExistingIds.isEmpty)
    }

    func testUnchangedFileMatchesByPathAndProducesNoChanges() {
        let file = makeFile(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg")
        let existing = makeExisting(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg")

        let plan = ReconciliationPlanner.diff(files: [file], existing: [existing])

        XCTAssertTrue(plan.newFiles.isEmpty)
        XCTAssertTrue(plan.moved.isEmpty)
        XCTAssertTrue(plan.localStatusChanges.isEmpty)
        XCTAssertTrue(plan.unmatchedExistingIds.isEmpty)
    }

    func testLocalStatusChangeDetectedWhenOnlineOnlyStatusFlips() {
        let file = makeFile(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg", isLocal: true)
        let existing = makeExisting(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg", isLocal: false)

        let plan = ReconciliationPlanner.diff(files: [file], existing: [existing])

        XCTAssertEqual(plan.localStatusChanges.count, 1)
        XCTAssertEqual(plan.localStatusChanges.first?.representationId, 1)
        XCTAssertEqual(plan.localStatusChanges.first?.isLocal, true)
    }

    func testMoveDetectedByProvisionalKeyWhenPathChanges() {
        // Same filename/size/mtime at a different path => a move, not a new file.
        let file = makeFile(relativePath: "CameraB/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 100, mtime: 1000)
        let existing = makeExisting(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 100, mtime: 1000)

        let plan = ReconciliationPlanner.diff(files: [file], existing: [existing])

        XCTAssertEqual(plan.moved.count, 1)
        XCTAssertEqual(plan.moved.first?.representationId, 1)
        XCTAssertEqual(plan.moved.first?.file.relativePath, "CameraB/IMG_0001.jpg")
        XCTAssertTrue(plan.newFiles.isEmpty)
        XCTAssertTrue(plan.unmatchedExistingIds.isEmpty)
    }

    func testDifferentProvisionalKeyIsNotTreatedAsAMove() {
        // Different size => not the same file, even at the same filename.
        let file = makeFile(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 999, mtime: 1000)
        let existing = makeExisting(id: 1, relativePath: "CameraB/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 100, mtime: 1000)

        let plan = ReconciliationPlanner.diff(files: [file], existing: [existing])

        XCTAssertEqual(plan.newFiles.count, 1)
        XCTAssertTrue(plan.moved.isEmpty)
        XCTAssertEqual(plan.unmatchedExistingIds, [1])
    }

    func testMissingFileBecomesUnmatched() {
        let existing = makeExisting(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg")
        let plan = ReconciliationPlanner.diff(files: [], existing: [existing])

        XCTAssertEqual(plan.unmatchedExistingIds, [1])
    }

    func testUnrecognizedExtensionIsIgnored() {
        let file = makeFile(relativePath: "CameraA/notes.txt", filename: "notes.txt")
        let plan = ReconciliationPlanner.diff(files: [file], existing: [])

        XCTAssertTrue(plan.newFiles.isEmpty)
    }

    func testRawAndJpgSiblingsBothBecomeNewFilesUnderSameBasename() {
        let raw = makeFile(relativePath: "CameraA/IMG_0001.CR3", filename: "IMG_0001.CR3")
        let jpg = makeFile(relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg")
        let plan = ReconciliationPlanner.diff(files: [raw, jpg], existing: [])

        XCTAssertEqual(plan.newFiles.count, 2)
        XCTAssertTrue(plan.newFiles.allSatisfy { $0.basename == "IMG_0001" })
        XCTAssertEqual(Set(plan.newFiles.map(\.kind)), [.raw, .jpg])
    }

    func testEachExistingRepresentationIsMatchedAtMostOnce() {
        // Two candidate files with identical provisional keys (e.g. duplicate
        // filenames staged under different directories) must not both claim the
        // same existing row as a "move".
        let fileA = makeFile(relativePath: "CameraB/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 100, mtime: 1000)
        let fileB = makeFile(relativePath: "CameraC/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 100, mtime: 1000)
        let existing = makeExisting(id: 1, relativePath: "CameraA/IMG_0001.jpg", filename: "IMG_0001.jpg", size: 100, mtime: 1000)

        let plan = ReconciliationPlanner.diff(files: [fileA, fileB], existing: [existing])

        XCTAssertEqual(plan.moved.count, 1)
        XCTAssertEqual(plan.newFiles.count, 1)
    }
}
