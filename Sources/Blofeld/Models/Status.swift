import Foundation

/// Whether a host's API is currently reachable / authenticated.
enum AuthState: Equatable {
    case ok
    case needsAuth
    case error(String)
    case unknown
}

/// Live status for a single observed endpoint.
struct EndpointStatus: Identifiable, Equatable {
    /// The endpoint name doubles as a stable identity within a host.
    var id: String { name }
    var name: String
    /// Errors on their first processing attempt (`number_of_processing_attempts == 1`).
    var newCount: Int
    /// Errors that were already retried (`number_of_processing_attempts > 1`).
    var retriedCount: Int
    /// Deep link into ServicePulse for this endpoint's failure group.
    /// Only available once at least one error exists.
    var servicePulseURL: URL?
    /// The recoverability group id for this endpoint (needed to retry).
    /// Only available once at least one error exists.
    var groupId: String?

    var totalCount: Int { newCount + retriedCount }
    var hasErrors: Bool { totalCount > 0 }
    var canRetry: Bool { groupId != nil }

    init(name: String, newCount: Int = 0, retriedCount: Int = 0, servicePulseURL: URL? = nil, groupId: String? = nil) {
        self.name = name
        self.newCount = newCount
        self.retriedCount = retriedCount
        self.servicePulseURL = servicePulseURL
        self.groupId = groupId
    }
}

// MARK: - Datadog monitors

/// The overall state of a Datadog monitor, mapped from the `status` string
/// returned by `pup monitors search` ("Alert", "Warn", "OK", "No Data").
enum MonitorState: String, Equatable {
    case alert
    case warn
    case ok
    case noData
    case unknown

    init(apiStatus: String) {
        switch apiStatus.lowercased() {
        case "alert": self = .alert
        case "warn": self = .warn
        case "ok": self = .ok
        case "no data": self = .noData
        default: self = .unknown
        }
    }

    /// Needs attention (sorts to the top of a query's list).
    var isAttention: Bool { self == .alert || self == .warn }

    /// Short label shown next to a monitor row.
    var label: String {
        switch self {
        case .alert: return "alert"
        case .warn: return "warn"
        case .ok: return "ok"
        case .noData: return "no data"
        case .unknown: return "unknown"
        }
    }

    /// Sort weight: alerting first, then warn, no-data, ok, unknown.
    var sortRank: Int {
        switch self {
        case .alert: return 0
        case .warn: return 1
        case .noData: return 2
        case .ok: return 3
        case .unknown: return 4
        }
    }
}

/// Live status for a single Datadog monitor matched by a query.
struct MonitorStatus: Identifiable, Equatable {
    /// The Datadog monitor id.
    var id: Int
    var name: String
    var state: MonitorState
    /// Datadog priority (1 = highest … 5), if set.
    var priority: Int?
    var tags: [String]
    /// Deep link into Datadog for this monitor.
    var url: URL?

    init(id: Int, name: String, state: MonitorState, priority: Int? = nil, tags: [String] = [], url: URL? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.priority = priority
        self.tags = tags
        self.url = url
    }
}

/// Whether the `pup` CLI is usable for Datadog queries.
enum PupAvailability: Equatable {
    case ok(site: String)
    case notInstalled
    case notAuthenticated
    case error(String)
    case unknown

    var isOk: Bool { if case .ok = self { return true } else { return false } }

    /// Short status label for the diagnostics box / panel banner.
    var label: String {
        switch self {
        case .ok(let site): return "Installed & authenticated (\(site))"
        case .notInstalled: return "pup CLI not found"
        case .notAuthenticated: return "Not authenticated"
        case .error(let message): return message
        case .unknown: return "Checking…"
        }
    }

    /// A short remediation hint shown under the status, when applicable.
    var hint: String? {
        switch self {
        case .notInstalled:
            return "Install the Datadog CLI:\n  brew tap datadog-labs/pack\n  brew install pup"
        case .notAuthenticated:
            return "Sign in to Datadog:\n  pup auth login"
        case .error:
            return "Re-check after running:  pup auth login"
        case .ok, .unknown:
            return nil
        }
    }

    static func describe(_ availability: PupAvailability) -> String { availability.label }
}

/// Live status for one configured monitor query: the monitors it matched plus
/// the state of the `pup` CLI when it ran. Derived (config + poll results),
/// mirroring `HostStatus`.
struct MonitorQueryStatus: Identifiable, Equatable {
    let id: UUID
    var name: String
    var query: String
    var monitors: [MonitorStatus]
    var availability: PupAvailability
    /// How many matched monitors were dropped beyond the display cap.
    var truncatedBy: Int

