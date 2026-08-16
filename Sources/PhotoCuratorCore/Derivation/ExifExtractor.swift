import Foundation
import ImageIO

public struct ExtractedExif: Sendable, Equatable {
    public var cameraModel: String?
    public var lens: String?
    public var iso: Int?
    public var aperture: Double?
    public var shutter: String?
    public var focalLength: Double?
    public var orientation: Int?
    public var gpsLat: Double?
    public var gpsLng: Double?
    public var captureDate: Date?

    public init(
        cameraModel: String? = nil,
        lens: String? = nil,
        iso: Int? = nil,
        aperture: Double? = nil,
        shutter: String? = nil,
        focalLength: Double? = nil,
        orientation: Int? = nil,
        gpsLat: Double? = nil,
        gpsLng: Double? = nil,
        captureDate: Date? = nil
    ) {
        self.cameraModel = cameraModel
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
        self.orientation = orientation
        self.gpsLat = gpsLat
        self.gpsLng = gpsLng
        self.captureDate = captureDate
    }
}

public enum ExifExtractorError: Error {
    case cannotCreateImageSource
    case cannotReadProperties
}

/// Metadata-only read via ImageIO — does not decode pixel data, so it's cheap even
/// for large RAW files (spec §1).
public enum ExifExtractor {
    public static func extract(from url: URL) throws -> ExtractedExif {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ExifExtractorError.cannotCreateImageSource
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw ExifExtractorError.cannotReadProperties
        }

        let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]

        var result = ExtractedExif()
        result.cameraModel = tiffDict?[kCGImagePropertyTIFFModel as String] as? String
        result.lens = exifDict?[kCGImagePropertyExifLensModel as String] as? String

        if let isoArray = exifDict?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let first = isoArray.first {
            result.iso = first.intValue
        }
        if let aperture = exifDict?[kCGImagePropertyExifFNumber as String] as? NSNumber {
            result.aperture = aperture.doubleValue
        }
        if let exposure = exifDict?[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            result.shutter = formatShutter(exposure.doubleValue)
        }
        if let focalLength = exifDict?[kCGImagePropertyExifFocalLength as String] as? NSNumber {
            result.focalLength = focalLength.doubleValue
        }
        if let orientation = properties[kCGImagePropertyOrientation as String] as? NSNumber {
            result.orientation = orientation.intValue
        }

        if let lat = (gpsDict?[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue {
            let ref = gpsDict?[kCGImagePropertyGPSLatitudeRef as String] as? String
            result.gpsLat = (ref == "S") ? -lat : lat
        }
        if let lng = (gpsDict?[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue {
            let ref = gpsDict?[kCGImagePropertyGPSLongitudeRef as String] as? String
            result.gpsLng = (ref == "W") ? -lng : lng
        }

        result.captureDate = captureDate(exifDict: exifDict, tiffDict: tiffDict)

        return result
    }

    private static func formatShutter(_ exposureSeconds: Double) -> String {
        guard exposureSeconds > 0 else { return "" }
        if exposureSeconds >= 1 {
            return String(format: "%.1fs", exposureSeconds)
        }
        let denominator = (1.0 / exposureSeconds).rounded()
        return "1/\(Int(denominator))"
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func captureDate(exifDict: [String: Any]?, tiffDict: [String: Any]?) -> Date? {
        if let dateString = exifDict?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let date = exifDateFormatter.date(from: dateString) {
            return date
        }
        if let dateString = tiffDict?[kCGImagePropertyTIFFDateTime as String] as? String,
           let date = exifDateFormatter.date(from: dateString) {
            return date
        }
        return nil
    }
}
