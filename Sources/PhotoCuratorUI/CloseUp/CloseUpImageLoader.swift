import AppKit
import Observation
import PhotoCuratorCore

/// Drives the JPG→RAW swap for one photo (spec §7.4): shows the fastest available
/// image immediately, then — if a RAW exists — renders it via `CIRAWFilter` in the
/// background and swaps to it after a short minimum delay ("developing"). Online-only
/// representations are materialized on demand here, since being viewed in close-up is
/// exactly the "user explicitly acts on it" trigger spec §7.3 describes.
@MainActor
@Observable
final class CloseUpImageLoader {
    private(set) var displayImage: NSImage?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private(set) var canToggleRaw = false
    private(set) var isShowingRaw = false
    private(set) var isRenderingRaw = false
    private(set) var rawRenderFailed = false

    /// Long edge, in pixels, a full RAW render is capped at.
    ///
    /// `CIRAWFilter` at native resolution decodes ~60 MP on a modern body — seconds of
    /// CPU and hundreds of megabytes for an image that is then drawn into a window a
    /// fraction of that size. This is comfortably above any current display's pixel
    /// width, so "fit to window" is pixel-exact and the 8× zoom degrades gracefully
    /// rather than costing that on every photo browsed past.
    ///
    /// `nonisolated` because the render itself deliberately runs off the main actor
    /// and needs to read this; it's an immutable `Sendable` constant, so there's no
    /// actor state to protect.
    private nonisolated static let maxRawRenderPixelSize: CGFloat = 4096

    private var loadTask: Task<Void, Never>?
    /// The in-flight (or most recent) RAW render. Held separately from `loadTask`
    /// because the render runs detached — cancelling the parent doesn't reach it —
    /// and because each new render chains onto this one, so that arrowing through a
    /// library queues renders one behind another instead of running a decode per
    /// keypress in parallel.
    private var rawRenderTask: Task<CGImage?, Never>?
    private var fastImage: NSImage?
    private var upgradedImage: NSImage?
    private var userToggled = false

    func load(pwr: PhotoWithRepresentations, photoRoot: URL, database: AppDatabase, derivationQueue: DerivationQueue) {
        loadTask?.cancel()
        rawRenderTask?.cancel()
        displayImage = nil
        fastImage = nil
        upgradedImage = nil
        isLoading = true
        loadFailed = false
        userToggled = false
        isShowingRaw = false
        isRenderingRaw = false
        rawRenderFailed = false
        canToggleRaw = pwr.raw != nil

        loadTask = Task {
            await self.run(pwr: pwr, photoRoot: photoRoot, database: database, derivationQueue: derivationQueue)
        }
    }

    func toggleRawJpg() {
        guard canToggleRaw else { return }
        userToggled = true
        isShowingRaw.toggle()
        displayImage = (isShowingRaw ? upgradedImage : fastImage) ?? displayImage
    }

    private func run(
        pwr: PhotoWithRepresentations,
        photoRoot: URL,
        database: AppDatabase,
        derivationQueue: DerivationQueue
    ) async {
        guard let fastRep = pwr.jpg ?? pwr.raw else {
            isLoading = false
            loadFailed = true
            return
        }

        guard let fastPath = await Self.ensureDerivedThumbnailPath(
            representation: fastRep, photoRoot: photoRoot, database: database, derivationQueue: derivationQueue
        ) else {
            isLoading = false
            loadFailed = true
            return
        }
        guard !Task.isCancelled else { return }

        let image = NSImage(contentsOfFile: fastPath)
        fastImage = image
        displayImage = image
        isLoading = false

        if let raw = pwr.raw {
            await renderRawUpgrade(raw: raw, photoRoot: photoRoot, database: database, derivationQueue: derivationQueue)
        } else if let jpg = pwr.jpg {
            await loadFullResolutionUpgrade(representation: jpg, photoRoot: photoRoot)
        }
    }

    private func renderRawUpgrade(
        raw: Representation,
        photoRoot: URL,
        database: AppDatabase,
        derivationQueue: DerivationQueue
    ) async {
        let start = Date()
        isRenderingRaw = true

        if !raw.isLocal {
            _ = try? await derivationQueue.deriveOnDemand(representation: raw, photoRoot: photoRoot)
        }
        guard !Task.isCancelled else { return }

        // `supportedCameraModels` is deliberately *not* used as a hard gate here:
        // its strings don't reliably match what a file's own EXIF camera-model tag
        // reports (formatting differs by camera/firmware), so treating a
        // non-match as "unsupported" risks silently blocking a render that would
        // have actually worked — which looks like the toggle "does nothing" from
        // the outside. Per spec §7.4, the render attempt itself is the real
        // arbiter: fall back to the embedded preview only if it actually fails.
        let fileURL = raw.fileURL(photoRoot: photoRoot)
        let previousRender = rawRenderTask
        let renderTask = Task.detached(priority: .userInitiated) { () -> CGImage? in
            // Serialized behind whatever was already rendering, and re-checked for
            // cancellation once it's this one's turn: browsing quickly past a photo
            // supersedes its render before it ever starts work, rather than piling
            // full-resolution decodes on top of each other.
            _ = await previousRender?.value
            guard !Task.isCancelled else { return nil }
            return try? RawImageRenderer.render(fileURL: fileURL, maxPixelSize: Self.maxRawRenderPixelSize)
        }
        rawRenderTask = renderTask
        let rendered = await renderTask.value
        guard !Task.isCancelled else { return }

        let elapsed = Date().timeIntervalSince(start)
        let minimumDelay = 2.5
        if elapsed < minimumDelay {
            try? await Task.sleep(for: .seconds(minimumDelay - elapsed))
        }
        guard !Task.isCancelled else { return }

        isRenderingRaw = false
        guard let rendered else {
            rawRenderFailed = true
            return
        }

        let nsImage = NSImage(cgImage: rendered, size: .zero)
        upgradedImage = nsImage
        if !userToggled {
            isShowingRaw = true
            displayImage = nsImage
        } else if isShowingRaw {
            displayImage = nsImage
        }
    }

    private func loadFullResolutionUpgrade(representation: Representation, photoRoot: URL) async {
        let fileURL = representation.fileURL(photoRoot: photoRoot)
        let image = await Task.detached(priority: .utility) {
            NSImage(contentsOf: fileURL)
        }.value
        guard !Task.isCancelled, let image else { return }
        upgradedImage = image
        if !userToggled {
            displayImage = image
        }
    }

    private static func ensureDerivedThumbnailPath(
        representation: Representation,
        photoRoot: URL,
        database: AppDatabase,
        derivationQueue: DerivationQueue
    ) async -> String? {
        guard let representationId = representation.id else { return nil }

        if let path = await fetchPreviewThumbnailPath(representationId: representationId, database: database) {
            return path
        }

        // One retry lives inside `deriveOnDemand`; if it still fails, the caller
        // shows a placeholder rather than leaving anything half-materialized (§7.7).
        guard (try? await derivationQueue.deriveOnDemand(representation: representation, photoRoot: photoRoot)) != nil else {
            return nil
        }
        return await fetchPreviewThumbnailPath(representationId: representationId, database: database)
    }

    private static func fetchPreviewThumbnailPath(representationId: Int64, database: AppDatabase) async -> String? {
        guard let record = try? await database.read({ db in
            try PhotoRepository.fetchThumbnail(representationId: representationId, sizeClass: .preview, in: db)
        }) else { return nil }
        return record.cachePath
    }
}
