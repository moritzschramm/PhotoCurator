import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import PhotoCuratorCore

/// Seeds one default `photo_libraries` row (id 1) so existing tests that don't care
/// about multi-library specifics can keep inserting `Photo`/`Representation` rows
/// with the schema's default `library_id` without hitting the (correct, intentional)
/// foreign key constraint on an otherwise-nonexistent library.
func makeInMemoryDatabase() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let dbQueue = try DatabaseQueue(configuration: configuration)
    try AppMigrations.makeMigrator().migrate(dbQueue)
    try dbQueue.write { db in
        try db.execute(
            sql: "INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at) VALUES (1, 'Test Library', X'00', 0, 0)"
        )
    }
    return dbQueue
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

enum TestImageError: Error {
    case couldNotWrite
}

/// Writes a real (tiny) JPEG. Derivation goes through ImageIO, which produces neither
/// a thumbnail nor EXIF for a file of arbitrary bytes — so any test that runs the
/// derivation pipeline needs a genuine image rather than placeholder `Data`.
func writeJPEG(to url: URL, gray: CGFloat = 0.5) throws {
    guard let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw TestImageError.couldNotWrite }
    context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
          )
    else { throw TestImageError.couldNotWrite }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TestImageError.couldNotWrite }
}
