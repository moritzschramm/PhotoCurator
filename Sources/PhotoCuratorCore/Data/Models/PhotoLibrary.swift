import Foundation
import GRDB

/// A registered photo-library root directory. The app supports several of these
/// (unlike the export target, which stays a single folder) — each owns its own
/// security-scoped bookmark, and every `Photo`/`Representation` belongs to exactly
/// one via `library_id`.
public struct PhotoLibrary: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64?
    public var name: String
    public var bookmarkData: Data
    public var displayOrder: Int64
    public var createdAt: Int64

    public init(
        id: Int64? = nil,
        name: String,
        bookmarkData: Data,
        displayOrder: Int64,
        createdAt: Int64
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.displayOrder = displayOrder
        self.createdAt = createdAt
    }
}

extension PhotoLibrary: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "photo_libraries"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case bookmarkData = "bookmark_data"
        case displayOrder = "display_order"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PhotoLibrary {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let bookmarkData = Column(CodingKeys.bookmarkData)
        public static let displayOrder = Column(CodingKeys.displayOrder)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}
