import SwiftUI
import PhotoCuratorCore

/// One of the app's three primary surfaces (spec §8): a large, zoomable, virtualized
/// grid — either the whole library or one album.
struct PhotoGridScreen: View {
    let scope: GridScope

    @Environment(AppEnvironment.self) private var environment
    @Environment(GridNavigator.self) private var navigator
    @State private var albumStore = AlbumScopeStore()
    @State private var thumbnailSize: CGFloat = 160
    @State private var selection: Set<Int64> = []
    @State private var showingExportSheet = false

    private var entries: [PhotoGridEntry] {
        switch scope {
        case .library: return environment.gridEntries
        case .album: return albumStore.entries
        }
    }

    var body: some View {
        PhotoGridRepresentable(
            entries: entries,
            itemSize: thumbnailSize,
            selection: $selection,
            onOpen: { id in navigator.openPhoto(id, scope: scope) },
            onZoomDelta: { delta in
                thumbnailSize = (thumbnailSize * (1 + delta)).clamped(to: 80...360)
            }
        )
        .navigationTitle(title)
        .task(id: scope) {
            if case .album(let albumId) = scope {
                albumStore.start(albumId: albumId, database: environment.database)
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheetView(photoIds: Array(selection), defaultCategory: defaultCategory)
        }
    }

    private var title: String {
        switch scope {
        case .library: return "Library"
        case .album(let id): return environment.albums.first { $0.id == id }?.name ?? "Album"
        }
    }

    private var defaultCategory: String {
        if case .album(let id) = scope {
            return environment.albums.first { $0.id == id }?.name ?? ""
        }
        return ""
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await environment.setLifecycle(photoIds: Array(selection), state: .candidate) }
            } label: {
                Label("Candidate", systemImage: "star")
            }
            .keyboardShortcut("c", modifiers: [])
            .disabled(selection.isEmpty)
            .help("Mark as candidate (C)")

            Button {
                Task { await environment.setLifecycle(photoIds: Array(selection), state: .rejected) }
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
            .keyboardShortcut("x", modifiers: [])
            .disabled(selection.isEmpty)
            .help("Reject (X)")

            Button {
                Task { await environment.setLifecycle(photoIds: Array(selection), state: .reviewed) }
            } label: {
                Label("Reviewed", systemImage: "checkmark")
            }
            .keyboardShortcut("u", modifiers: [])
            .disabled(selection.isEmpty)
            .help("Mark as reviewed (U)")

            Menu {
                ForEach(environment.albums) { album in
                    Button(album.name) {
                        Task {
                            for id in selection {
                                await environment.toggleAlbumMembership(photoId: id, albumId: album.id ?? -1)
                            }
                        }
                    }
                }
            } label: {
                Label("Add to Album", systemImage: "square.stack.3d.up")
            }
            .disabled(selection.isEmpty || environment.albums.isEmpty)

            Button {
                showingExportSheet = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)
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
            .help("Thumbnail size — pinch on the grid also zooms")
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
