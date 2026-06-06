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
