import Foundation
import GRDB
@testable import PhotoCuratorCore

func makeInMemoryDatabase() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let dbQueue = try DatabaseQueue(configuration: configuration)
    try AppMigrations.makeMigrator().migrate(dbQueue)
    return dbQueue
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
