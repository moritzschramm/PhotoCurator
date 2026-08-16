import Foundation

/// Provisional identity for a file that hasn't been content-hashed yet — filename +
/// size + mtime (spec §5). Filenames in the main library are stable, so this triples
/// as the best-effort match used to catch moves/renames before a content hash exists.
public struct ProvisionalKey: Hashable, Sendable {
    public var filename: String
    public var fileSize: Int64?
    public var fileMtime: Int64?

    public init(filename: String, fileSize: Int64?, fileMtime: Int64?) {
        self.filename = filename
        self.fileSize = fileSize
        self.fileMtime = fileMtime
    }
}

extension ProvisionalKey {
    public init(representation: Representation) {
        self.init(
            filename: representation.filename,
            fileSize: representation.fileSize,
            fileMtime: representation.fileMtime
        )
    }
}
