import Foundation

public enum DirectoryEnumerationError: Error {
    case cannotEnumerate(URL)
}

/// The outcome of one directory walk: the files found, plus whether the walk actually
/// saw everything.
///
/// `isComplete` is load-bearing rather than informational. Reconciliation treats a
/// known file that no enumerated file matched as deleted from disk and drops its row
/// — along with its review verdict, album membership and export history. A walk that
/// silently skipped an unreadable subdirectory (or hit a transient File Provider
/// error, which a Proton-backed folder does do) looks exactly like a mass deletion,
/// so callers must not act on absences from a partial walk.
public struct DirectoryEnumeration: Sendable {
    public var files: [EnumeratedFile]
    public var isComplete: Bool

    public init(files: [EnumeratedFile], isComplete: Bool) {
        self.files = files
        self.isComplete = isComplete
    }
}

/// Enumeration-only filesystem access (spec §2, §7.1): batch-fetches name, size,
/// dates, and File-Provider online-only status in one pass, and never opens a file's
/// bytes. Used for both the Proton photo folder and the export target.
public enum DirectoryEnumerator {
    /// `isUbiquitousItemKey`/`ubiquitousItemDownloadingStatusKey` are populated for any
    /// File-Provider-backed location (iCloud Drive, Proton Drive, etc.) — not an
    /// iCloud-only API, despite the "ubiquitous" naming.
    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .nameKey
    ]

    private static let resourceKeySet = Set(resourceKeys)

    /// Convenience for callers that only need the file list and don't reason about
    /// absences (import scanning, tests) — a partial walk there just means a few
    /// candidates aren't offered.
    public static func enumerateFiles(under root: URL) throws -> [EnumeratedFile] {
        try enumerate(under: root).files
    }

    public static func enumerate(under root: URL) throws -> DirectoryEnumeration {
        var results: [EnumeratedFile] = []
        var lastError: Error?
        var hadError = false

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                lastError = error
                hadError = true
                return true
            }
        ) else {
            throw DirectoryEnumerationError.cannotEnumerate(root)
        }

        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: resourceKeySet)
            } catch {
                lastError = error
                hadError = true
                continue
            }

            if values.isDirectory == true { continue }
            if values.isRegularFile == false { continue }

            results.append(
                EnumeratedFile(
                    url: url,
                    relativePath: url.relativePath(from: root),
                    filename: values.name ?? url.lastPathComponent,
                    fileSize: values.fileSize.map(Int64.init),
                    modificationDate: values.contentModificationDate,
                    isUbiquitous: values.isUbiquitousItem ?? false,
                    downloadingStatus: values.ubiquitousItemDownloadingStatus
                )
            )
        }

        // A walk that produced nothing *and* errored never got off the ground — that's
        // a hard failure, not an empty directory. A walk that errored partway still
        // returns what it found, flagged incomplete so callers don't read absences as
        // deletions.
        if results.isEmpty, let lastError {
            throw lastError
        }

        return DirectoryEnumeration(files: results, isComplete: !hadError)
    }
}
