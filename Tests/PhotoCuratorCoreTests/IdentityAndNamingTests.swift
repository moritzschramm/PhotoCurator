import XCTest
import CryptoKit
@testable import PhotoCuratorCore

final class ContentHasherTests: XCTestCase {
    func testMatchesDirectCryptoKitComputationAcrossChunkBoundaries() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.bin")
        var data = Data()
        for i in 0..<5000 { data.append(UInt8(i % 256)) }
        try data.write(to: fileURL)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // Small chunk size relative to the file forces the read loop through
        // several iterations, exercising chunk-boundary handling.
        let actual = try ContentHasher.sha256(ofFileAt: fileURL, chunkSize: 512)

        XCTAssertEqual(actual, expected)
    }

    func testEmptyFile() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("empty.bin")
        try Data().write(to: fileURL)

        let expected = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ContentHasher.sha256(ofFileAt: fileURL), expected)
    }
}

final class ProvisionalKeyTests: XCTestCase {
    func testEqualityIgnoresFilenameCaseSensitively() {
        let a = ProvisionalKey(filename: "IMG_0001.jpg", fileSize: 100, fileMtime: 1000)
        let b = ProvisionalKey(filename: "IMG_0001.jpg", fileSize: 100, fileMtime: 1000)
        let c = ProvisionalKey(filename: "img_0001.jpg", fileSize: 100, fileMtime: 1000)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testUsableAsDictionaryKey() {
        let key = ProvisionalKey(filename: "IMG_0001.jpg", fileSize: 100, fileMtime: 1000)
        var dict: [ProvisionalKey: Int] = [:]
        dict[key] = 1
        XCTAssertEqual(dict[ProvisionalKey(filename: "IMG_0001.jpg", fileSize: 100, fileMtime: 1000)], 1)
    }
}

final class RepresentationFileTypeTests: XCTestCase {
    func testRawExtensionsAreCaseInsensitive() {
        XCTAssertEqual(RepresentationFileType.kind(forExtension: "CR3"), .raw)
        XCTAssertEqual(RepresentationFileType.kind(forExtension: "cr3"), .raw)
        XCTAssertEqual(RepresentationFileType.kind(forExtension: "dng"), .raw)
    }

    func testJpgExtensions() {
        XCTAssertEqual(RepresentationFileType.kind(forExtension: "jpg"), .jpg)
        XCTAssertEqual(RepresentationFileType.kind(forExtension: "JPEG"), .jpg)
    }

    func testUnrecognizedExtensionReturnsNil() {
        XCTAssertNil(RepresentationFileType.kind(forExtension: "txt"))
        XCTAssertNil(RepresentationFileType.kind(forExtension: "db"))
    }
}

final class CameraSubdirectoryNamingTests: XCTestCase {
    func testSanitizeReplacesSpacesWithUnderscores() {
        XCTAssertEqual(CameraSubdirectoryNaming.sanitize("Canon EOS R5"), "Canon_EOS_R5")
    }

    func testSanitizeReplacesDisallowedCharacters() {
        XCTAssertEqual(CameraSubdirectoryNaming.sanitize("NIKON:Z9"), "NIKON_Z9")
    }

    func testSuggestedSubdirectoryFallsBackWhenNoCameraModel() {
        XCTAssertEqual(CameraSubdirectoryNaming.suggestedSubdirectory(cameraModel: nil), CameraSubdirectoryNaming.fallback)
        XCTAssertEqual(CameraSubdirectoryNaming.suggestedSubdirectory(cameraModel: "   "), CameraSubdirectoryNaming.fallback)
    }

    func testSuggestedSubdirectoryUsesSanitizedCameraModel() {
        XCTAssertEqual(CameraSubdirectoryNaming.suggestedSubdirectory(cameraModel: "Canon EOS R5"), "Canon_EOS_R5")
    }
}
