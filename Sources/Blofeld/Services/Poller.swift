import Foundation

/// Drives the periodic polling loop. Owned by `AppState`; pushes results back
/// onto it (on the main actor). The loop re-reads the interval each cycle, so
/// changing it in Settings takes effect on the next tick; `reschedule()` forces
/// an immediate new cycle (used when hosts or the interval change).
@MainActor
final class Poller {
    weak var state: AppState?
    private let client = ServiceControlClient()
    private let pup = PupClient()
    private var loop: Task<Void, Never>?

    /// Monitors fetched per query (a page large enough to count alerts among
    /// many matches) vs. how many are kept/shown after the alerting-first sort.
    private static let fetchCap = 100
    private static let displayCap = 25

    func start() {
        reschedule()
    }

    /// Cancels the running loop and starts a fresh one (polls immediately).
    func reschedule() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                let seconds = self?.state?.config.pollSeconds ?? 60
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    /// One-shot poll (manual refresh button).
    func pollNow() {
        Task { await pollAll() }
    }

    private func pollAll() async {
        guard let state else { return }
        let hosts = state.config.hosts
        let queries = state.config.datadogQueries
        guard !hosts.isEmpty || !queries.isEmpty else {
            state.markUpdated()
            return
        }
        state.setRefreshing(true)
        for host in hosts {
            await poll(host: host)
        }
        await pollDatadog(queries: queries)
        state.markUpdated()
        state.setRefreshing(false)
    }

    private func poll(host: HostConfig) async {
        guard let state else { return }
        do {
            // Group lookup is best-effort: it only resolves ServicePulse links.
            let groups = (try? await client.recoverabilityGroups(apiHost: host.apiHost)) ?? []

            var results: [String: EndpointStatus] = [:]
            for endpoint in host.endpoints {
                let errors = try await client.errors(apiHost: host.apiHost, endpoint: endpoint.name)
                let newCount = errors.filter { $0.numberOfProcessingAttempts == 1 }.count
                let retriedCount = errors.filter { $0.numberOfProcessingAttempts > 1 }.count

                var servicePulseURL: URL?
                var groupId: String?
                if newCount + retriedCount > 0,
                   let group = groups.first(where: { $0.title == endpoint.name }) {
                    groupId = group.id
                    servicePulseURL = ServiceControlClient.servicePulseURL(
                        servicePulseHost: host.servicePulseHost, groupId: group.id)
                }

                results[AppState.key(host.id, endpoint.name)] = EndpointStatus(
                    name: endpoint.name,
                    newCount: newCount,
                    retriedCount: retriedCount,
                    servicePulseURL: servicePulseURL,
                    groupId: groupId)
            }
            state.applyResults(hostId: host.id, results: results, auth: .ok)
            let total = results.values.reduce(0) { $0 + $1.totalCount }
            let new = results.values.reduce(0) { $0 + $1.newCount }
            EventLog.shared.log(.info, "\(host.name): polled \(host.endpoints.count) endpoint(s) — \(total) error(s), \(new) new")
        } catch ServiceControlError.needsAuth {
            state.applyAuth(hostId: host.id, .needsAuth)
            EventLog.shared.log(.info, "\(host.name): authentication required")
        } catch {
            let message = ServiceControlClient.describe(error)
            state.applyAuth(hostId: host.id, .error(message))
            EventLog.shared.log(.error, "\(host.name): poll failed — \(message)")
        }
    }

    // MARK: - Datadog monitors (via the pup CLI)

    private func pollDatadog(queries: [MonitorQueryConfig]) async {
        guard let state, !queries.isEmpty else { return }

        let availability = await pup.availability(sitesToTry: state.pupSitesToProbe())
        state.setPupAvailability(availability)

        // If pup isn't usable, surface the reason on every query and stop.
        guard case .ok(let site) = availability else {
            for query in queries {
                state.applyMonitorResults(queryId: query.id, status: MonitorQueryStatus(
                    id: query.id, name: query.name, query: query.query, availability: availability))
            }
            EventLog.shared.log(.info, "Datadog: pup unavailable — \(PupAvailability.describe(availability))")
            return
        }

        for query in queries {
            await poll(query: query, site: site)
        }
    }

    private func poll(query: MonitorQueryConfig, site: String) async {
        guard let state else { return }
        let trimmed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.applyMonitorResults(queryId: query.id, status: MonitorQueryStatus(
                id: query.id, name: query.name, query: query.query, availability: .ok(site: site)))
            return
        }
        do {
            let result = try await pup.searchMonitors(query: trimmed, site: site, perPage: Self.fetchCap)
            // Sort alerting-first, then keep the display cap; report the rest as
            // "+N more" relative to the *total* the query matched.
            let sorted = result.monitors.sorted { a, b in
                if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            let kept = Array(sorted.prefix(Self.displayCap))
            let truncated = max(0, result.totalMatched - kept.count)
            let status = MonitorQueryStatus(
                id: query.id, name: query.name, query: query.query,
                monitors: kept, availability: .ok(site: site), truncatedBy: truncated)
            state.applyMonitorResults(queryId: query.id, status: status)
            EventLog.shared.log(.info, "\(query.name): \(result.totalMatched) monitor(s) matched, \(status.alertCount) alerting")
        } catch PupError.notAuthenticated {
            state.setPupAvailability(.notAuthenticated)
            state.applyMonitorResults(queryId: query.id, status: MonitorQueryStatus(
                id: query.id, name: query.name, query: query.query, availability: .notAuthenticated))
            EventLog.shared.log(.info, "\(query.name): Datadog authentication required")
        } catch {
            let message = PupClient.describe(error)
            state.applyMonitorResults(queryId: query.id, status: MonitorQueryStatus(
                id: query.id, name: query.name, query: query.query, availability: .error(message)))
            EventLog.shared.log(.error, "\(query.name): Datadog query failed — \(message)")
        }
    }
}
