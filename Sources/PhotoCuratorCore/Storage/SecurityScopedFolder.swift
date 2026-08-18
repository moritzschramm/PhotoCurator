import Foundation

/// A folder URL resolved from a security-scoped bookmark. Access must be bracketed
/// with `start`/`stopAccessingSecurityScopedResource` (spec §9); `withAccess` does
/// that bracketing so callers can't forget to stop it.
public struct SecurityScopedFolder: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    @discardableResult
    public func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try await body(url)
    }
}

/// A resolved, registered photo-library directory (spec: multiple photo libraries) —
/// pairs a `PhotoLibrary` row's id/name with its resolved, security-scoped folder.
public struct PhotoLibraryFolder: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let name: String
    public let folder: SecurityScopedFolder

    public init(id: Int64, name: String, folder: SecurityScopedFolder) {
        self.id = id
        self.name = name
        self.folder = folder
    }

    public var url: URL { folder.url }

    public static func == (lhs: PhotoLibraryFolder, rhs: PhotoLibraryFolder) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.folder.url == rhs.folder.url
    }
}

/// Current grant state of every registered photo library plus the single export
/// target. The app hard-gates on `isFullyGranted` at launch (spec §9): at least one
/// photo library and the export target.
public struct FolderAccessStatus: Sendable {
    public var photoLibraries: [PhotoLibraryFolder]
    public var exportTarget: SecurityScopedFolder?

    public init(photoLibraries: [PhotoLibraryFolder], exportTarget: SecurityScopedFolder?) {
        self.photoLibraries = photoLibraries
        self.exportTarget = exportTarget
    }

    public var isFullyGranted: Bool {
        !photoLibraries.isEmpty && exportTarget != nil
    }
}
