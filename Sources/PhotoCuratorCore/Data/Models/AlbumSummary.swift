import Foundation

/// What the albums overview needs per album: the row itself, how many photos it
/// holds, and a cover thumbnail (spec §7.5, §8: "overview of all albums").
public struct AlbumSummary: Identifiable, Equatable, Sendable {
    public var album: Album
    public var photoCount: Int
    public var coverThumbnailPath: String?

    public init(album: Album, photoCount: Int, coverThumbnailPath: String?) {
        self.album = album
        self.photoCount = photoCount
        self.coverThumbnailPath = coverThumbnailPath
    }

    public var id: Int64 { album.id ?? 0 }
}
