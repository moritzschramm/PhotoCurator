import AppKit
import PhotoCuratorCore

/// Intercepts Return/Space to "open" the current selection (matching Finder/Photos);
/// everything else — including arrow-key selection movement — falls through to
/// `NSCollectionView`'s own built-in keyboard handling.
final class ActivatablePhotoCollectionView: NSCollectionView {
    var onActivateSelection: (() -> Void)?
    /// Assigning `selectionIndexPaths` directly never calls the delegate's
    /// `didSelectItemsAt`/`didDeselectItemsAt` — which is exactly what lets
    /// `PhotoGridViewController.syncSelection` push SwiftUI's selection down without
    /// looping back up. Shift-click below assigns it too, so it has to report the
    /// change itself or the range would stay purely visual: the SwiftUI binding
    /// would keep the pre-shift-click value, the toolbar would act on the wrong
    /// photos, and the next re-render's `syncSelection` would silently revert the
    /// highlight.
    var onSelectionChangedProgrammatically: (() -> Void)?

    /// The item a plain or cmd-click last landed on, i.e. the fixed end of a
    /// shift-click range. NSCollectionView doesn't implement range selection
    /// itself (unlike NSTableView), so shift-click is handled explicitly below;
    /// cmd-click and plain click are left to `super` since those already work.
    private var rangeAnchorIndexPath: IndexPath?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return, Space
            onActivateSelection?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            rangeAnchorIndexPath = nil
            super.mouseDown(with: event)
            return
        }

        if event.modifierFlags.contains(.shift), let anchor = rangeAnchorIndexPath {
            let lo = min(anchor.item, indexPath.item)
            let hi = max(anchor.item, indexPath.item)
            selectionIndexPaths = Set((lo...hi).map { IndexPath(item: $0, section: anchor.section) })
            onSelectionChangedProgrammatically?()
            return
        }

        super.mouseDown(with: event)
        rangeAnchorIndexPath = indexPath
    }
}

/// Owns the virtualized `NSCollectionView` grid (spec §1: must be AppKit, not
/// SwiftUI `LazyVGrid`, for high-cell-count scrolling). Wrapped for SwiftUI by
/// `PhotoGridRepresentable`.
final class PhotoGridViewController: NSViewController {
    private static let photoDragType = NSPasteboard.PasteboardType("com.photocurator.photoId")

    private let scrollView = NSScrollView()
    private let collectionView = ActivatablePhotoCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, Int64>!
    private var entriesById: [Int64: PhotoGridEntry] = [:]
    private var orderedIds: [Int64] = []

    /// Only true for an album's browse grid (spec: drag-and-drop only makes
    /// sense against a persisted manual order, which the whole-library view
    /// doesn't have).
    var isReorderingEnabled = false
    var onSelectionChange: ((Set<Int64>) -> Void)?
    var onOpen: ((Int64) -> Void)?
    var onZoomDelta: ((CGFloat) -> Void)?
    /// Fired after a drag-and-drop reorder completes, with the complete new
    /// order — the caller is expected to persist it.
    var onReorder: (([Int64]) -> Void)?

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
        collectionView.onSelectionChangedProgrammatically = { [weak self] in
            self?.reportSelection()
        }
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.registerForDraggedTypes([Self.photoDragType])

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
        // Defaults to true, which holds back mouseDown/mouseUp from reaching
        // NSCollectionView's own click-to-select handling until this recognizer
        // can rule out a second click — i.e. selection waits out the system
        // double-click interval on every single click. Letting primary mouse
        // events through immediately fixes that without breaking double-click
        // detection, which still runs in parallel off the same events.
        doubleClick.delaysPrimaryMouseButtonEvents = false
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
        let previousOrderedIds = orderedIds
        entriesById = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        orderedIds = entries.map(\.id)

        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout,
           layout.itemSize.width != itemSize {
            layout.itemSize = NSSize(width: itemSize, height: itemSize)
            layout.invalidateLayout()
        }

        // A click's selection change round-trips back through SwiftUI (the
        // binding update triggers a re-render, which calls this method again)
        // even though `entries` itself didn't change. Re-applying an identical
        // snapshot still puts NSCollectionView through a batch-update/animation
        // cycle, which visibly delayed the selection highlight — so skip it
        // entirely when the photo list itself is unchanged, and only sync
        // selection, which is instant.
        guard orderedIds != previousOrderedIds || entriesById != previousEntriesById else {
            syncSelection(selection)
            return
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

    /// Rebuilds and applies a snapshot purely from the current `orderedIds` —
    /// used after a local drag-and-drop reorder, where `entriesById` hasn't
    /// changed (same photos, same content) but their order has.
    private func applyReorderedSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
        snapshot.appendSections([0])
        snapshot.appendItems(orderedIds, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
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

    fileprivate func reportSelection() {
        let ids = collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
        onSelectionChange?(Set(ids))
    }

    // MARK: Drag-and-drop reordering (album scope only)

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        isReorderingEnabled
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard isReorderingEnabled, let photoId = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(photoId), forType: Self.photoDragType)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard isReorderingEnabled else { return [] }
        // Always insert *between* items, never "onto" one — this is a reorder,
        // not a drop-into-item action.
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard isReorderingEnabled,
              let pasteboardItems = draggingInfo.draggingPasteboard.pasteboardItems else { return false }
        let draggedIds = pasteboardItems.compactMap { $0.string(forType: Self.photoDragType) }.compactMap(Int64.init)
        guard !draggedIds.isEmpty else { return false }
        let draggedSet = Set(draggedIds)

        // Preserve the dragged items' own relative order (matters for a
        // multi-selection drag) rather than the pasteboard's enumeration order.
        let draggedInCurrentOrder = orderedIds.filter { draggedSet.contains($0) }

        let targetIndex = indexPath.item
        // How many dragged items sat before the drop point — removing them
        // shifts everything after them left by that amount, so the target
        // index has to shift left too to land in the same visual gap.
        let removedBeforeTarget = orderedIds.prefix(targetIndex).filter { draggedSet.contains($0) }.count

        var newOrder = orderedIds
        newOrder.removeAll { draggedSet.contains($0) }
        let insertionIndex = (targetIndex - removedBeforeTarget).clamped(to: 0...newOrder.count)
        newOrder.insert(contentsOf: draggedInCurrentOrder, at: insertionIndex)

        guard newOrder != orderedIds else { return false }
        orderedIds = newOrder
        applyReorderedSnapshot()
        onReorder?(newOrder)
        return true
    }
}
