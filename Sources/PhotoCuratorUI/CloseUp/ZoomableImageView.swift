import AppKit
import SwiftUI

/// `NSScrollView` handles "zoom centered on a point" natively — trackpad pinch
/// (`allowsMagnification`) already anchors on the gesture location, and
/// `setMagnification(_:centeredAtPoint:)` gives the same anchoring for a manual trigger.
/// This subclass adds scroll-wheel-drives-zoom on top for a *plain wheel mouse*
/// (anchored at the pointer, same as pinch) since it has no pinch gesture available,
/// plus click-drag panning so zooming in past "fit" is actually usable.
private final class ZoomableScrollView: NSScrollView {
    private var lastDragLocation: NSPoint?

    override func scrollWheel(with event: NSEvent) {
        // Trackpad/Magic Mouse two-finger scroll reports precise deltas and should
        // pan like any ordinary scrollable content — pinch is the natural zoom
        // gesture there, and fighting it with scroll-driven zoom is what caused
        // panning to glitch. A plain wheel mouse reports imprecise deltas and has
        // no pinch equivalent, so its wheel drives zoom instead.
        guard !event.hasPreciseScrollingDeltas, event.deltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        // `setMagnification(_:centeredAt:)` wants its point in *content view*
        // space (the NSClipView's coordinate system, which reflects the current
        // scroll/pan offset) — not the scroll view's own fixed viewport bounds,
        // which is what `self.convert` gives you. Using the wrong space here
        // means the anchor point is only correct while unscrolled; the moment
        // you've panned (e.g. by zooming in and moving the pointer), zooming
        // out anchors on the wrong spot in the image and visibly jumps.
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        let clampedDelta = event.deltaY.clamped(to: -10...10)
        let zoomFactor = 1 + (clampedDelta * 0.03)
        let newMagnification = (magnification * zoomFactor).clamped(to: minMagnification...maxMagnification)
        setMagnification(newMagnification, centeredAt: pointInContent)
    }

    override func mouseDown(with event: NSEvent) {
        guard magnification > minMagnification else {
            super.mouseDown(with: event)
            return
        }
        lastDragLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragLocation, magnification > minMagnification else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: current.x - last.x, y: current.y - last.y)
        lastDragLocation = current

        // contentView (NSClipView) is Y-flipped relative to the scroll view's own
        // coordinate space that `delta` is measured in, so only Y needs negating
        // here to get "grab and drag" semantics on both axes.
        var origin = contentView.bounds.origin
        origin.x -= delta.x
        origin.y += delta.y
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        super.mouseUp(with: event)
    }
}

final class ZoomableImageViewController: NSViewController {
    private let scrollView = ZoomableScrollView()
    private let imageView = NSImageView()

    override func loadView() {
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 8.0
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        // Aspect-fit within whatever frame we give it, centered — .scaleAxesIndependently
        // would stretch/distort to fill the frame regardless of aspect ratio.
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the image fit to the window on resize, but only while not actively
        // zoomed in — don't fight a zoom level the user chose.
        if scrollView.magnification <= scrollView.minMagnification {
            fitImageToContainer()
        }
    }

    func setImage(_ image: NSImage?, resetZoom: Bool) {
        imageView.image = image

        if resetZoom || scrollView.magnification <= scrollView.minMagnification {
            // Either a genuinely new photo, or not currently zoomed in (in which
            // case there's no zoom/pan to preserve anyway) — (re-)fit normally.
            fitImageToContainer()
        }
        // Otherwise: a quality upgrade (JPG → RAW) for the same photo while
        // already zoomed in. Deliberately touch nothing else here — imageView's
        // frame, the scroll view's magnification, and its scroll position (which
        // part of the image is currently visible) all stay exactly as they were;
        // only the pixel content changes. An earlier version tried to explicitly
        // "preserve" magnification by resetting the frame and restoring the
        // magnification value, but that still lost the scroll position (which
        // part of the image was panned into view), so the zoom level carried over
        // but the visible region jumped. Not touching anything is both simpler
        // and strictly more correct.
    }

    /// The frame is always exactly the container size — `imageScaling` +
    /// `imageAlignment` above do the aspect-fit-and-center work internally, rather
    /// than this computing a separate, image-aspect-sized rect positioned at the
    /// origin (which fit correctly but left the image pinned to a corner instead
    /// of centered).
    private func fitImageToContainer() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let containerSize = scrollView.contentView.bounds.size
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        imageView.frame = NSRect(origin: .zero, size: containerSize)
        scrollView.magnification = 1.0
    }
}

/// SwiftUI-facing wrapper. `resetKey` should identify the *photo*, not the image
/// bytes — changing it resets zoom/pan; the same key across a JPG→RAW quality swap
/// for the same photo preserves whatever zoom the user set.
struct ZoomableImageView: NSViewControllerRepresentable {
    let image: NSImage?
    let resetKey: AnyHashable

    func makeNSViewController(context: Context) -> ZoomableImageViewController {
        let controller = ZoomableImageViewController()
        controller.loadViewIfNeeded()
        controller.setImage(image, resetZoom: true)
        context.coordinator.lastResetKey = resetKey
        return controller
    }

    func updateNSViewController(_ controller: ZoomableImageViewController, context: Context) {
        let shouldReset = context.coordinator.lastResetKey != resetKey
        controller.setImage(image, resetZoom: shouldReset)
        context.coordinator.lastResetKey = resetKey
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastResetKey: AnyHashable?
    }
}
