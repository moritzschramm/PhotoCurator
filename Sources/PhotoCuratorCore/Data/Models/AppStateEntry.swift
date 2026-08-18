import GRDB

/// Generic key/value store for small pieces of app state that aren't worth their own
/// table: baseline flag, folder bookmarks, last snapshot time (spec §4).
public struct AppStateEntry: Codable, Equatable, Sendable {
    public var key: String
    public var value: String?

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

extension AppStateEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "app_state"
}

/// Well-known `app_state` keys.
public enum AppStateKey {
    public static let baselineEstablished = "baseline_established"
    public static let exportFolderBookmark = "export_folder_bookmark"
    public static let lastSnapshotAt = "last_snapshot_at"
    /// Last folder picked via the manual "Import…" button — a convenience so the
    /// user doesn't have to re-navigate to the SD card every time (spec §7.2 UX),
    /// not a hard-gated grant like the two `FolderRole` bookmarks above.
    public static let lastImportSourceBookmark = "last_import_source_bookmark"
}
