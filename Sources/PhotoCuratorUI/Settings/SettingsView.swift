import SwiftUI
import PhotoCuratorCore

/// The app's `Settings { }` scene (Cmd+,) — currently just the "Reset App" danger
/// zone, a rare, app-wide, destructive action that doesn't belong on any single
/// sidebar row.
public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingReset = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                Button("Reset App…", role: .destructive) {
                    isConfirmingReset = true
                }
                Text("Wipes every photo library, album, and export record PhotoCurator knows about, and takes you back through first-time setup. Files already on disk — your originals, and anything already exported — are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Danger Zone")
            }
        }
        .padding()
        .frame(width: 420, height: 220)
        .alert("Reset App to Zero?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await environment.resetApp()
                    await environment.bootstrap()
                }
            }
        } message: {
            Text("This permanently erases PhotoCurator's database — every registered library, photo, album, and export record — and takes you back through first-time setup. This cannot be undone. Your original photo files and anything already exported are never touched.")
        }
    }
}
