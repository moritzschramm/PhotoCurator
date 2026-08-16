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

/// Which of the two first-run folder grants a bookmark belongs to (spec §9).
public enum FolderRole: String, Sendable, CaseIterable {
    case photoLibrary
    case exportTarget

    var appStateKey: String {
        switch self {
        case .photoLibrary: return AppStateKey.photoFolderBookmark
        case .exportTarget: return AppStateKey.exportFolderBookmark
        }
    }
}

/// Current grant state of both persisted folders. The app hard-gates on
/// `isFullyGranted` at launch (spec §9).
public struct FolderAccessStatus: Sendable {
    public var photoLibrary: SecurityScopedFolder?
    public var exportTarget: SecurityScopedFolder?

    public init(photoLibrary: SecurityScopedFolder?, exportTarget: SecurityScopedFolder?) {
        self.photoLibrary = photoLibrary
        self.exportTarget = exportTarget
    }

    public var isFullyGranted: Bool {
        photoLibrary != nil && exportTarget != nil
    }
}
