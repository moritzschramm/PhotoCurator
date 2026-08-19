import Foundation

public enum TrashDisposalError: Error, LocalizedError {
    case noResultingURL

    public var errorDescription: String? {
        "The file was trashed, but macOS did not report its Trash location."
    }
}

/// Wraps `FileManager.trashItem(at:resultingItemURL:)` so undoable actions that
/// delete a real file as a side effect (import undo, export removal) send it to the
/// user's Trash instead of permanently removing it — recoverable via Finder
/// independent of the app's own (session-only) undo history, and what a subsequent
/// `redo()` moves back from.
public enum TrashDisposal {
    @discardableResult
    public static func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let trashedURL = resultingURL as URL? else { throw TrashDisposalError.noResultingURL }
        return trashedURL
    }

    /// Moves a previously-trashed file back to `destinationURL` — used by `redo()`
    /// after an `undo()` trashed it. Recreates any missing intermediate directory,
    /// mirroring the destination-directory creation import/export already do.
    public static func restore(from trashedURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: trashedURL, to: destinationURL)
    }
}
