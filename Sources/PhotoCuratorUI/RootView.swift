import SwiftUI
import AppKit
import PhotoCuratorCore

enum SidebarSelection: Hashable {
    /// `id == nil` is "All Photos".
    case library(id: Int64?)
    case unassigned
    case albumsOverview
    case album(Int64)
}

enum PhotoNavigationTarget: Hashable {
    case photo(id: Int64, scope: GridScope)
}

/// Which set of photos a grid screen shows — every registered photo library, one
/// specific library (`id` non-nil), reviewed-but-uncategorized photos, or one album.
public enum GridScope: Hashable, Sendable {
    case library(id: Int64?)
    case unassigned
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
    @State private var sidebarSelection: SidebarSelection? = .library(id: nil)
    @State private var manualImportSourceURL: URL?
    @State private var lastImportDirectoryHint: URL?
    @State private var isCreatingAlbum = false
    @State private var newAlbumName = ""
    @State private var renamingAlbum: Album?
    @State private var renameAlbumName = ""
    @State private var renamingLibrary: PhotoLibraryFolder?
    @State private var renameLibraryName = ""
    @State private var removingLibrary: PhotoLibraryFolder?
    @State private var addLibraryError: String?
    @State private var exportDirectoryError: String?

    public init() {}

    public var body: some View {
        Group {
            switch environment.launchPhase {
            case .notStarted, .resolvingFolderAccess:
                LaunchSplashView()
            case .awaitingFolderAccess:
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
        .task {
            lastImportDirectoryHint = await BookmarkStore.resolveLastImportSource(database: environment.database)
        }
        .sheet(isPresented: importSheetBinding) {
            if let url = manualImportSourceURL {
                ImportSheetView(sourceFolderURL: url, displayName: url.lastPathComponent, defaultLibraryId: defaultImportLibraryId)
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
        .alert(
            "Rename Album",
            isPresented: Binding(
                get: { renamingAlbum != nil },
                set: { isPresented in if !isPresented { renamingAlbum = nil } }
            )
        ) {
            TextField("Album name", text: $renameAlbumName)
            Button("Cancel", role: .cancel) { renamingAlbum = nil }
            Button("Rename") {
                guard let id = renamingAlbum?.id else { return }
                let name = renameAlbumName
                renamingAlbum = nil
                Task { await environment.renameAlbum(id: id, name: name) }
            }
        }
        .alert(
            "Rename Library",
            isPresented: Binding(
                get: { renamingLibrary != nil },
                set: { isPresented in if !isPresented { renamingLibrary = nil } }
            )
        ) {
            TextField("Library name", text: $renameLibraryName)
            Button("Cancel", role: .cancel) { renamingLibrary = nil }
            Button("Rename") {
                guard let id = renamingLibrary?.id else { return }
                let name = renameLibraryName
                renamingLibrary = nil
                Task { await environment.renamePhotoLibrary(id: id, name: name) }
            }
        }
        .alert(
            "Remove Library",
            isPresented: Binding(
                get: { removingLibrary != nil },
                set: { isPresented in if !isPresented { removingLibrary = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { removingLibrary = nil }
            Button("Remove", role: .destructive) {
                guard let id = removingLibrary?.id else { return }
                removingLibrary = nil
                Task { await environment.removePhotoLibrary(id: id) }
            }
        } message: {
            Text("This removes \"\(removingLibrary?.name ?? "")\" and all of PhotoCurator's records for its photos — lifecycle state, album membership, export history. The original files on disk are never touched.")
        }
        .alert(
            "Could Not Add Library",
            isPresented: Binding(
                get: { addLibraryError != nil },
                set: { isPresented in if !isPresented { addLibraryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { addLibraryError = nil }
        } message: {
            Text(addLibraryError ?? "")
        }
        .alert(
            "Could Not Change Export Directory",
            isPresented: Binding(
                get: { exportDirectoryError != nil },
                set: { isPresented in if !isPresented { exportDirectoryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportDirectoryError = nil }
        } message: {
            Text(exportDirectoryError ?? "")
        }
    }

    private var importSheetBinding: Binding<Bool> {
        Binding(
            get: { manualImportSourceURL != nil },
            set: { isPresented in
                if !isPresented {
                    manualImportSourceURL?.stopAccessingSecurityScopedResource()
                    manualImportSourceURL = nil
                }
            }
        )
    }

    /// Which library a fresh import should default to: whichever one is currently
    /// selected in the sidebar filter, else the first registered library.
    private var defaultImportLibraryId: Int64? {
        if case .library(let id) = sidebarSelection, let id {
            return id
        }
        return environment.folderAccess.photoLibraries.first?.id
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Button {
                presentImportPicker()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Import photos from a folder or SD card")

            Label("All Photos", systemImage: "photo.on.rectangle")
                .tag(SidebarSelection.library(id: nil))

            Label("Unassigned Photos", systemImage: "tray")
                .tag(SidebarSelection.unassigned)

            Label("All Albums", systemImage: "square.grid.2x2")
                .tag(SidebarSelection.albumsOverview)
                .contextMenu {
                    Button("Change Export Directory…") {
                        presentChangeExportDirectoryPicker()
                    }
                }

            Section {
                ForEach(environment.folderAccess.photoLibraries) { library in
                    Label(library.name, systemImage: "folder")
                        .tag(SidebarSelection.library(id: library.id))
                        .contextMenu {
                            Button("Rename Library…") {
                                renameLibraryName = library.name
                                renamingLibrary = library
                            }
                            Button("Remove Library…", role: .destructive) {
                                removingLibrary = library
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Libraries")
                    Spacer()
                    Button {
                        presentAddLibraryPicker()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Add Photo Library…")
                }
            }

            Section {
                ForEach(environment.albums) { album in
                    Label(album.name, systemImage: "square.stack")
                        .tag(SidebarSelection.album(album.id ?? -1))
                        .contextMenu {
                            Button("Rename Album…") {
                                renameAlbumName = album.name
                                renamingAlbum = album
                            }
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
            if environment.isSyncingInBackground {
                ToolbarItem {
                    ProgressView()
                        .controlSize(.small)
                        .help("Syncing library changes…")
                }
            }
        }
    }

    /// A plain `NSOpenPanel` rather than SwiftUI's `.fileImporter` specifically so
    /// its starting folder can be seeded from `lastImportDirectoryHint` — the user
    /// otherwise has to re-navigate to the SD card from scratch on every import.
    private func presentImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the SD card or folder to import photos from."
        panel.directoryURL = lastImportDirectoryHint

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Security-scoped, same as a `.fileImporter` result — started here,
        // synchronously, and kept started for as long as the sheet is open (see
        // `importSheetBinding`, which stops it on dismiss).
        manualImportSourceURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else { return }
        manualImportSourceURL = url
        lastImportDirectoryHint = url

        // `makeBookmarkData` must run synchronously here, in the picker's own
        // completion — deferring it risks the transient grant window lapsing.
        // The DB write that persists it has no such constraint, so that part
        // alone is fine to hand off to a background Task.
        if let bookmark = try? BookmarkStore.makeBookmarkData(for: url) {
            Task { await BookmarkStore.saveLastImportSourceBookmarkData(bookmark, database: environment.database) }
        }
    }

    /// Same `NSOpenPanel` pattern as `presentImportPicker` — synchronous bookmark
    /// creation in the panel's own completion, async DB write after.
    private func presentAddLibraryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to register as a photo library."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard url.startAccessingSecurityScopedResource() else {
            addLibraryError = "Could not access \"\(url.lastPathComponent)\"."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try BookmarkStore.makeBookmarkData(for: url)
            Task {
                let ok = await environment.addPhotoLibrary(bookmarkData: bookmarkData, name: url.lastPathComponent)
                if !ok {
                    addLibraryError = "Could not add \"\(url.lastPathComponent)\"."
                }
            }
        } catch {
            addLibraryError = "Could not access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }

    /// Same `NSOpenPanel` pattern as `presentAddLibraryPicker` — synchronous
    /// bookmark creation in the panel's own completion, async DB write after.
    private func presentChangeExportDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder curated photos get exported into."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard url.startAccessingSecurityScopedResource() else {
            exportDirectoryError = "Could not access \"\(url.lastPathComponent)\"."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try BookmarkStore.makeBookmarkData(for: url)
            Task {
                let ok = await environment.changeExportTarget(bookmarkData: bookmarkData)
                if !ok {
                    exportDirectoryError = "Could not switch to \"\(url.lastPathComponent)\"."
                }
            }
        } catch {
            exportDirectoryError = "Could not access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch sidebarSelection {
        case .none:
            PhotoGridScreen(scope: .library(id: nil))
        case .library(let id):
            PhotoGridScreen(scope: .library(id: id))
        case .unassigned:
            PhotoGridScreen(scope: .unassigned)
        case .albumsOverview:
            AlbumsOverviewView { albumId in
                sidebarSelection = .album(albumId)
            }
        case .album(let albumId):
            PhotoGridScreen(scope: .album(albumId))
        }
    }
}

/// Shown only while re-resolving already-granted bookmarks at launch — deliberately
/// generic (no folder-picker affordances) so it doesn't imply anything is missing.
private struct LaunchSplashView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(minWidth: 480, minHeight: 420)
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
