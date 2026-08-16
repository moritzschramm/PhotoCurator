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
    }
}
