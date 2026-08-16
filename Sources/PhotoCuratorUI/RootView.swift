import SwiftUI
import PhotoCuratorCore

enum SidebarSelection: Hashable {
    case library
    case albumsOverview
    case album(Int64)
}

enum PhotoNavigationTarget: Hashable {
    case photo(id: Int64, scope: GridScope)
}

/// Which set of photos a grid screen shows — the whole library, or one album.
public enum GridScope: Hashable, Sendable {
    case library
    case album(Int64)
}

/// Lets deeply-nested AppKit callbacks (an `NSCollectionView` double-click) push onto
/// the SwiftUI `NavigationStack` without threading a binding through every view.
@MainActor
@Observable
final class GridNavigator {
    var path = NavigationPath()

    func openPhoto(_ id: Int64, scope: GridScope) {
        path.append(PhotoNavigationTarget.photo(id: id, scope: scope))
    }
}

public struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var navigator = GridNavigator()
    @State private var sidebarSelection: SidebarSelection? = .library
    @State private var manualImportSourceURL: URL?
    @State private var isPickingImportSource = false
    @State private var isCreatingAlbum = false
    @State private var newAlbumName = ""

    public init() {}

    public var body: some View {
        Group {
            switch environment.launchPhase {
            case .notStarted, .awaitingFolderAccess:
                PermissionGateView()
            case .reconciling(let progress):
                ReconcilingView(progress: progress)
            case .failed(let message):
                FailureView(message: message)
            case .ready:
                mainContent
            }
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $navigator.path) {
                detailContent
                    .navigationDestination(for: PhotoNavigationTarget.self) { target in
                        switch target {
                        case .photo(let id, let scope):
                            CloseUpView(photoId: id, scope: scope)
                        }
                    }
            }
        }
        .environment(navigator)
        .fileImporter(isPresented: $isPickingImportSource, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                manualImportSourceURL = url
            }
        }
        .sheet(isPresented: importSheetBinding) {
            if let source = activeImportSource {
                ImportSheetView(sourceFolderURL: source.url, displayName: source.displayName)
            }
        }
        .alert("New Album", isPresented: $isCreatingAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Cancel", role: .cancel) { newAlbumName = "" }
            Button("Create") {
                let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                newAlbumName = ""
                guard !name.isEmpty else { return }
                Task {
                    if let album = await environment.createAlbum(name: name) {
                        sidebarSelection = .album(album.id ?? -1)
                    }
                }
            }
        }
    }

    private var activeImportSource: (url: URL, displayName: String)? {
        if let manual = manualImportSourceURL {
            return (manual, manual.lastPathComponent)
        }
        if let volume = environment.mountedVolumePendingImport {
            return (volume.url, volume.volumeName)
        }
        return nil
    }

    private var importSheetBinding: Binding<Bool> {
        Binding(
            get: { activeImportSource != nil },
            set: { isPresented in
                if !isPresented {
                    manualImportSourceURL = nil
                    environment.mountedVolumePendingImport = nil
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Label("Library", systemImage: "photo.on.rectangle")
                .tag(SidebarSelection.library)

            Label("All Albums", systemImage: "square.grid.2x2")
                .tag(SidebarSelection.albumsOverview)

            Section {
                ForEach(environment.albums) { album in
                    Label(album.name, systemImage: "square.stack")
                        .tag(SidebarSelection.album(album.id ?? -1))
                        .contextMenu {
                            Button("Delete Album", role: .destructive) {
                                Task { await environment.deleteAlbum(id: album.id ?? -1) }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Albums")
                    Spacer()
                    Button {
                        isCreatingAlbum = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("New Album")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
            ToolbarItem {
                Button {
                    isPickingImportSource = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .help("Import photos from a folder or SD card")
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch sidebarSelection {
        case .none, .library:
            PhotoGridScreen(scope: .library)
        case .albumsOverview:
            AlbumsOverviewView { albumId in
                sidebarSelection = .album(albumId)
            }
        case .album(let albumId):
            PhotoGridScreen(scope: .album(albumId))
        }
    }
}

private struct ReconcilingView: View {
    let progress: ReconciliationService.Progress

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progressFraction)
                .frame(maxWidth: 320)
            Text(phaseLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var progressFraction: Double? {
        guard progress.total > 0 else { return nil }
        return Double(progress.processed) / Double(progress.total)
    }

    private var phaseLabel: String {
        switch progress.phase {
        case .enumeratingPhotoLibrary: return "Scanning photo library…"
        case .reconcilingPhotoLibrary: return "Indexing photo library (\(progress.processed)/\(progress.total))…"
        case .enumeratingExportTarget: return "Scanning export target…"
        case .reconcilingExportTarget: return "Indexing export target…"
        case .establishingBaseline: return "Finishing first-run setup…"
        case .done: return "Ready"
        }
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 420)
    }
}
