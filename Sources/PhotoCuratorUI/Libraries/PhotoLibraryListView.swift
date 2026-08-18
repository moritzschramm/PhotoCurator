import SwiftUI
import AppKit
import PhotoCuratorCore

/// Shared "settings-style list" of registered photo-library directories — add/remove/
/// rename. Reused by both `PermissionGateView` (onboarding) and the app's `Settings`
/// scene (managing libraries after first run).
struct PhotoLibraryListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var renamingLibrary: PhotoLibraryFolder?
    @State private var renameText = ""
    @State private var removingLibrary: PhotoLibraryFolder?
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if environment.folderAccess.photoLibraries.isEmpty {
                Text("No photo libraries yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List(environment.folderAccess.photoLibraries) { library in
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.secondary)
                        Text(library.name)
                        Spacer()
                        Button("Rename…") {
                            renameText = library.name
                            renamingLibrary = library
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Button("Remove…") {
                            removingLibrary = library
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }

            Button {
                presentAddLibraryPicker()
            } label: {
                Label("Add Library…", systemImage: "plus.circle")
            }

            if let addError {
                Text(addError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .alert(
            "Rename Library",
            isPresented: Binding(
                get: { renamingLibrary != nil },
                set: { isPresented in if !isPresented { renamingLibrary = nil } }
            )
        ) {
            TextField("Library name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingLibrary = nil }
            Button("Rename") {
                guard let id = renamingLibrary?.id else { return }
                let name = renameText
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
    }

    /// A plain `NSOpenPanel`, matching the exact pattern in
    /// `RootView.presentImportPicker()` — synchronous bookmark creation in the
    /// panel's own completion, async DB write after.
    private func presentAddLibraryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to register as a photo library."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard url.startAccessingSecurityScopedResource() else {
            addError = "Could not access \"\(url.lastPathComponent)\"."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try BookmarkStore.makeBookmarkData(for: url)
            addError = nil
            Task {
                let ok = await environment.addPhotoLibrary(bookmarkData: bookmarkData, name: url.lastPathComponent)
                if !ok {
                    addError = "Could not add \"\(url.lastPathComponent)\"."
                }
            }
        } catch {
            addError = "Could not access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }
}