    init(id: UUID, name: String, query: String, monitors: [MonitorStatus] = [],
         availability: PupAvailability = .unknown, truncatedBy: Int = 0) {
        self.id = id
        self.name = name
        self.query = query
        self.monitors = monitors
        self.availability = availability
        self.truncatedBy = truncatedBy
    }

    var alertCount: Int { monitors.filter { $0.state == .alert }.count }
    var attentionCount: Int { monitors.filter { $0.state.isAttention }.count }
    var totalCount: Int { monitors.count + truncatedBy }
    var hasAlerts: Bool { alertCount > 0 }

    /// Monitors sorted alerting-first (then warn, no-data, ok), name as tiebreak.
    var sortedForDisplay: [MonitorStatus] {
        monitors.sorted { a, b in
            if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// Live status for a host (one ServiceControl API + its endpoints).
struct HostStatus: Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoints: [EndpointStatus]
    var authState: AuthState

    var totalCount: Int { endpoints.reduce(0) { $0 + $1.totalCount } }
    var newCount: Int { endpoints.reduce(0) { $0 + $1.newCount } }
    var hasErrors: Bool { totalCount > 0 }
    var needsAuth: Bool { authState == .needsAuth }

    init(id: UUID, name: String, endpoints: [EndpointStatus], authState: AuthState = .unknown) {
        self.id = id
        self.name = name
        self.endpoints = endpoints
        self.authState = authState
    }
}

// MARK: - Azure Service Bus

/// Live dead-letter status for a single observed Service Bus queue.
struct QueueStatus: Identifiable, Equatable {
    /// The queue name doubles as a stable identity within a namespace.
    var id: String { name }
    var name: String
    var deadLetterCount: Int
    /// Deep link into the Azure Portal's Service Bus Explorer for this queue.
    var portalURL: URL?
    /// Whether the queue has duplicate detection on (resubmit must then assign
    /// a fresh MessageId, or the broker silently drops the copy).
    var duplicateDetection: Bool
    /// Set when the configured queue doesn't exist in the namespace.
    var notFound: Bool

    var hasDeadLetters: Bool { deadLetterCount > 0 }

    init(name: String, deadLetterCount: Int = 0, portalURL: URL? = nil,
         duplicateDetection: Bool = false, notFound: Bool = false) {
        self.name = name
        self.deadLetterCount = deadLetterCount
        self.portalURL = portalURL
        self.duplicateDetection = duplicateDetection
        self.notFound = notFound
    }
}

/// Whether the `az` CLI is usable for Service Bus queries.
enum AzAvailability: Equatable {
    case ok(user: String)
    case notInstalled
    case notAuthenticated
    case error(String)
    case unknown

    var isOk: Bool { if case .ok = self { return true } else { return false } }

    /// Short status label for the diagnostics box / panel banner.
    var label: String {
        switch self {
        case .ok(let user): return "Installed & signed in (\(user))"
        case .notInstalled: return "az CLI not found"
        case .notAuthenticated: return "Not signed in"
        case .error(let message): return message
        case .unknown: return "Checking…"
        }
    }

    /// A short remediation hint shown under the status, when applicable.
    var hint: String? {
        switch self {
        case .notInstalled:
            return "Install the Azure CLI:\n  brew install azure-cli"
        case .notAuthenticated:
            return "Sign in to Azure:\n  az login"
        case .error:
            return "Re-check after running:  az login"
        case .ok, .unknown:
            return nil
        }
    }
}

/// Live status for one Service Bus namespace (its queues + reachability).
/// Derived (config + poll results), mirroring `HostStatus`.
struct ServiceBusNamespaceStatus: Identifiable, Equatable {
    let id: UUID
    var name: String
    var queues: [QueueStatus]
    /// Reachability of the namespace (`.error` carries the az failure message).
    var state: AuthState
    var availability: AzAvailability

    var totalDeadLetters: Int { queues.reduce(0) { $0 + $1.deadLetterCount } }

    init(id: UUID, name: String, queues: [QueueStatus], state: AuthState = .unknown,
         availability: AzAvailability = .unknown) {
        self.id = id
        self.name = name
        self.queues = queues
        self.state = state
        self.availability = availability
    }
}
