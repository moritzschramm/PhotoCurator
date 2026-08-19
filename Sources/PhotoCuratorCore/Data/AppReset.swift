import Foundation
import GRDB

/// Wipes the app database back to a fresh-install state. Deletes only the three
/// tables with no incoming foreign key of their own — `photo_libraries`, `albums`,
/// `app_state` — and relies on `ON DELETE CASCADE` (see `AppMigrations`) to clear
/// every child transitively: photos, representations, exif, photo_albums, exports,
/// thumbnails. Every child FK is CASCADE except `albums.cover_photo_id` (`SET NULL`),
/// which is moot here since albums themselves are deleted in the same operation.
///
/// Never touches any file on disk that isn't purely app-owned derived data (see
/// `resetThumbnailCache` below) — original library files and already-exported files
/// live entirely outside the database and are never referenced by anything this
/// deletes.
public enum AppReset {
    public static func resetDatabase(_ database: AppDatabase) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM photo_libraries")
            try db.execute(sql: "DELETE FROM albums")
            try db.execute(sql: "DELETE FROM app_state")
        }
    }

    /// `directory` is explicit (not read internally from `AppPaths`) so this is
    /// unit-testable against a scratch temp directory — the real call site passes
    /// the real cache directory. Disposable derived data, not user data, so this
    /// uses a plain delete rather than the Trash.
    public static func resetThumbnailCache(directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
