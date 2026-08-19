import Foundation
import GRDB

/// Reclaims thumbnail cache files that no `thumbnails` row points at any more.
///
/// `DerivationService` deletes the pair of files it supersedes when it re-derives a
/// representation, but rows can also disappear by *cascade* — a representation
/// dropped by reconciliation, or a whole library removed — and those paths can't be
/// cleaned up at the moment they're deleted: undo of a library removal restores those
/// exact rows and depends on their cached files still being on disk (see
/// `PhotoLibraryRepository.snapshot`). Sweeping instead at launch resolves that
/// cleanly, because the undo stack is session-only and therefore provably empty at
/// that point — nothing can still be waiting to restore a row that points here.
public enum ThumbnailCacheMaintenance {
    /// Deletes every file sitting directly in `directory` that isn't referenced by a
    /// `thumbnails.cache_path`, and returns how many it removed. Non-recursive and
    /// best-effort: an unreadable directory or an undeletable file is skipped rather
    /// than surfaced, since this is opportunistic housekeeping, never a correctness
    /// requirement.
    ///
    /// Must only be called when nothing is deriving concurrently — a thumbnail whose
    /// file is written but whose row hasn't been committed yet would otherwise look
    /// exactly like an orphan.
    ///
    /// Matching is by *filename*, not full path, and that's load-bearing rather than
    /// lazy: `contentsOfDirectory` hands back symlink-resolved URLs (`/var/...`
    /// becomes `/private/var/...`), so comparing whole path strings against the
    /// stored ones can decide every single live thumbnail is an orphan and empty the
    /// whole cache. Filenames are `ThumbnailGenerator`'s UUIDs, so they're already
    /// unique enough to be the real identity here, and the failure mode this biases
    /// toward — keeping a file that a row in some *other* directory happens to name —
    /// costs disk space rather than a thumbnail.
    @discardableResult
    public static func sweepOrphans(directory: URL, database: AppDatabase) async -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        guard let referencedPaths = try? await database.read({ db in
            try String.fetchSet(db, sql: "SELECT cache_path FROM thumbnails")
        }) else { return 0 }
        let referencedFilenames = Set(referencedPaths.map { ($0 as NSString).lastPathComponent })

        var removed = 0
        for url in contents where !referencedFilenames.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
