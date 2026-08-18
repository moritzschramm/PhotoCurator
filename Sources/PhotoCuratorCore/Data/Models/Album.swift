import GRDB

/// Albums are logical only (spec §7.5): a row here plus `PhotoAlbum` relations,
/// never a filesystem directory.
public struct Album: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64?
    public var name: String
    public var coverPhotoId: Int64?
    public var createdAt: Int64

    public init(id: Int64? = nil, name: String, coverPhotoId: Int64? = nil, createdAt: Int64) {
        self.id = id
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.createdAt = createdAt
    }
}

extension Album: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "albums"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverPhotoId = "cover_photo_id"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Album {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let coverPhotoId = Column(CodingKeys.coverPhotoId)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}

/// Junction row: album membership is a relation, orthogonal to lifecycle (spec §4).
/// `position` is the user's manual drag-and-drop order within the album (lower
/// sorts first); it is independent of `addedAt`, which is kept only as an
/// audit/tiebreak field.
public struct PhotoAlbum: Codable, Equatable, Sendable {
    public var photoId: Int64
    public var albumId: Int64
    public var addedAt: Int64
    public var position: Int64

    public init(photoId: Int64, albumId: Int64, addedAt: Int64, position: Int64) {
        self.photoId = photoId
        self.albumId = albumId
        self.addedAt = addedAt
        self.position = position
    }
}

extension PhotoAlbum: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "photo_albums"

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case albumId = "album_id"
        case addedAt = "added_at"
        case position
    }
}

extension PhotoAlbum {
    public enum Columns {
        public static let photoId = Column(CodingKeys.photoId)
        public static let albumId = Column(CodingKeys.albumId)
        public static let addedAt = Column(CodingKeys.addedAt)
        public static let position = Column(CodingKeys.position)
    }
}
