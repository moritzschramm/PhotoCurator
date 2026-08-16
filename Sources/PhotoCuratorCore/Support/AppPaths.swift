import Foundation

/// Filesystem locations owned by the app (spec §3). Originals and the export target
/// are user-selected via security-scoped bookmarks and never hardcoded here — this
/// type only knows about the app's own local state in Application Support.
public enum AppPaths {
    /// `~/Library/Application Support/PhotoCurator/` — created on first access.
    /// Application Support (not Caches) is used even for thumbnails, because
    /// regenerating a thumbnail for an evicted/online-only original means
    /// re-downloading it, which is expensive (spec §3).
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("PhotoCurator", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func liveDatabaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("PhotoCurator.sqlite")
    }

    public static func thumbnailCacheDirectory() throws -> URL {
        let dir = try applicationSupportDirectory().appendingPathComponent("Thumbnails", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Fixed filename for the consistent snapshot written into the Proton folder
    /// (spec §3). Always overwritten in place — never the live `.sqlite`/-wal/-shm.
    public static let snapshotFilename = "PhotoCurator-backup.sqlite"
}
