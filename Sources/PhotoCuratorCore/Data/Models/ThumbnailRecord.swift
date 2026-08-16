import GRDB

public enum ThumbnailSizeClass: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case grid
    case preview
}

/// Manifest row for a thumbnail file cached in Application Support (spec §3, §4).
/// The image bytes live on disk at `cachePath`; this table just indexes them.
public struct ThumbnailRecord: Codable, Equatable, Sendable {
    public var representationId: Int64
    public var sizeClass: ThumbnailSizeClass
    public var cachePath: String

    public init(representationId: Int64, sizeClass: ThumbnailSizeClass, cachePath: String) {
        self.representationId = representationId
        self.sizeClass = sizeClass
        self.cachePath = cachePath
    }
}

extension ThumbnailRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thumbnails"

    enum CodingKeys: String, CodingKey {
        case representationId = "representation_id"
        case sizeClass = "size_class"
        case cachePath = "cache_path"
    }
}
