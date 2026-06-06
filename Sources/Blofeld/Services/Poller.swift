import Foundation

/// Drives the periodic polling loop. Owned by `AppState`; pushes results back
/// onto it (on the main actor). The loop re-reads the interval each cycle, so
/// changing it in Settings takes effect on the next tick; `reschedule()` forces
/// an immediate new cycle (used when hosts or the interval change).
@MainActor
final class Poller {
    weak var state: AppState?
    private let client = ServiceControlClient()
    private var loop: Task<Void, Never>?

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
        guard !hosts.isEmpty else {
            state.markUpdated()
            return
        }
        state.setRefreshing(true)
        for host in hosts {
            await poll(host: host)
        }
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
}
