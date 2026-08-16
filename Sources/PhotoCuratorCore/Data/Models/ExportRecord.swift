import GRDB

/// Export log: source of truth for "already published" (spec §7.6). Dedup is by
/// content hash *plus* category/destination — never by re-hashing target files, since
/// the external gallery-builder may rewrite them after export.
public struct ExportRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64?
    public var photoId: Int64
    public var representationId: Int64
    public var contentHash: String
    public var category: String?
    public var destinationPath: String
    public var exportedAt: Int64

    public init(
        id: Int64? = nil,
        photoId: Int64,
        representationId: Int64,
        contentHash: String,
        category: String? = nil,
        destinationPath: String,
        exportedAt: Int64
    ) {
        self.id = id
        self.photoId = photoId
        self.representationId = representationId
        self.contentHash = contentHash
        self.category = category
        self.destinationPath = destinationPath
        self.exportedAt = exportedAt
    }
}

extension ExportRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "exports"

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case representationId = "representation_id"
        case contentHash = "content_hash"
        case category
        case destinationPath = "destination_path"
        case exportedAt = "exported_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ExportRecord {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let photoId = Column(CodingKeys.photoId)
        public static let representationId = Column(CodingKeys.representationId)
        public static let contentHash = Column(CodingKeys.contentHash)
        public static let category = Column(CodingKeys.category)
        public static let destinationPath = Column(CodingKeys.destinationPath)
        public static let exportedAt = Column(CodingKeys.exportedAt)
    }
}
