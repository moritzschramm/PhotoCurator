import SwiftUI
import UniformTypeIdentifiers
import PhotoCuratorCore

/// First-run (and any-run, if a grant needs renewing) folder access gate (spec §9):
/// the app does not operate until both the photo library and export target folders
/// are granted.
struct PermissionGateView: View {
    @Environment(AppEnvironment.self) private var environment
    // A single `.fileImporter`, not one per button: attaching two of them to the same
    // view is a known SwiftUI/macOS quirk where only the outermost one reliably
    // presents — the other's `isPresented` flips true but no panel appears.
    //
    // `pickerRole` and `isPickerPresented` are deliberately two independent state
    // vars, not one Optional driving both via a computed Binding: if `set` on that
    // Binding clears the role as soon as the panel dismisses, it can race with (or
    // run before) `onCompletion` reading it, so the completion handler silently
    // never fires. `pickerRole` here is only ever written by the buttons and only
    // ever read by `onCompletion` — nothing else clears it.
    @State private var pickerRole: FolderRole = .photoLibrary
    @State private var isPickerPresented = false
    @State private var pickError: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("PhotoCurator needs two folders")
                .font(.title2.bold())

            Text("Both are required before the app can run. Access is remembered after this.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                grantRow(
                    title: "Photo library (Proton Drive folder)",
                    granted: environment.folderAccess.photoLibrary != nil,
                    action: { pickerRole = .photoLibrary; isPickerPresented = true }
                )
                grantRow(
                    title: "Export / gallery target folder",
                    granted: environment.folderAccess.exportTarget != nil,
                    action: { pickerRole = .exportTarget; isPickerPresented = true }
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
        .frame(minWidth: 480, minHeight: 420)
        .fileImporter(isPresented: $isPickerPresented, allowedContentTypes: [.folder]) { result in
            handlePick(result, role: pickerRole)
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

    private func handlePick(_ result: Result<URL, Error>, role: FolderRole) {
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
            Task { await environment.grantAccess(bookmarkData: bookmarkData, role: role) }
        } catch {
            pickError = "Could not access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }
}
