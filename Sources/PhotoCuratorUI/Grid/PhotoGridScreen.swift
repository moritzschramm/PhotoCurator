import SwiftUI
import PhotoCuratorCore

/// One of the app's three primary surfaces (spec §8): a large, zoomable, virtualized
/// grid — the whole library, one specific library, reviewed-but-uncategorized
/// photos, or one album.
struct PhotoGridScreen: View {
    let scope: GridScope

    @Environment(AppEnvironment.self) private var environment
    @Environment(GridNavigator.self) private var navigator
    @State private var albumStore = AlbumScopeStore()
    @State private var thumbnailSize: CGFloat = 160
    @State private var selection: Set<Int64> = []
    @State private var showingExportSheet = false
    /// Which albums each currently-selected photo already belongs to — refreshed
    /// whenever the selection changes, so the "Add to Album" menu can show a
    /// checkmark without a database round-trip on every menu open.
    @State private var selectionAlbumIds: [Int64: Set<Int64>] = [:]

    private var entries: [PhotoGridEntry] {
        switch scope {
        case .library(let id): return environment.gridEntries(libraryId: id)
        case .unassigned: return environment.unassignedGridEntries
        case .album: return albumStore.entries
        }
    }

    private var isAlbumScope: Bool {
        if case .album = scope { return true }
        return false
    }

    var body: some View {
        PhotoGridRepresentable(
            entries: entries,
            itemSize: thumbnailSize,
            selection: $selection,
            isReorderingEnabled: isAlbumScope,
            onOpen: { id in navigator.openPhoto(id, scope: scope) },
            onZoomDelta: { delta in
                thumbnailSize = (thumbnailSize * (1 + delta)).clamped(to: 80...360)
            },
            onReorder: { newOrder in
                guard case .album(let albumId) = scope else { return }
                Task { await environment.reorderAlbumPhotos(albumId: albumId, orderedPhotoIds: newOrder) }
            }
        )
        .navigationTitle(title)
        .task(id: scope) {
            if case .album(let albumId) = scope {
                albumStore.start(albumId: albumId, database: environment.database)
            }
        }
        .task(id: selection) {
            selectionAlbumIds = selection.isEmpty ? [:] : await environment.albumIds(forPhotoIds: Array(selection))
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingExportSheet) {
            if case .album(let albumId) = scope {
                AlbumExportSheetView(albumId: albumId, category: defaultCategory)
            }
        }
    }

    private var title: String {
        switch scope {
        case .library(let id):
            guard let id else { return "All Photos" }
            return environment.folderAccess.photoLibraries.first { $0.id == id }?.name ?? "Library"
        case .unassigned: return "Unassigned Photos"
        case .album(let id): return environment.albums.first { $0.id == id }?.name ?? "Album"
        }
    }

    private var defaultCategory: String {
        if case .album(let id) = scope {
            return environment.albums.first { $0.id == id }?.name ?? ""
        }
        return ""
    }

    /// Whether every currently-selected photo already belongs to `albumId` — used
    /// both to render the "Add to Album" menu's checkmark and to decide whether
    /// choosing it should add or remove the whole selection.
    private func isSelectionFullyInAlbum(_ albumId: Int64) -> Bool {
        !selection.isEmpty && selection.allSatisfy { selectionAlbumIds[$0]?.contains(albumId) ?? false }
    }

    /// Whether every currently-selected photo is already in `state` — used to decide
    /// whether clicking that state's toolbar button should apply it, or (clicking an
    /// already-fully-applied state again) toggle the selection back to unreviewed.
    private func isSelectionFullyInState(_ state: LifecycleState) -> Bool {
        !selection.isEmpty && selection.allSatisfy { id in
            entries.first { $0.id == id }?.photo.photo.lifecycleState == state
        }
    }

    private func toggleLifecycle(_ state: LifecycleState) {
        let targetState: LifecycleState = isSelectionFullyInState(state) ? .new : state
        Task { await environment.setLifecycle(photoIds: Array(selection), state: targetState) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                toggleLifecycle(.candidate)
            } label: {
                Label("Candidate", systemImage: "star")
            }
            .keyboardShortcut("c", modifiers: [])
            .disabled(selection.isEmpty)
            .help("Mark as candidate — click again to mark unreviewed (C)")

            Button {
                toggleLifecycle(.rejected)
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
            .keyboardShortcut("x", modifiers: [])
            .disabled(selection.isEmpty)
            .help("Reject — click again to mark unreviewed (X)")

            Button {
                toggleLifecycle(.accepted)
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .keyboardShortcut("u", modifiers: [])
            .disabled(selection.isEmpty)
            .help("Mark as accepted — click again to mark unreviewed (U)")

            Menu {
                ForEach(environment.albums) { album in
                    let albumId = album.id ?? -1
                    let allMembers = isSelectionFullyInAlbum(albumId)
                    Toggle(isOn: Binding(
                        get: { allMembers },
                        set: { _ in
                            Task {
                                await environment.toggleAlbumMembershipForSelection(
                                    photoIds: Array(selection), albumId: albumId, allAreMembers: allMembers
                                )
                                // The menu can be reopened without the selection ever
                                // changing (the usual `.task(id: selection)` refresh
                                // trigger), so the checkmark needs an explicit refresh
                                // here too, not just on selection change.
                                selectionAlbumIds = await environment.albumIds(forPhotoIds: Array(selection))
                            }
                        }
                    )) {
                        Text(album.name)
                    }
                }
            } label: {
                Label("Add to Album", systemImage: "square.stack.3d.up")
            }
            .disabled(selection.isEmpty || environment.albums.isEmpty)
        }

        if case .album = scope {
            ToolbarItem {
                Button("Export") {
                    showingExportSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .help("Review and export this album's accepted photos")
            }
        }

        ToolbarItem {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.caption)
                Slider(value: $thumbnailSize, in: 80...360)
                    .frame(width: 120)
                Image(systemName: "photo.fill")
                    .font(.body)
            }
            .padding(.horizontal, 8)
            .help("Thumbnail size — pinch on the grid also zooms")
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
