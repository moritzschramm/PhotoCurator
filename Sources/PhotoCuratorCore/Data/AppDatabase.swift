import Foundation
import GRDB

/// Owns the live database connection pool. There is exactly one `AppDatabase` per app
/// run. `DatabasePool` gives WAL mode plus GRDB's single-writer/multiple-reader model
/// for free, which is what spec §7.3 means by "background queue with a single DB writer."
public final class AppDatabase: @unchecked Sendable {
    public let dbPool: DatabasePool

    public init(path: URL) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        self.dbPool = try DatabasePool(path: path.path, configuration: configuration)
        try AppMigrations.makeMigrator().migrate(dbPool)
    }

    /// Convenience initializer over the standard Application Support location.
    public static func openDefault() throws -> AppDatabase {
        try AppDatabase(path: AppPaths.liveDatabaseURL())
    }

    @discardableResult
    public func write<T>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbPool.write(updates)
    }

    public func read<T>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbPool.read(value)
    }

    /// A write that is *not* wrapped in GRDB's implicit transaction. Needed only for
    /// the handful of statements SQLite refuses to run inside one — `VACUUM INTO`
    /// (see `SnapshotService`) being the case this exists for. Everything else must
    /// go through `write`, which keeps its batch atomic.
    @discardableResult
    public func writeWithoutTransaction<T: Sendable>(
        _ updates: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await dbPool.writeWithoutTransaction(updates)
    }

    /// Synchronous write for call sites already off the main thread (e.g. inside the
    /// import or derivation pipelines' own background queues).
    @discardableResult
    public func writeSync<T>(_ updates: (Database) throws -> T) throws -> T {
        try dbPool.write(updates)
    }

    public func readSync<T>(_ value: (Database) throws -> T) throws -> T {
        try dbPool.read(value)
    }
}
