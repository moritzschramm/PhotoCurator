import Foundation

/// Picks the per-camera subdirectory a newly imported file lands in (spec §7.2).
/// There's no pre-existing convention to match against, so the app establishes its
/// own from the EXIF camera model; the import sheet lets the user override it per
/// batch before anything is copied.
public enum CameraSubdirectoryNaming {
    public static let fallback = "Unsorted"

    public static func suggestedSubdirectory(cameraModel: String?) -> String {
        guard let cameraModel, !cameraModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return sanitize(cameraModel)
    }

    public static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleanedScalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(cleanedScalars)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? fallback : cleaned
    }
}
