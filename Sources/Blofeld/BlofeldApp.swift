import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snapshot mode: render the panel to a PNG and quit.
        if SnapshotRunner.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
    }
}

@main
struct BlofeldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            IslandPanelView()
                .environmentObject(state)
        } label: {
            // Auto-inverting template logo + an error count when present.
            Image(nsImage: AppAssets.menuBar(pointSize: 18))
            if state.totalErrors > 0 {
                Text("\(state.totalErrors)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
