import AppKit

/// Shared decode cache for on-disk thumbnails, plus off-main-thread loading.
///
/// `NSImage(contentsOfFile:)` reads and decodes the file synchronously. Doing that
/// while configuring a grid cell (or inside a SwiftUI `body`) puts a file read on the
/// main thread for every tile that scrolls into view, which is exactly the stutter the
/// AppKit grid exists to avoid. Callers get a cached image immediately when there is
/// one, and hand off to `load` otherwise.
///
/// `NSCache` is thread-safe and evicts under memory pressure on its own; the count
/// limit just keeps a long scroll through a large library from parking thousands of
/// decoded bitmaps in memory before the system asks for any of it back.
enum ThumbnailImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    private static let queue = DispatchQueue(
        label: "com.photocurator.thumbnail-decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    /// Loads (or returns the cached) image, calling back on the main thread.
    static func load(_ path: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = cached(path) {
            completion(cached)
            return
        }
        queue.async {
            let image = decode(path)
            DispatchQueue.main.async { completion(image) }
        }
    }

    static func load(_ path: String) async -> NSImage? {
        if let cached = cached(path) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: decode(path)) }
        }
    }

    private static func decode(_ path: String) -> NSImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
