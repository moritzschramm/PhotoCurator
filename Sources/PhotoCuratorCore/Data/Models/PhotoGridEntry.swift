import Foundation

/// What the grid (and any grid-shaped view, like an album browse) needs to render one
/// tile: the photo/representations plus whichever cached grid-size thumbnail is ready
/// to show, without an extra per-cell database query while scrolling.
public struct PhotoGridEntry: Identifiable, Equatable, Sendable {
    public var photo: PhotoWithRepresentations
    public var gridThumbnailPath: String?

    public init(photo: PhotoWithRepresentations, gridThumbnailPath: String?) {
        self.photo = photo
        self.gridThumbnailPath = gridThumbnailPath
    }

    public var id: Int64 { photo.id }
}
