import Foundation

/// Persists and resolves the app-scoped security-scoped bookmarks for the two
/// first-run folder grants: the Proton photo library and the export/gallery target
/// (spec §9). Bookmarks are stored in `app_state`, base64-encoded, so they live in the
/// same irreplaceable database as everything else — never in `UserDefaults`.
public enum BookmarkStore {
    /// Creates the bookmark itself — synchronous on purpose. A URL handed back by an
    /// open/save panel (e.g. SwiftUI's `.fileImporter`) is only guaranteed
    /// security-scoped for a short window right after the panel closes; deferring
    /// this into an `async` `Task` risks that window lapsing before
    /// `bookmarkData(options:)` runs, which silently fails to produce a usable
    /// bookmark. Call this directly from the picker's completion handler, then hand
    /// the resulting `Data` to `saveBookmarkData` (which has no such constraint).
    public static func makeBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func saveBookmarkData(_ bookmark: Data, role: FolderRole, database: AppDatabase) async throws {
        try await database.write { db in
            try AppStateRepository.setData(bookmark, forKey: role.appStateKey, in: db)
        }
    }

    public static func save(url: URL, role: FolderRole, database: AppDatabase) async throws {
        let bookmark = try makeBookmarkData(for: url)
        try await saveBookmarkData(bookmark, role: role, database: database)
    }

    /// Resolves the persisted bookmark for `role`, if any. Transparently re-persists a
    /// fresh bookmark when macOS reports the existing one as stale (e.g. the folder was
    /// moved or renamed within the same volume).
    public static func resolve(role: FolderRole, database: AppDatabase) async throws -> SecurityScopedFolder? {
        guard let data = try await database.read({ db in
            try AppStateRepository.getData(role.appStateKey, in: db)
        }) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try await save(url: url, role: role, database: database)
        }
        return SecurityScopedFolder(url: url)
    }

    public static func resolveAll(database: AppDatabase) async throws -> FolderAccessStatus {
        FolderAccessStatus(
            photoLibrary: try await resolve(role: .photoLibrary, database: database),
            exportTarget: try await resolve(role: .exportTarget, database: database)
        )
    }

    public static func clear(role: FolderRole, database: AppDatabase) async throws {
        try await database.write { db in
            try AppStateRepository.setData(nil, forKey: role.appStateKey, in: db)
        }
    }
}
