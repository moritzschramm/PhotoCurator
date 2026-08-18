import Foundation

/// Persists and resolves security-scoped bookmarks: the single export/gallery target
/// (spec §9, stored in `app_state`, base64-encoded) and every registered photo library
/// (stored as a native BLOB column on its own `photo_libraries` row instead — see
/// `PhotoLibraryRepository` — since there can be several, unlike the export target).
public enum BookmarkStore {
    /// Creates the bookmark itself — synchronous on purpose. A URL handed back by an
    /// open/save panel (e.g. SwiftUI's `.fileImporter`, or `NSOpenPanel`) is only
    /// guaranteed security-scoped for a short window right after the panel closes;
    /// deferring this into an `async` `Task` risks that window lapsing before
    /// `bookmarkData(options:)` runs, which silently fails to produce a usable
    /// bookmark. Call this directly from the picker's completion handler, then hand
    /// the resulting `Data` to whichever save function is relevant (no such
    /// constraint applies to the database write itself).
    public static func makeBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves any bookmark `Data` into a `SecurityScopedFolder`, re-persisting a
    /// fresh bookmark via `onStale` when macOS reports the existing one as stale (e.g.
    /// the folder was moved/renamed within the same volume). Shared by the export
    /// target and every photo library's own resolution below.
    private static func resolveFolder(from data: Data, onStale: (Data) async throws -> Void) async throws -> SecurityScopedFolder {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            let fresh = try makeBookmarkData(for: url)
            try await onStale(fresh)
        }
        return SecurityScopedFolder(url: url)
    }

    // MARK: Export target (single, fixed slot in app_state)

    public static func saveExportBookmarkData(_ bookmark: Data, database: AppDatabase) async throws {
        try await database.write { db in
            try AppStateRepository.setData(bookmark, forKey: AppStateKey.exportFolderBookmark, in: db)
        }
    }

    public static func saveExportTarget(url: URL, database: AppDatabase) async throws {
        try await saveExportBookmarkData(try makeBookmarkData(for: url), database: database)
    }

    public static func resolveExportTarget(database: AppDatabase) async throws -> SecurityScopedFolder? {
        guard let data = try await database.read({ db in
            try AppStateRepository.getData(AppStateKey.exportFolderBookmark, in: db)
        }) else {
            return nil
        }
        return try await resolveFolder(from: data) { fresh in
            try await saveExportBookmarkData(fresh, database: database)
        }
    }

    public static func clearExportTarget(database: AppDatabase) async throws {
        try await database.write { db in
            try AppStateRepository.setData(nil, forKey: AppStateKey.exportFolderBookmark, in: db)
        }
    }

    // MARK: Photo libraries (one row per library in `photo_libraries`)

    /// Resolves every registered `PhotoLibrary` row, transparently re-persisting any
    /// stale bookmark to its own row.
    public static func resolveAllPhotoLibraries(database: AppDatabase) async throws -> [PhotoLibraryFolder] {
        let libraries = try await database.read { db in try PhotoLibraryRepository.fetchAll(in: db) }
        var resolved: [PhotoLibraryFolder] = []
        for library in libraries {
            guard let id = library.id else { continue }
            let folder = try await resolveFolder(from: library.bookmarkData) { fresh in
                try await database.write { db in
                    try PhotoLibraryRepository.updateBookmarkData(id: id, bookmarkData: fresh, in: db)
                }
            }
            resolved.append(PhotoLibraryFolder(id: id, name: library.name, folder: folder))
        }
        return resolved
    }

    public static func resolveAll(database: AppDatabase) async throws -> FolderAccessStatus {
        async let libraries = resolveAllPhotoLibraries(database: database)
        async let exportTarget = resolveExportTarget(database: database)
        return FolderAccessStatus(photoLibraries: try await libraries, exportTarget: try await exportTarget)
    }

    // MARK: Last import source (convenience only, not a hard-gated grant)

    /// `bookmark` should come from `makeBookmarkData`, called synchronously in the
    /// picker's own completion handler for the same reason as above — this half
    /// (the actual DB write) has no such timing constraint, so it's fine to await.
    public static func saveLastImportSourceBookmarkData(_ bookmark: Data, database: AppDatabase) async {
        try? await database.write { db in
            try AppStateRepository.setData(bookmark, forKey: AppStateKey.lastImportSourceBookmark, in: db)
        }
    }

    /// Best-effort: unlike the folder-grant resolution above, a failure here (folder
    /// moved, stale bookmark, nothing saved yet) just means the picker falls back to
    /// its default starting location — never worth surfacing as an error.
    public static func resolveLastImportSource(database: AppDatabase) async -> URL? {
        guard let data = try? await database.read({ db -> Data? in
            try AppStateRepository.getData(AppStateKey.lastImportSourceBookmark, in: db)
        }) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
