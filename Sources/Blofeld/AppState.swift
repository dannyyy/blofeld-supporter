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
    /// Latest Datadog monitor results, keyed by query id.
    @Published private(set) var monitorResults: [UUID: MonitorQueryStatus] = [:]
    /// Whether the `pup` CLI is installed & authenticated (drives the panel
    /// banner and the Settings diagnostics box).
    @Published private(set) var pupAvailability: PupAvailability = .unknown
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing: Bool = false
    /// Transient action-feedback messages shown in the panel.
    @Published private(set) var toasts: [Toast] = []
    /// Endpoint keys with a retry currently in flight (disables the button).
    @Published private(set) var retrying: Set<String> = []
    /// Latest Service Bus queue results, keyed by "<namespaceId>/<queue>".
    @Published private(set) var queueResults: [String: QueueStatus] = [:]
    /// Per-namespace reachability, keyed by namespace id.
    @Published private(set) var namespaceStates: [UUID: AuthState] = [:]
    /// Whether the `az` CLI is installed & signed in.
    @Published private(set) var azAvailability: AzAvailability = .unknown
    /// Queue keys with a DLQ resubmit currently in flight.
    @Published private(set) var resubmitting: Set<String> = []

    private let store = ConfigStore()
    private let poller = Poller()
    private let authManager = AuthManager()
    private let client = ServiceControlClient()
    private let pupClient = PupClient()
    private let azClient = AzureCLIClient()
    private let serviceBusClient = ServiceBusClient()
    private var rescheduleDebounce: Task<Void, Never>?

    init(startServices: Bool = true) {
        self.config = store.load() ?? .default
        poller.state = self
        guard startServices else { return }   // snapshot/preview: no network or login item
        EventLog.shared.log(.info, "Blofeld started — \(config.hosts.count) host(s), \(config.datadogQueries.count) Datadog query(ies), \(config.serviceBusNamespaces.count) Service Bus namespace(s), polling every \(config.pollSeconds)s")
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

    /// The Datadog query/monitor tree the UI renders — derived from `config` +
    /// `monitorResults` (same pattern as `hosts`), so query edits show instantly.
    var monitorQueries: [MonitorQueryStatus] {
        config.datadogQueries.map { query in
            let name = query.name.isEmpty ? "Untitled query" : query.name
            if var existing = monitorResults[query.id] {
                existing.name = name
                existing.query = query.query
                return existing
            }
            return MonitorQueryStatus(id: query.id, name: name, query: query.query,
                                      availability: pupAvailability)
        }
    }

    /// The Service Bus namespace/queue tree the UI renders — derived from
    /// `config` + `queueResults` (same pattern as `hosts`).
    var serviceBusNamespaces: [ServiceBusNamespaceStatus] {
        config.serviceBusNamespaces.map { ns in
            ServiceBusNamespaceStatus(
                id: ns.id,
                name: ns.name.isEmpty ? "Untitled namespace" : ns.name,
                queues: ns.queues.map { queue in
                    queueResults[Self.key(ns.id, queue.name)] ?? QueueStatus(name: queue.name)
                },
                state: namespaceStates[ns.id] ?? .unknown,
                availability: azAvailability)
        }
    }

    var totalErrors: Int { hosts.reduce(0) { $0 + $1.totalCount } }
    var totalNew: Int { hosts.reduce(0) { $0 + $1.newCount } }
    var totalAlertingMonitors: Int { monitorQueries.reduce(0) { $0 + $1.alertCount } }
    var totalDeadLetters: Int { serviceBusNamespaces.reduce(0) { $0 + $1.totalDeadLetters } }
    var anyNeedsAuth: Bool { hosts.contains { $0.needsAuth } }
    /// Combined attention count shown on the menu-bar icon (errors + alerts +
    /// dead letters).
    var menuBarBadgeCount: Int { totalErrors + totalAlertingMonitors + totalDeadLetters }
    var isHealthy: Bool {
        totalErrors == 0 && totalAlertingMonitors == 0 && totalDeadLetters == 0 && !anyNeedsAuth
    }

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

    /// Moves a queue's dead-lettered messages back into the queue (bounded per
    /// click), then re-polls.
    func resubmit(namespaceId: UUID, queue: String) {
        let key = Self.key(namespaceId, queue)
        guard !resubmitting.contains(key) else { return }
        guard let ns = config.serviceBusNamespaces.first(where: { $0.id == namespaceId }) else { return }
        let freshMessageId = queueResults[key]?.duplicateDetection ?? false
        resubmitting.insert(key)
        Task {
            defer { resubmitting.remove(key) }
            let token: String
            do {
                token = try await azClient.accessToken()
            } catch {
                toast(.error, "Resubmit failed for \(queue): \(AzureCLIClient.describe(error))")
                return
            }
            if freshMessageId {
                EventLog.shared.log(.info, "\(queue): duplicate detection is on — resubmitted copies get a new MessageId")
            }
            let outcome = await serviceBusClient.resubmitDeadLetters(
                namespace: ns.namespace, queue: queue, token: token,
                limit: Self.resubmitLimit, freshMessageId: freshMessageId)
            let moved = "\(outcome.resubmitted) message\(outcome.resubmitted == 1 ? "" : "s")"
            if let error = outcome.error {
                if case ServiceBusError.forbidden(401) = error { await azClient.invalidateToken() }
                let reason = ServiceBusClient.describe(error)
                toast(.error, outcome.resubmitted > 0
                      ? "Resubmitted \(moved) from \(queue), then stopped: \(reason)"
                      : "Resubmit failed for \(queue): \(reason)")
            } else if outcome.resubmitted == 0 {
                toast(.success, "No dead-lettered messages left in \(queue)")
            } else {
                toast(.success, "Resubmitted \(moved) from \(queue)")
            }
            poller.pollNow()
        }
    }

    /// Upper bound of messages moved per resubmit click.
    static let resubmitLimit = 500

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

    func applyQueueResults(namespaceId: UUID, results new: [String: QueueStatus], state: AuthState) {
        if config.notificationsEnabled {
            let nsName = config.serviceBusNamespaces.first(where: { $0.id == namespaceId })?.name ?? ""
            for (key, value) in new {
                // Same baseline rule as `applyResults`: only notify on a rise.
                if let previous = queueResults[key], value.deadLetterCount > previous.deadLetterCount {
                    NotificationService.shared.notifyDeadLetterIncrease(
                        queue: value.name,
                        namespace: nsName.isEmpty ? "namespace" : nsName,
                        delta: value.deadLetterCount - previous.deadLetterCount,
                        total: value.deadLetterCount)
                }
            }
        }
        for (key, value) in new { queueResults[key] = value }
        namespaceStates[namespaceId] = state
    }

    func applyNamespaceState(namespaceId: UUID, _ state: AuthState) {
        namespaceStates[namespaceId] = state
    }

    func setAzAvailability(_ availability: AzAvailability) {
        azAvailability = availability
    }

    /// Re-checks the `az` CLI off the poll loop (Settings diagnostics box).
    func refreshAzAvailability() {
        Task { self.azAvailability = await azClient.availability() }
    }

    func setPupAvailability(_ availability: PupAvailability) {
        pupAvailability = availability
    }

    /// The `DD_SITE` values to probe, best-guess first. An explicit configured
    /// site wins; otherwise try the last authenticated site, then all known
    /// sites. Keeps the steady state to a single `pup` call while still
    /// auto-detecting the site on a fresh machine.
    func pupSitesToProbe() -> [String] {
        let configured = config.datadogSite.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return [configured] }
        var sites: [String] = []
        if case .ok(let site) = pupAvailability { sites.append(site) }
        for site in DatadogSite.known where !sites.contains(site) { sites.append(site) }
        return sites
    }

    /// Re-checks the `pup` CLI off the poll loop (Settings diagnostics box).
    func refreshPupAvailability() {
        let sites = pupSitesToProbe()
        Task { self.pupAvailability = await pupClient.availability(sitesToTry: sites) }
    }

    func applyMonitorResults(queryId: UUID, status: MonitorQueryStatus) {
        if config.notificationsEnabled, status.availability.isOk,
           let previous = monitorResults[queryId], previous.availability.isOk {
            // Notify only for monitors that *newly* entered Alert since the last
            // successful poll — no spam on first poll or steady state.
            let priorAlerting = Set(previous.monitors.filter { $0.state == .alert }.map(\.id))
            for monitor in status.monitors where monitor.state == .alert && !priorAlerting.contains(monitor.id) {
                NotificationService.shared.notifyMonitorAlert(monitor: monitor.name, query: status.name)
            }
        }
        monitorResults[queryId] = status
    }

    // MARK: - Config changes

    private func onConfigChanged(from old: AppConfig) {
        store.save(config)
        if old.launchAtLogin != config.launchAtLogin {
            LaunchAtLogin.apply(config.launchAtLogin)
        }
        if old.pollSeconds != config.pollSeconds || old.hosts != config.hosts
            || old.datadogQueries != config.datadogQueries
            || old.datadogSite != config.datadogSite
            || old.serviceBusNamespaces != config.serviceBusNamespaces {
            // Drop results for endpoints / queries that no longer exist.
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
        let validQueries = Set(config.datadogQueries.map { $0.id })
        monitorResults = monitorResults.filter { validQueries.contains($0.key) }
        let validQueues = Set(config.serviceBusNamespaces.flatMap { ns in
            ns.queues.map { Self.key(ns.id, $0.name) }
        })
        queueResults = queueResults.filter { validQueues.contains($0.key) }
        let validNamespaces = Set(config.serviceBusNamespaces.map { $0.id })
        namespaceStates = namespaceStates.filter { validNamespaces.contains($0.key) }
    }
}
