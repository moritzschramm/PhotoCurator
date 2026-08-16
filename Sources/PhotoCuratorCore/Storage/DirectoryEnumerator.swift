import Foundation

public enum DirectoryEnumerationError: Error {
    case cannotEnumerate(URL)
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

    public static func enumerateFiles(under root: URL) throws -> [EnumeratedFile] {
        var results: [EnumeratedFile] = []
        var lastError: Error?

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                lastError = error
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

        if results.isEmpty, let lastError {
            throw lastError
        }

        return results
    }
}
