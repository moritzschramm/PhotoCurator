import Foundation
import GRDB

/// Small generic key/value store for app state that doesn't warrant its own table
/// (spec §4): the first-run baseline flag, folder bookmarks, last snapshot time.
public enum AppStateRepository {

    public static func getString(_ key: String, in db: Database) throws -> String? {
        try AppStateEntry.fetchOne(db, key: key)?.value
    }

    public static func setString(_ value: String?, forKey key: String, in db: Database) throws {
        let entry = AppStateEntry(key: key, value: value)
        try entry.save(db)
    }

    public static func getBool(_ key: String, in db: Database) throws -> Bool {
        try getString(key, in: db) == "true"
    }

    public static func setBool(_ value: Bool, forKey key: String, in db: Database) throws {
        try setString(value ? "true" : "false", forKey: key, in: db)
    }

    public static func getData(_ key: String, in db: Database) throws -> Data? {
        guard let base64 = try getString(key, in: db) else { return nil }
        return Data(base64Encoded: base64)
    }

    public static func setData(_ value: Data?, forKey key: String, in db: Database) throws {
        try setString(value?.base64EncodedString(), forKey: key, in: db)
    }

    public static func getInt64(_ key: String, in db: Database) throws -> Int64? {
        try getString(key, in: db).flatMap { Int64($0) }
    }

    public static func setInt64(_ value: Int64?, forKey key: String, in db: Database) throws {
        try setString(value.map(String.init), forKey: key, in: db)
    }
}
