import Foundation

extension URL {
    /// This URL's path relative to `root`, assuming it's contained within it. Falls
    /// back to just the last path component if it isn't.
    public func relativePath(from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return lastPathComponent }
        var relative = String(fullPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
