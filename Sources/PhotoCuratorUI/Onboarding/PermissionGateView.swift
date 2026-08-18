import SwiftUI
import UniformTypeIdentifiers
import PhotoCuratorCore

/// First-run (and any-run, if a grant needs renewing) folder access gate (spec §9):
/// the app does not operate until at least one photo library and the export target
/// are both granted.
struct PermissionGateView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isExportPickerPresented = false
    @State private var pickError: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("PhotoCurator needs at least one photo library and an export folder")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Both are required before the app can run. Access is remembered after this.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Photo libraries")
                    .font(.headline)
                PhotoLibraryListView()

                Divider()
                    .padding(.vertical, 4)

                Text("Export / gallery target")
                    .font(.headline)
                grantRow(
                    title: "Export / gallery target folder",
                    granted: environment.folderAccess.exportTarget != nil,
                    action: { isExportPickerPresented = true }
                )
            }
            .frame(maxWidth: 440)

            if let pickError {
                Text(pickError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            } else if case .failed(let message) = environment.launchPhase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 520)
        .fileImporter(isPresented: $isExportPickerPresented, allowedContentTypes: [.folder]) { result in
            handleExportPick(result)
        }
    }

    private func grantRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
            Text(title)
            Spacer()
            Button(granted ? "Change…" : "Choose…", action: action)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func handleExportPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        // The picker hands back a URL with only a transient sandbox grant — it must
        // be activated with startAccessingSecurityScopedResource() before the app
        // can read the directory or mint a bookmark from it, otherwise bookmarkData
        // fails with a generic "couldn't be opened" error.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            // Bookmark creation itself must still happen synchronously, right here
            // in the picker's own completion handler — see
            // `BookmarkStore.makeBookmarkData`. Only the database write (no
            // security-scope timing constraint) is deferred to a Task.
            let bookmarkData = try BookmarkStore.makeBookmarkData(for: url)
            pickError = nil
            Task { await environment.grantExportAccess(bookmarkData: bookmarkData) }
        } catch {
            pickError = "Could not access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }
}
