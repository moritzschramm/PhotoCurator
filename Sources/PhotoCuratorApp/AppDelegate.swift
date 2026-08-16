import AppKit
import PhotoCuratorUI

/// Owns the one `AppEnvironment` for the app session and hooks the two lifecycle
/// moments SwiftUI's `App` protocol doesn't expose directly: kicking off the launch
/// sequence, and blocking quit just long enough to write the final snapshot
/// (spec §3: "on quit").
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?
    private var didSnapshotBeforeQuit = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            environment = try AppEnvironment()
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
