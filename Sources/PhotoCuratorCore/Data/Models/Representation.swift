import Foundation
import GRDB

public enum RepresentationKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case raw
    case jpg
}

public enum DerivationState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case underived
    case derived
}

/// A single file on disk (RAW or JPG) belonging to a `Photo`. Identity is two-phase:
/// provisional (filename + size + mtime) until `contentHash` is computed on
/// materialization, per spec §5.
public struct Representation: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64?
    public var libraryId: Int64
    public var photoId: Int64
    public var kind: RepresentationKind
    public var relativePath: String
    public var filename: String
    public var fileSize: Int64?
    public var fileMtime: Int64?
    public var contentHash: String?
    public var isLocal: Bool
    public var derivationState: DerivationState
    public var indexedAt: Int64

    public init(
        id: Int64? = nil,
        libraryId: Int64,
        photoId: Int64,
        kind: RepresentationKind,
        relativePath: String,
        filename: String,
        fileSize: Int64? = nil,
        fileMtime: Int64? = nil,
        contentHash: String? = nil,
        isLocal: Bool,
        derivationState: DerivationState = .underived,
        indexedAt: Int64
    ) {
        self.id = id
        self.libraryId = libraryId
        self.photoId = photoId
        self.kind = kind
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.contentHash = contentHash
        self.isLocal = isLocal
        self.derivationState = derivationState
        self.indexedAt = indexedAt
    }
}

extension Representation: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "representations"

    enum CodingKeys: String, CodingKey {
        case id
        case libraryId = "library_id"
        case photoId = "photo_id"
        case kind
        case relativePath = "relative_path"
        case filename
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
        case contentHash = "content_hash"
        case isLocal = "is_local"
        case derivationState = "derivation_state"
        case indexedAt = "indexed_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Representation {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let libraryId = Column(CodingKeys.libraryId)
        public static let photoId = Column(CodingKeys.photoId)
        public static let kind = Column(CodingKeys.kind)
        public static let relativePath = Column(CodingKeys.relativePath)
        public static let filename = Column(CodingKeys.filename)
        public static let fileSize = Column(CodingKeys.fileSize)
        public static let fileMtime = Column(CodingKeys.fileMtime)
        public static let contentHash = Column(CodingKeys.contentHash)
        public static let isLocal = Column(CodingKeys.isLocal)
        public static let derivationState = Column(CodingKeys.derivationState)
        public static let indexedAt = Column(CodingKeys.indexedAt)
    }

    public static let photo = belongsTo(Photo.self)
}

extension Representation {
    /// Absolute location of this representation's file, given the photo library root.
    public func fileURL(photoRoot: URL) -> URL {
        photoRoot.appendingPathComponent(relativePath)
    }
}

/// File extensions recognized for each representation kind (case-insensitive).
public enum RepresentationFileType {
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
        "orf", "rw2", "raf", "pef", "ptx", "dng", "raw", "3fr", "erf", "kdc", "mrw", "x3f"
    ]

    public static let jpgExtensions: Set<String> = ["jpg", "jpeg"]

    public static func kind(forExtension ext: String) -> RepresentationKind? {
        let lowered = ext.lowercased()
        if rawExtensions.contains(lowered) { return .raw }
        if jpgExtensions.contains(lowered) { return .jpg }
        return nil
    }

    public static var allRecognizedExtensions: Set<String> {
        rawExtensions.union(jpgExtensions)
    }
}
