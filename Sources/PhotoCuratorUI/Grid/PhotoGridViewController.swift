import AppKit
import PhotoCuratorCore

/// Intercepts Return/Space to "open" the current selection (matching Finder/Photos);
/// everything else — including arrow-key selection movement — falls through to
/// `NSCollectionView`'s own built-in keyboard handling.
final class ActivatablePhotoCollectionView: NSCollectionView {
    var onActivateSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return, Space
            onActivateSelection?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the virtualized `NSCollectionView` grid (spec §1: must be AppKit, not
/// SwiftUI `LazyVGrid`, for high-cell-count scrolling). Wrapped for SwiftUI by
/// `PhotoGridRepresentable`.
final class PhotoGridViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let collectionView = ActivatablePhotoCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, Int64>!
    private var entriesById: [Int64: PhotoGridEntry] = [:]
    private var orderedIds: [Int64] = []

    var onSelectionChange: ((Set<Int64>) -> Void)?
    var onOpen: ((Int64) -> Void)?
    var onZoomDelta: ((CGFloat) -> Void)?

    override func loadView() {
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        layout.itemSize = NSSize(width: 160, height: 160)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        collectionView.delegate = self
        collectionView.onActivateSelection = { [weak self] in
            self?.activateFirstSelection()
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        dataSource = NSCollectionViewDiffableDataSource<Int, Int64>(collectionView: collectionView) { [weak self] collectionView, indexPath, photoId in
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
            guard let photoItem = item as? PhotoGridItem else { return item }
            if let entry = self?.entriesById[photoId] {
                photoItem.configure(with: entry)
            }
            return photoItem
        }

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        scrollView.addGestureRecognizer(magnify)
    }

    func update(entries: [PhotoGridEntry], itemSize: CGFloat, selection: Set<Int64>) {
        // Defensive: NSViewController loads its view (and runs viewDidLoad, which
        // sets up `dataSource`) lazily. Callers are expected to force that via
        // `loadViewIfNeeded()` first, but this guards against a crash if one doesn't.
        loadViewIfNeeded()

        let previousEntriesById = entriesById
        entriesById = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        orderedIds = entries.map(\.id)

        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout,
           layout.itemSize.width != itemSize {
            layout.itemSize = NSSize(width: itemSize, height: itemSize)
            layout.invalidateLayout()
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
        snapshot.appendSections([0])
        snapshot.appendItems(orderedIds, toSection: 0)

        // `reloadItems` (not `reconfigureItems`, unavailable on this snapshot type)
        // forces already-present cells to redraw when their content changed
        // (derivation/lifecycle state, a new thumbnail) without recreating cells
        // whose identity AND content are both unchanged — matters for scroll
        // performance on a large library (spec §1: "high-cell-count scrolling").
        // Brand-new ids don't need this: `appendItems` already configures them.
        let changedIds = orderedIds.filter { id in
            guard let previous = previousEntriesById[id] else { return false }
            return previous != entriesById[id]
        }
        if !changedIds.isEmpty {
            snapshot.reloadItems(changedIds)
        }

        dataSource.apply(snapshot, animatingDifferences: true)
        syncSelection(selection)
    }

    private func syncSelection(_ selection: Set<Int64>) {
        let currentIds = Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        guard currentIds != selection else { return }
        let indexPaths = Set(selection.compactMap { id -> IndexPath? in
            guard let index = orderedIds.firstIndex(of: id) else { return nil }
            return IndexPath(item: index, section: 0)
        })
        collectionView.selectionIndexPaths = indexPaths
    }

    private func activateFirstSelection() {
        guard let firstIndexPath = collectionView.selectionIndexPaths.sorted().first,
              let photoId = dataSource.itemIdentifier(for: firstIndexPath) else { return }
        onOpen?(photoId)
    }

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let photoId = dataSource.itemIdentifier(for: indexPath) else { return }
        onOpen?(photoId)
    }

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        onZoomDelta?(recognizer.magnification)
        recognizer.magnification = 0
    }
}

extension PhotoGridViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        reportSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        reportSelection()
    }

    private func reportSelection() {
        let ids = collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
        onSelectionChange?(Set(ids))
    }
}
