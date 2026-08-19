import AppKit
import Combine
import PhotoCuratorUI

/// Owns the one `AppEnvironment` for the app session and hooks the two lifecycle
/// moments SwiftUI's `App` protocol doesn't expose directly: kicking off the launch
/// sequence, and blocking quit just long enough to write the final snapshot
/// (spec §3: "on quit").
///
/// Conforms to `ObservableObject` with `environment` as `@Published` specifically so
/// `PhotoCuratorApp`'s `WindowGroup` gets re-evaluated once `environment` actually
/// becomes non-nil. `@NSApplicationDelegateAdaptor` only re-invalidates views when the
/// delegate publishes changes this way (documented Apple behavior); without it, the
/// window body would only ever see whatever `environment` held at its very first
/// evaluation — which can race ahead of `applicationWillFinishLaunching` setting it —
/// leaving the app stuck on the "could not start" placeholder. Note this does *not*
/// extend to the `.commands` menu, which is built exactly once and never re-evaluated
/// no matter what is published here; see `PhotoCuratorApp` for how Undo/Redo works
/// around that.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    private var didSnapshotBeforeQuit = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            self.environment = try AppEnvironment()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "PhotoCurator could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let environment else { return }
        Task { await environment.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment, !didSnapshotBeforeQuit else { return .terminateNow }
        Task {
            await environment.snapshotBeforeQuit()
            didSnapshotBeforeQuit = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
