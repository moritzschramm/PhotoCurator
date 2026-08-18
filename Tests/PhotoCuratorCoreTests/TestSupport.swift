import Foundation
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
