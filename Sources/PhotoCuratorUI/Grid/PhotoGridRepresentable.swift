import SwiftUI
import PhotoCuratorCore

/// SwiftUI-facing wrapper around `PhotoGridViewController`'s `NSCollectionView`
/// (spec §1). Data flows down (`entries`, `itemSize`, `selection`); user gestures
/// flow up via callbacks — standard one-way `NSViewRepresentable` shape.
struct PhotoGridRepresentable: NSViewControllerRepresentable {
    let entries: [PhotoGridEntry]
    let itemSize: CGFloat
    @Binding var selection: Set<Int64>
    var onOpen: (Int64) -> Void
    var onZoomDelta: (CGFloat) -> Void

    func makeNSViewController(context: Context) -> PhotoGridViewController {
        let controller = PhotoGridViewController()
        // NSViewController loads its view lazily; without forcing it here,
        // viewDidLoad() (which sets up the collection view and data source)
        // hasn't run yet when `update` below tries to use them.
        controller.loadViewIfNeeded()
        controller.onSelectionChange = { newSelection in
            if selection != newSelection {
                selection = newSelection
            }
        }
        controller.onOpen = onOpen
        controller.onZoomDelta = onZoomDelta
        controller.update(entries: entries, itemSize: itemSize, selection: selection)
        return controller
    }

    func updateNSViewController(_ controller: PhotoGridViewController, context: Context) {
        controller.onOpen = onOpen
        controller.onZoomDelta = onZoomDelta
        controller.onSelectionChange = { newSelection in
            if selection != newSelection {
                selection = newSelection
            }
        }
        controller.update(entries: entries, itemSize: itemSize, selection: selection)
    }
}
