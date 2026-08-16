import Foundation

/// Read model combining a `Photo` with its `Representation` rows — what the grid,
/// close-up view, and export flow actually operate on. A photo may have only a RAW
/// representation, only a JPG, or both (spec §4).
public struct PhotoWithRepresentations: Identifiable, Equatable, Sendable {
    public var photo: Photo
    public var representations: [Representation]

    public init(photo: Photo, representations: [Representation]) {
        self.photo = photo
        self.representations = representations
    }

    public var id: Int64 { photo.id ?? 0 }

    public var jpg: Representation? { representations.first { $0.kind == .jpg } }
    public var raw: Representation? { representations.first { $0.kind == .raw } }

    /// True once at least one representation has finished thumbnail/EXIF/hash derivation.
    public var hasAnyDerivedRepresentation: Bool {
        representations.contains { $0.derivationState == .derived }
    }

    /// True when every representation is still online-only (cloud placeholder).
    public var isFullyOnlineOnly: Bool {
        !representations.isEmpty && representations.allSatisfy { !$0.isLocal }
    }
}
