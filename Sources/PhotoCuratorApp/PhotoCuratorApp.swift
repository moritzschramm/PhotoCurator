import SwiftUI
import PhotoCuratorUI

@main
struct PhotoCuratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment = appDelegate.environment {
                    RootView()
                        .environment(environment)
                } else {
                    Text("PhotoCurator could not start. Check Console for details.")
                        .padding()
                        .frame(width: 420, height: 200)
                }
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // `.commands` is evaluated exactly once, before `AppDelegate.environment`
            // even exists, and SwiftUI never re-evaluates it afterward for this app's
            // configuration — not on `environment` becoming non-nil, not on
            // `canUndo`/`canRedo` changing. Baking `.disabled(...)` to a value
            // computed at that one-time evaluation would freeze it permanently
            // disabled, so instead these are always enabled and each action reads
            // `canUndo`/`canRedo` *live* (a closure reads its captured reference's
            // current property values at call time, not at closure-creation time),
            // no-op'ing if there's genuinely nothing to undo/redo.
            CommandGroup(replacing: .undoRedo) {
                Button(appDelegate.environment?.undoManager.undoMenuItemTitle ?? "Undo") {
                    guard let undoManager = appDelegate.environment?.undoManager, undoManager.canUndo else { return }
                    undoManager.undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button(appDelegate.environment?.undoManager.redoMenuItemTitle ?? "Redo") {
                    guard let undoManager = appDelegate.environment?.undoManager, undoManager.canRedo else { return }
                    undoManager.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        Settings {
            if let environment = appDelegate.environment {
                SettingsView()
                    .environment(environment)
            }
        }
    }
}
