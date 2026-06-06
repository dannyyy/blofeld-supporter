import Foundation

/// Persisted application configuration. Encoded as JSON in Application Support.
struct AppConfig: Codable, Equatable {
    /// NServiceBus / ServiceControl hosts to observe.
    var hosts: [HostConfig]
    /// Datadog monitor search queries to observe (via the `pup` CLI).
    var datadogQueries: [MonitorQueryConfig]
    /// The Datadog site `pup` should use (e.g. "datadoghq.eu"). Empty = auto-detect.
    /// A LaunchServices-launched app has no `DD_SITE` in its environment, so the
    /// app sets it explicitly per `pup` call rather than relying on the shell.
    var datadogSite: String
    var pollSeconds: Int
    var notificationsEnabled: Bool
    var launchAtLogin: Bool

    static let `default` = AppConfig(
        hosts: [],
        datadogQueries: [],
        datadogSite: "",
        pollSeconds: 60,
        notificationsEnabled: true,
        launchAtLogin: false
    )

    init(
        hosts: [HostConfig],
        datadogQueries: [MonitorQueryConfig] = [],
        datadogSite: String = "",
        pollSeconds: Int,
        notificationsEnabled: Bool,
        launchAtLogin: Bool
    ) {
        self.hosts = hosts
        self.datadogQueries = datadogQueries
        self.datadogSite = datadogSite
        self.pollSeconds = pollSeconds
        self.notificationsEnabled = notificationsEnabled
        self.launchAtLogin = launchAtLogin
    }

    // Custom decode so configs written before Datadog support (no
    // `datadogQueries` / `datadogSite` keys) still load instead of failing the
    // whole decode — which would drop the user back to `.default` and lose
    // their hosts. Add any future field the same way.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decode([HostConfig].self, forKey: .hosts)
        datadogQueries = try c.decodeIfPresent([MonitorQueryConfig].self, forKey: .datadogQueries) ?? []
        datadogSite = try c.decodeIfPresent(String.self, forKey: .datadogSite) ?? ""
        pollSeconds = try c.decode(Int.self, forKey: .pollSeconds)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
    }
}

/// The Datadog sites `pup` can authenticate against (probed during auto-detect).
/// Values are `DD_SITE` strings; see https://docs.datadoghq.com/getting_started/site/
enum DatadogSite {
    static let known: [String] = [
        "datadoghq.com",       // US1
        "us3.datadoghq.com",   // US3
        "us5.datadoghq.com",   // US5
        "datadoghq.eu",        // EU1
        "ap1.datadoghq.com",   // AP1
        "ddog-gov.com",        // US1-FED
    ]

    /// Friendly label for a site value, for the Settings picker.
    static func label(for site: String) -> String {
        switch site {
        case "datadoghq.com": return "US1 (datadoghq.com)"
        case "us3.datadoghq.com": return "US3 (us3.datadoghq.com)"
        case "us5.datadoghq.com": return "US5 (us5.datadoghq.com)"
        case "datadoghq.eu": return "EU1 (datadoghq.eu)"
        case "ap1.datadoghq.com": return "AP1 (ap1.datadoghq.com)"
        case "ddog-gov.com": return "US1-FED (ddog-gov.com)"
        default: return site
        }
    }
}

/// One observed message broker: a ServiceControl API host plus the matching
/// ServicePulse host, and the endpoints to watch on it.
struct HostConfig: Codable, Equatable, Identifiable {
    var id: UUID
    /// Friendly label shown in the UI (e.g. "Production", "Staging").
    var name: String
    /// Base URL of the ServiceControl API, e.g. https://servicecontrol.example.com
    var apiHost: String
    /// Base URL of ServicePulse, e.g. https://servicepulse.example.com
    var servicePulseHost: String
    /// Endpoint names to observe (e.g. "order-processor").
    var endpoints: [EndpointConfig]

    init(
        id: UUID = UUID(),
        name: String,
        apiHost: String,
        servicePulseHost: String,
        endpoints: [EndpointConfig]
    ) {
        self.id = id
        self.name = name
        self.apiHost = apiHost
        self.servicePulseHost = servicePulseHost
        self.endpoints = endpoints
    }
}

/// A single endpoint name to observe. Identifiable so the editor can add/remove
/// rows safely without index-based bindings.
struct EndpointConfig: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// One Datadog monitor search query to observe. Every monitor the query matches
/// is shown in the panel (via `pup monitors search --query <query>`).
/// Identifiable so the editor can add/remove rows without index-based bindings.
struct MonitorQueryConfig: Codable, Equatable, Identifiable {
    var id: UUID
    /// Friendly label shown in the panel (e.g. "Error queues", "Checkout SLOs").
    var name: String
    /// The Datadog monitor search query, e.g. "team:blofeld status:alert".
    var query: String

    init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// The allowed global polling intervals, on a *progressive* scale: the step
/// size grows with the value, so a slider over these options gives fine 15 s
/// control near the bottom and coarse 15 min control near the top.
/// Range: 30 s … 1 h.
enum PollInterval {
    static let options: [Int] = {
        var values: [Int] = []
        func fill(from: Int, through: Int, step: Int) {
            var v = from
            while v <= through { values.append(v); v += step }
        }
        fill(from: 30,   through: 120,  step: 15)   // 30 s – 2 m,  15 s steps
        fill(from: 150,  through: 300,  step: 30)   // 2.5 m – 5 m, 30 s steps
        fill(from: 360,  through: 600,  step: 60)   // 6 m – 10 m,  1 m steps
        fill(from: 900,  through: 1800, step: 300)  // 15 m – 30 m, 5 m steps
        fill(from: 2700, through: 3600, step: 900)  // 45 m – 1 h,  15 m steps
        return values
    }()

    /// Compact label, e.g. "30s", "1m 30s", "5m", "1h".
    static func label(for seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes < 60 {
            return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
        }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }

    /// Snaps an arbitrary value to the nearest allowed option.
    static func nearest(to seconds: Int) -> Int {
        options.min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? 60
    }

    /// Position of the option nearest to `seconds` (for the slider binding).
    static func index(of seconds: Int) -> Int {
        options.firstIndex(of: nearest(to: seconds)) ?? 0
    }
}
