import GRDB

/// Curation status of a shot. "In an album" is NOT a lifecycle state — it is derived
/// from `photo_albums` membership (see `Album`/`PhotoAlbum`). A photo can be, e.g.,
/// `published` and in two albums at once.
public enum LifecycleState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case new
    case reviewed
    case candidate
    case published
    case rejected
}

/// One logical photo per shot, grouped by `basename` within `sourceDir`. Owns one or
/// more `Representation` rows (RAW and/or JPG).
public struct Photo: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64?
    public var basename: String
    public var sourceDir: String
    public var captureDate: Int64?
    public var lifecycleState: LifecycleState
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: Int64? = nil,
        basename: String,
        sourceDir: String,
        captureDate: Int64? = nil,
        lifecycleState: LifecycleState = .new,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.basename = basename
        self.sourceDir = sourceDir
        self.captureDate = captureDate
        self.lifecycleState = lifecycleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Photo: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "photos"

    enum CodingKeys: String, CodingKey {
        case id
        case basename
        case sourceDir = "source_dir"
        case captureDate = "capture_date"
        case lifecycleState = "lifecycle_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Photo {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let basename = Column(CodingKeys.basename)
        public static let sourceDir = Column(CodingKeys.sourceDir)
        public static let captureDate = Column(CodingKeys.captureDate)
        public static let lifecycleState = Column(CodingKeys.lifecycleState)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
