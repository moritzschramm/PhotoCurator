import Foundation
import CoreImage
import CoreGraphics
import ImageIO

public enum RawImageRendererError: Error {
    case cannotCreateFilter
    case cannotProduceImage
    case cannotCreateCGImage
}

/// Full-quality RAW rendering via Core Image's `CIRAWFilter` — the same ImageIO/Core
/// Image engine Finder, Preview, and Quick Look use (spec §7.4), so the render
/// matches what Quick Look would show. Viewing only: no exposure/white-balance/etc.
/// adjustment controls are exposed here (RAW editing is deferred, spec §11).
public enum RawImageRenderer {
    private static let ciContext = CIContext()

    /// `CIRAWFilter` has been available since macOS 12, below this app's macOS 14
    /// minimum, so no `#available` guard is needed to call `supportedCameraModels`
    /// itself — this just answers whether a *specific* camera is on the list.
    public static func isCameraModelSupported(_ model: String?) -> Bool {
        guard let model, !model.isEmpty else { return true }
        return CIRAWFilter.supportedCameraModels.contains(model)
    }

    /// Renders a RAW file to a `CGImage`, optionally capped at `maxPixelSize` on the
    /// long edge (via `CIRAWFilter.scaleFactor`, which is cheaper than rendering full
    /// size and downsampling after). Uses Core Image's default decode (auto exposure/
    /// white balance as shot) with no user adjustment.
    public static func render(fileURL: URL, maxPixelSize: CGFloat? = nil) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: fileURL) else {
            throw RawImageRendererError.cannotCreateFilter
        }

        if let maxPixelSize {
            filter.scaleFactor = scaleFactor(for: fileURL, maxPixelSize: maxPixelSize)
        }

        guard let outputImage = filter.outputImage else {
            throw RawImageRendererError.cannotProduceImage
        }
        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw RawImageRendererError.cannotCreateCGImage
        }
        return cgImage
    }

    private static func scaleFactor(for fileURL: URL, maxPixelSize: CGFloat) -> Float {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              max(width, height) > 0
        else {
            return 1.0
        }
        return Float(min(1.0, Double(maxPixelSize) / max(width, height)))
    }
}
