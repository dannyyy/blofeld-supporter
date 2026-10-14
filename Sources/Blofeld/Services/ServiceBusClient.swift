import Foundation

enum ServiceBusError: Error {
    /// 401/403 — the token is missing the data-plane role (or expired).
    case forbidden(Int)
    case invalidURL
    case http(Int)
}

/// Azure Service Bus data-plane REST client, used only to resubmit
/// dead-lettered messages. Authenticated with an Entra ID token obtained from
/// the `az` CLI (`AzureCLIClient.accessToken()`); needs the "Azure Service Bus
/// Data Owner" role (or Data Receiver + Data Sender) on the namespace.
///
/// Resubmit is at-least-once: each message is peek-locked from the DLQ, sent to
/// the queue, and only then completed. If the send fails the lock is abandoned
/// so the message stays in the DLQ.
struct ServiceBusClient {
    let session: URLSession

    /// The result of a resubmit run: how many messages moved, and the error
    /// that stopped it early (nil = the DLQ was drained or the limit reached).
    struct ResubmitOutcome {
        let resubmitted: Int
        let error: Error?
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Moves up to `limit` dead-lettered messages back into `queue`.
    /// `freshMessageId` assigns a new broker MessageId to each copy — required
    /// when the queue has duplicate detection, which would otherwise silently
    /// drop a copy whose MessageId it has already seen.
    func resubmitDeadLetters(namespace: String, queue: String, token: String,
                             limit: Int, freshMessageId: Bool) async -> ResubmitOutcome {
        var done = 0
        do {
            let base = try Self.baseURL(namespace: namespace, queue: queue)
            while done < limit {
                guard let message = try await receiveDeadLetter(base: base, token: token) else { break }
                do {
                    try await send(message, base: base, token: token, freshMessageId: freshMessageId)
                } catch {
                    // Leave it in the DLQ for a later attempt.
                    _ = try? await request(message.lockURL, method: "PUT", token: token)
                    throw error
                }
                try await request(message.lockURL, method: "DELETE", token: token)
                done += 1
            }
            return ResubmitOutcome(resubmitted: done, error: nil)
        } catch {
            return ResubmitOutcome(resubmitted: done, error: error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ServiceBusError.forbidden:
            return "access denied (needs the Azure Service Bus Data Owner role)"
        case ServiceBusError.invalidURL:
            return "invalid namespace or queue name"
        case ServiceBusError.http(let code):
            return "HTTP \(code)"
        case let urlError as URLError:
            return urlError.localizedDescription
        default:
            return AzureCLIClient.describe(error)
        }
    }

    // MARK: - Receive / send

    private struct LockedMessage {
        let body: Data
        let contentType: String?
        let brokerProperties: [String: Any]
        /// Custom (application) properties, carried as HTTP headers with their
        /// raw, JSON-encoded values (strings stay quoted) — forwarded verbatim.
        let customProperties: [(String, String)]
        let lockURL: URL
    }

    /// Broker properties a client may set on send; everything else (lock
    /// token, sequence number, delivery count, dead-letter source, …) is
    /// assigned by the broker.
    private static let forwardedBrokerProperties: Set<String> = [
        "MessageId", "CorrelationId", "Label", "ReplyTo", "To",
        "SessionId", "ReplyToSessionId", "PartitionKey",
    ]

    /// Response headers that are transport, not message properties.
    private static let transportHeaders: Set<String> = [
        "content-type", "content-length", "date", "server", "location",
        "brokerproperties", "transfer-encoding", "strict-transport-security",
        "connection", "keep-alive", "vary", "cache-control", "expires", "pragma",
    ]

    /// Application properties added by the broker on dead-lettering — the
    /// resubmitted copy should not carry them.
    private static let droppedCustomProperties: Set<String> = [
        "deadletterreason", "deadlettererrordescription",
    ]

    /// Peek-locks the head of the DLQ. Returns nil when the DLQ is empty.
    private func receiveDeadLetter(base: URL, token: String) async throws -> LockedMessage? {
        guard var components = URLComponents(url: base.appendingPathComponent("$DeadLetterQueue/messages/head"),
                                             resolvingAgainstBaseURL: false) else { throw ServiceBusError.invalidURL }
        components.queryItems = [URLQueryItem(name: "timeout", value: "5")]
        guard let url = components.url else { throw ServiceBusError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.data(for: req)
        let http = try Self.check(response, accept: [201, 204])
        if http.statusCode == 204 { return nil }

        guard let location = http.value(forHTTPHeaderField: "Location"),
              let lockURL = URL(string: location) else { throw ServiceBusError.http(http.statusCode) }

        var broker: [String: Any] = [:]
        if let raw = http.value(forHTTPHeaderField: "BrokerProperties"),
           let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            broker = json
        }
        var custom: [(String, String)] = []
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let value = value as? String else { continue }
            let lower = name.lowercased()
            if Self.transportHeaders.contains(lower) || Self.droppedCustomProperties.contains(lower)
                || lower.hasPrefix("x-ms-") { continue }
            custom.append((name, value))
        }
        return LockedMessage(body: data,
                             contentType: http.value(forHTTPHeaderField: "Content-Type"),
                             brokerProperties: broker,
                             customProperties: custom,
                             lockURL: lockURL)
    }

    private func send(_ message: LockedMessage, base: URL, token: String, freshMessageId: Bool) async throws {
        var req = URLRequest(url: base.appendingPathComponent("messages"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType = message.contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        var broker = message.brokerProperties.filter { Self.forwardedBrokerProperties.contains($0.key) }
        if freshMessageId { broker["MessageId"] = UUID().uuidString }
        if !broker.isEmpty, let json = try? JSONSerialization.data(withJSONObject: broker),
           let string = String(data: json, encoding: .utf8) {
            req.setValue(string, forHTTPHeaderField: "BrokerProperties")
        }
        for (name, value) in message.customProperties {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.httpBody = message.body
        let (_, response) = try await session.data(for: req)
        _ = try Self.check(response, accept: [201])
    }

    /// Completes (DELETE) or abandons (PUT) a peek-locked message.
    @discardableResult
    private func request(_ url: URL, method: String, token: String) async throws -> HTTPURLResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.data(for: req)
        return try Self.check(response, accept: [200, 204])
    }

    // MARK: - Helpers

    private static func check(_ response: URLResponse, accept: Set<Int>) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ServiceBusError.http(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw ServiceBusError.forbidden(http.statusCode) }
        guard accept.contains(http.statusCode) else { throw ServiceBusError.http(http.statusCode) }
        return http
    }

    /// `https://<ns>.servicebus.windows.net/<queue>`. `BLOFELD_ASB_ENDPOINT`
    /// replaces the namespace host (tests point it at a local mock).
    static func baseURL(namespace: String, queue: String) throws -> URL {
        let host: String
        if let override = ProcessInfo.processInfo.environment["BLOFELD_ASB_ENDPOINT"], !override.isEmpty {
            host = override.hasSuffix("/") ? String(override.dropLast()) : override
        } else {
            let ns = namespace.trimmingCharacters(in: .whitespaces)
            guard !ns.isEmpty, ns.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw ServiceBusError.invalidURL
            }
            host = "https://\(ns).servicebus.windows.net"
        }
        guard let base = URL(string: host) else { throw ServiceBusError.invalidURL }
        return base.appendingPathComponent(queue)
    }
}
