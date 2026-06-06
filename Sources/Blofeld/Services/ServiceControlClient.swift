import Foundation

enum ServiceControlError: Error {
    /// The request was bounced to the OAuth2 Proxy / SSO login wall.
    case needsAuth
    case invalidURL
    case http(Int)
    case decoding(Error)
}

/// Thin async wrapper over the ServiceControl HTTP API.
///
/// All requests share `HTTPCookieStorage.shared`, so the `_oauth2_proxy` cookie
/// captured by `AuthManager`'s WKWebView is sent automatically.
struct ServiceControlClient {
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    /// Unresolved errors for an endpoint.
    func errors(apiHost: String, endpoint: String) async throws -> [ErrorMessage] {
        // Pass the raw (decoded) endpoint name; URLComponents encodes it once.
        let url = try makeURL(apiHost: apiHost,
                              path: "/api/endpoints/\(endpoint)/errors/",
                              query: [URLQueryItem(name: "status", value: "unresolved")])
        return try await getJSON([ErrorMessage].self, url: url)
    }

    /// Recoverability groups grouped by "Endpoint Name" — used to resolve the
    /// ServicePulse group id for an endpoint.
    func recoverabilityGroups(apiHost: String) async throws -> [RecoverabilityGroup] {
        // Literal space -> URLComponents encodes to %20 exactly once.
        let url = try makeURL(apiHost: apiHost,
                              path: "/api/recoverability/groups/Endpoint Name",
                              query: nil)
        return try await getJSON([RecoverabilityGroup].self, url: url)
    }

    /// Requests a retry of every failed message in a recoverability group.
    /// POST `/api/recoverability/groups/<groupId>/errors/retry`.
    func retryGroup(apiHost: String, groupId: String) async throws {
        let url = try makeURL(apiHost: apiHost,
                              path: "/api/recoverability/groups/\(groupId)/errors/retry",
                              query: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceControlError.http(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw ServiceControlError.needsAuth }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") { throw ServiceControlError.needsAuth }
        guard (200..<300).contains(http.statusCode) else { throw ServiceControlError.http(http.statusCode) }
    }

    // MARK: - Helpers

    private func getJSON<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceControlError.http(-1) }

        // OAuth2 Proxy redirects unauthenticated requests to an HTML login page
        // (often still HTTP 200). Treat 401/403 or an HTML body as "needs auth".
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ServiceControlError.needsAuth
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") {
            throw ServiceControlError.needsAuth
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceControlError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A JSON endpoint returning non-JSON we couldn't flag as HTML is most
            // likely an unauthenticated proxy response.
            throw ServiceControlError.needsAuth
        }
    }

    /// Builds a URL from a base host and a raw (decoded) absolute path.
    /// URLComponents performs the single, correct percent-encoding pass.
    private func makeURL(apiHost: String, path: String, query: [URLQueryItem]?) throws -> URL {
        let base = apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost
        guard var components = URLComponents(string: base) else { throw ServiceControlError.invalidURL }
        components.path = components.path + path
        components.queryItems = query
        guard let url = components.url else { throw ServiceControlError.invalidURL }
        return url
    }
}

extension ServiceControlClient {
    /// Human-readable description for surfacing in the UI / log.
    static func describe(_ error: Error) -> String {
        switch error {
        case ServiceControlError.needsAuth:
            return "authentication required"
        case ServiceControlError.invalidURL:
            return "invalid host URL"
        case ServiceControlError.http(let code):
            return "HTTP \(code)"
        case ServiceControlError.decoding:
            return "unexpected response"
        case let urlError as URLError:
            return urlError.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    /// Builds the ServicePulse deep link for a failure group.
    static func servicePulseURL(servicePulseHost: String, groupId: String) -> URL? {
        let base = servicePulseHost.hasSuffix("/") ? String(servicePulseHost.dropLast()) : servicePulseHost
        return URL(string: "\(base)/#/failed-messages/group/\(groupId)")
    }
}
