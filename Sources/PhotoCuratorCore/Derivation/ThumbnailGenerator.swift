import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ThumbnailSize: Sendable {
    case grid
    case preview

    var maxPixelSize: Int {
        switch self {
        case .grid: return 400
        case .preview: return 1600
        }
    }

    public var sizeClass: ThumbnailSizeClass {
        switch self {
        case .grid: return .grid
        case .preview: return .preview
        }
    }
}

public enum ThumbnailGeneratorError: Error {
    case cannotCreateImageSource
    case cannotCreateThumbnail
    case cannotEncode
    case cannotWrite
}

/// ImageIO-only thumbnail rendering (spec §1: no third-party RAW decoder). For RAW
/// sources this prefers the embedded preview (fast — the same fast path spec §7.4
/// wants for the initial JPG→RAW swap display); JPG sources are always freshly
/// downsampled so a small EXIF-embedded thumbnail can never masquerade as our cache.
public enum ThumbnailGenerator {
    @discardableResult
    public static func generate(
        from sourceURL: URL,
        kind: RepresentationKind,
        size: ThumbnailSize,
        destinationDirectory: URL
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ThumbnailGeneratorError.cannotCreateImageSource
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size.maxPixelSize
        ]
        if kind == .raw {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailGeneratorError.cannotCreateThumbnail
        }

        let filename = "\(UUID().uuidString).jpg"
        let destinationURL = destinationDirectory.appendingPathComponent(filename)

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ThumbnailGeneratorError.cannotEncode
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailGeneratorError.cannotWrite
        }

        return destinationURL
    }
}
