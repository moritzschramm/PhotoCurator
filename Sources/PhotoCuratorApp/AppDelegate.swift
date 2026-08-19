import AppKit
import Combine
import PhotoCuratorUI

/// Owns the one `AppEnvironment` for the app session and hooks the two lifecycle
/// moments SwiftUI's `App` protocol doesn't expose directly: kicking off the launch
/// sequence, and blocking quit just long enough to write the final snapshot
/// (spec §3: "on quit").
///
/// Conforms to `ObservableObject` with `environment` as `@Published` specifically so
/// `PhotoCuratorApp.body` — including its `.commands` menu — gets re-evaluated once
/// `environment` actually becomes non-nil. `@NSApplicationDelegateAdaptor` only
/// re-invalidates views/commands when the delegate publishes changes this way
/// (documented Apple behavior); without it, `body` would only ever see whatever
/// `environment` held at its very first evaluation — which can race ahead of
/// `applicationWillFinishLaunching` setting it — silently freezing the Undo/Redo menu
/// as permanently empty instead of just disabled.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    /// Mirrors `environment.undoManager`'s state as `@Published` properties on this
    /// same already-proven-reactive object, rather than reading
    /// `environment?.canUndo` directly from `.commands` — `environment` is itself
    /// `@Observable`, and SwiftUI's `.commands` builder doesn't reliably re-evaluate
    /// when a property *inside* an already-set `@Published` value changes (only when
    /// the published value itself is reassigned), so undoing/redoing worked
    /// internally but the Edit menu stayed stuck disabled without this bridge.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var didSnapshotBeforeQuit = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment()
            self.environment = environment
            observeUndoManager(environment.undoManager)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "PhotoCurator could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func observeUndoManager(_ undoManager: UndoManager) {
        for name: Notification.Name in [.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                self?.canUndo = undoManager.canUndo
                self?.canRedo = undoManager.canRedo
            }
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
