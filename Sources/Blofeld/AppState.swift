import SwiftUI
import Combine

/// Central observable state shared across the menu bar label, the island panel
/// and the settings window.
///
/// The panel always reflects the user's `config`: `hosts` is derived by merging
/// each configured endpoint with the latest poll `results`. The `Poller` pushes
/// results in via `applyResults` / `applyAuth`.
@MainActor
final class AppState: ObservableObject {
    @Published var config: AppConfig {
        didSet { onConfigChanged(from: oldValue) }
    }
    /// Latest per-endpoint poll results, keyed by "<hostId>/<endpoint>".
    @Published private(set) var results: [String: EndpointStatus] = [:]
    /// Per-host authentication/reachability state, keyed by host id.
    @Published private(set) var authStates: [UUID: AuthState] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing: Bool = false
    /// Transient action-feedback messages shown in the panel.
    @Published private(set) var toasts: [Toast] = []
    /// Endpoint keys with a retry currently in flight (disables the button).
    @Published private(set) var retrying: Set<String> = []

    private let store = ConfigStore()
    private let poller = Poller()
    private let authManager = AuthManager()
    private let client = ServiceControlClient()
    private var rescheduleDebounce: Task<Void, Never>?

    init(startServices: Bool = true) {
        self.config = store.load() ?? .default
        poller.state = self
        guard startServices else { return }   // snapshot/preview: no network or login item
        EventLog.shared.log(.info, "Blofeld started — \(config.hosts.count) host(s), polling every \(config.pollSeconds)s")
        NotificationService.shared.start()
        LaunchAtLogin.apply(config.launchAtLogin)
        poller.start()
    }

    /// The host/endpoint tree the UI renders — derived from `config` + `results`.
    var hosts: [HostStatus] {
        config.hosts.map { host in
            HostStatus(
                id: host.id,
                name: host.name.isEmpty ? "Untitled host" : host.name,
                endpoints: host.endpoints.map { endpoint in
                    results[Self.key(host.id, endpoint.name)]
                        ?? EndpointStatus(name: endpoint.name)
                },
                authState: authStates[host.id] ?? .unknown
            )
        }
    }

    var totalErrors: Int { hosts.reduce(0) { $0 + $1.totalCount } }
    var totalNew: Int { hosts.reduce(0) { $0 + $1.newCount } }
    var anyNeedsAuth: Bool { hosts.contains { $0.needsAuth } }
    var isHealthy: Bool { totalErrors == 0 && !anyNeedsAuth }

    static func key(_ hostId: UUID, _ endpoint: String) -> String {
        "\(hostId.uuidString)/\(endpoint)"
    }

    // MARK: - User actions

    func refresh() {
        poller.pollNow()
    }

    /// Opens the in-app SSO login window for a host, then re-polls on success.
    func authenticate(hostId: UUID) {
        guard let host = config.hosts.first(where: { $0.id == hostId }) else { return }
        authManager.login(apiHost: host.apiHost) { [weak self] in
            guard let self else { return }
            self.authStates[hostId] = .unknown
            self.toast(.success, "Signed in to \(host.name.isEmpty ? "host" : host.name)")
            self.poller.pollNow()
        }
    }

    /// Retries all failed messages for an endpoint's recoverability group.
    func retry(hostId: UUID, endpoint: String) {
        let key = Self.key(hostId, endpoint)
        guard !retrying.contains(key) else { return }
        guard let host = config.hosts.first(where: { $0.id == hostId }) else { return }
        guard let groupId = results[key]?.groupId else {
            toast(.error, "No failure group to retry for \(endpoint)")
            return
        }
        retrying.insert(key)
        Task {
            defer { retrying.remove(key) }
            do {
                try await client.retryGroup(apiHost: host.apiHost, groupId: groupId)
                toast(.success, "Retry requested for \(endpoint)")
                poller.pollNow()
            } catch ServiceControlError.needsAuth {
                authStates[hostId] = .needsAuth
                toast(.error, "Sign in required to retry \(endpoint)")
            } catch {
                toast(.error, "Retry failed for \(endpoint): \(ServiceControlClient.describe(error))")
            }
        }
    }

    // MARK: - Toasts

    func toast(_ kind: ToastKind, _ message: String) {
        let toast = Toast(kind: kind, message: message)
        withAnimationIfPossible { toasts.append(toast) }
        EventLog.shared.log(kind.logLevel, message)
        Task {
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            dismissToast(toast.id)
        }
    }

    func dismissToast(_ id: UUID) {
        withAnimationIfPossible { toasts.removeAll { $0.id == id } }
    }

    private func withAnimationIfPossible(_ body: () -> Void) {
        withAnimation(Theme.quickSpring) { body() }
    }

    // MARK: - Poller callbacks

    func setRefreshing(_ value: Bool) { isRefreshing = value }
    func markUpdated() { lastUpdated = Date() }

    func applyResults(hostId: UUID, results new: [String: EndpointStatus], auth: AuthState) {
        if config.notificationsEnabled {
            let hostName = config.hosts.first(where: { $0.id == hostId })?.name ?? "host"
            for (key, value) in new {
                // Notify only when we have a prior baseline and the count rose —
                // avoids spam on first poll and on every steady-state tick.
                if let previous = results[key], value.totalCount > previous.totalCount {
                    NotificationService.shared.notifyIncrease(
                        endpoint: value.name,
                        host: hostName.isEmpty ? "host" : hostName,
                        delta: value.totalCount - previous.totalCount,
                        total: value.totalCount)
                }
            }
        }
        for (key, value) in new { results[key] = value }
        authStates[hostId] = auth
    }

    func applyAuth(hostId: UUID, _ auth: AuthState) {
        authStates[hostId] = auth
    }

    // MARK: - Config changes

    private func onConfigChanged(from old: AppConfig) {
        store.save(config)
        if old.launchAtLogin != config.launchAtLogin {
            LaunchAtLogin.apply(config.launchAtLogin)
        }
        if old.pollSeconds != config.pollSeconds || old.hosts != config.hosts {
            // Drop results for endpoints that no longer exist.
            pruneResults()
            // Debounce: editing a host name/URL fires a change per keystroke —
            // coalesce so we re-poll once the user pauses, not on every letter.
            rescheduleDebounce?.cancel()
            rescheduleDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.poller.reschedule()
            }
        }
    }

    private func pruneResults() {
        let valid = Set(config.hosts.flatMap { host in
            host.endpoints.map { Self.key(host.id, $0.name) }
        })
        results = results.filter { valid.contains($0.key) }
        let validHosts = Set(config.hosts.map { $0.id })
        authStates = authStates.filter { validHosts.contains($0.key) }
    }
}
