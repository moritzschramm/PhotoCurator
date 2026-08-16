import GRDB

/// EXIF metadata for a single representation. One row per representation (RAW and JPG
/// siblings may carry slightly different EXIF, so this is keyed by representation, not photo).
public struct ExifRecord: Codable, Equatable, Sendable {
    public var representationId: Int64
    public var cameraModel: String?
    public var lens: String?
    public var iso: Int?
    public var aperture: Double?
    public var shutter: String?
    public var focalLength: Double?
    public var orientation: Int?
    public var gpsLat: Double?
    public var gpsLng: Double?

    public init(
        representationId: Int64,
        cameraModel: String? = nil,
        lens: String? = nil,
        iso: Int? = nil,
        aperture: Double? = nil,
        shutter: String? = nil,
        focalLength: Double? = nil,
        orientation: Int? = nil,
        gpsLat: Double? = nil,
        gpsLng: Double? = nil
    ) {
        self.representationId = representationId
        self.cameraModel = cameraModel
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
        self.orientation = orientation
        self.gpsLat = gpsLat
        self.gpsLng = gpsLng
    }
}

extension ExifRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "exif"

    enum CodingKeys: String, CodingKey {
        case representationId = "representation_id"
        case cameraModel = "camera_model"
        case lens
        case iso
        case aperture
        case shutter
        case focalLength = "focal_length"
        case orientation
        case gpsLat = "gps_lat"
        case gpsLng = "gps_lng"
    }
}
