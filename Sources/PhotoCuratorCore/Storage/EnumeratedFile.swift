import Foundation

/// One file found by directory enumeration, with the batch-fetched resource values
/// needed to reconcile it against the database — never the file's bytes (spec §2).
public struct EnumeratedFile: Sendable, Equatable {
    public var url: URL
    /// Path relative to the enumeration root, e.g. "CanonR5/IMG_0001.CR3".
    public var relativePath: String
    public var filename: String
    public var fileSize: Int64?
    public var modificationDate: Date?
    public var isUbiquitous: Bool
    public var downloadingStatus: URLUbiquitousItemDownloadingStatus?

    public init(
        url: URL,
        relativePath: String,
        filename: String,
        fileSize: Int64?,
        modificationDate: Date?,
        isUbiquitous: Bool,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?
    ) {
        self.url = url
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isUbiquitous = isUbiquitous
        self.downloadingStatus = downloadingStatus
    }

    /// Per-camera subdirectory: the first path component of `relativePath`.
    public var sourceDir: String {
        relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    public var fileMtimeEpoch: Int64? {
        modificationDate.map { Int64($0.timeIntervalSince1970) }
    }

    /// Materialized-on-disk status. Plain local files (not File-Provider-backed at
    /// all) are always local; File-Provider items (Proton's placeholders) are local
    /// only once fully downloaded.
    public var isLocal: Bool {
        guard isUbiquitous else { return true }
        return downloadingStatus == .current || downloadingStatus == .downloaded
    }

    public var fileExtension: String {
        (filename as NSString).pathExtension
    }
}
