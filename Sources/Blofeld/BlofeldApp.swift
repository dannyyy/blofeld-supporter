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
            // Auto-inverting template logo + a count of things needing attention
            // (NServiceBus errors + alerting Datadog monitors) when present.
            Image(nsImage: AppAssets.menuBar(pointSize: 18))
            if state.menuBarBadgeCount > 0 {
                Text("\(state.menuBarBadgeCount)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
