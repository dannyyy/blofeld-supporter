import SwiftUI

/// Renders the island panel to a PNG and exits — used to verify the UI without
/// needing Screen Recording / Accessibility. Triggered by setting the
/// `BLOFELD_SNAPSHOT=<output.png>` environment variable.
enum SnapshotRunner {
    @MainActor
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["BLOFELD_SNAPSHOT"], !path.isEmpty else {
            return false
        }

        AppEnvironment.isSnapshot = true
        let state = AppState(startServices: false)
        let hostId = UUID()
        let healthyId = UUID()
        let queryId = UUID()
        state.config = AppConfig(
            hosts: [
                HostConfig(id: hostId, name: "Production",
                           apiHost: "https://sc", servicePulseHost: "https://sp",
                           endpoints: [EndpointConfig(name: "order-processor"),
                                       EndpointConfig(name: "product-catalog")]),
                HostConfig(id: healthyId, name: "Staging",
                           apiHost: "https://sc2", servicePulseHost: "https://sp2",
                           endpoints: [EndpointConfig(name: "checkout-service")])
            ],
            datadogQueries: [
                MonitorQueryConfig(id: queryId, name: "Blofeld team", query: "team:blofeld status:alert")
            ],
            pollSeconds: 60, notificationsEnabled: true, launchAtLogin: false)

        state.applyResults(hostId: hostId, results: [
            AppState.key(hostId, "order-processor"): EndpointStatus(
                name: "order-processor", newCount: 2, retriedCount: 5,
                servicePulseURL: URL(string: "https://sp/#/g1"), groupId: "g1"),
            AppState.key(hostId, "product-catalog"): EndpointStatus(
                name: "product-catalog")
        ], auth: .ok)
        state.applyResults(hostId: healthyId, results: [
            AppState.key(healthyId, "checkout-service"): EndpointStatus(name: "checkout-service")
        ], auth: .ok)
        state.setPupAvailability(.ok(site: "datadoghq.eu"))
        state.applyMonitorResults(queryId: queryId, status: MonitorQueryStatus(
            id: queryId, name: "Blofeld team", query: "team:blofeld status:alert",
            monitors: [
                MonitorStatus(id: 1, name: "Payables has failed messages in error queue",
                              state: .alert, priority: 2, tags: ["team:blofeld"],
                              url: URL(string: "https://app.datadoghq.eu/monitors/1")),
                MonitorStatus(id: 2, name: "Checkout p95 latency high",
                              state: .warn, tags: ["team:blofeld"],
                              url: URL(string: "https://app.datadoghq.eu/monitors/2")),
                MonitorStatus(id: 3, name: "Order processor heartbeat",
                              state: .ok, tags: ["team:blofeld"],
                              url: URL(string: "https://app.datadoghq.eu/monitors/3"))
            ],
            availability: .ok(site: "datadoghq.eu"), truncatedBy: 4))
        state.toast(.success, "Retry requested for order-processor")

        let wantsSettings = ProcessInfo.processInfo.environment["BLOFELD_SNAPSHOT_SETTINGS"] != nil

        let view: AnyView = wantsSettings
            ? AnyView(GeneralSettingsView(snapshot: true).environmentObject(state).frame(width: 510))
            : AnyView(IslandPanelView().environmentObject(state).frame(width: Theme.panelWidth))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        return true
    }
}
