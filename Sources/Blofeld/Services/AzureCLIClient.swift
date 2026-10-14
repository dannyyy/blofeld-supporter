import Foundation

enum AzError: Error {
    case notInstalled
    case notAuthenticated
    case timedOut
    case failed(String)
    case decoding(Error)
}

/// Thin async wrapper over the Azure `az` CLI, reusing the user's `az login`.
///
/// Read-only by construction: `az` has no `--read-only` switch, so this type
/// only ever invokes three read commands — `account show`,
/// `servicebus queue list` and `account get-access-token`. The token is used by
/// `ServiceBusClient` for the data-plane resubmit; Blofeld stores no secrets.
///
/// A LaunchServices-launched `.app` has a minimal PATH and does *not* read
/// `~/.zshrc`, so the binary is resolved by absolute path and PATH is augmented
/// (the `az` launcher is a shell script that execs Homebrew's Python).
actor AzureCLIClient {
    /// The Entra ID resource for the Service Bus data plane.
    static let serviceBusResource = "https://servicebus.azure.net"

    private var cachedToken: (value: String, expiresOn: Date)?

    /// Resolves the `az` binary. `BLOFELD_AZ_PATH` overrides for tests.
    static func resolvePath() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BLOFELD_AZ_PATH"],
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = ["/opt/homebrew/bin/az", "/usr/local/bin/az", "/usr/bin/az"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - High level

    /// Whether az is installed and signed in; returns the signed-in user.
    func availability() async -> AzAvailability {
        do {
            let result = try await run(["account", "show"])
            let account = try JSONDecoder().decode(AzAccount.self, from: result)
            return .ok(user: account.user?.name ?? account.name ?? "signed in")
        } catch AzError.notInstalled {
            return .notInstalled
        } catch AzError.notAuthenticated {
            return .notAuthenticated
        } catch {
            return .error(Self.describe(error))
        }
    }

    /// One queue as reported by `az servicebus queue list`.
    struct QueueInfo: Equatable {
        let name: String
        let resourceId: String
        let deadLetterCount: Int
        let duplicateDetection: Bool
    }

    /// All queues of a namespace with their counts — one subprocess per
    /// namespace (az's Python startup is ~1 s, so never one per queue).
    func queues(subscription: String, resourceGroup: String, namespace: String) async throws -> [QueueInfo] {
        var args = ["servicebus", "queue", "list",
                    "--resource-group", resourceGroup, "--namespace-name", namespace]
        if !subscription.isEmpty { args += ["--subscription", subscription] }
        let data = try await run(args)
        let queues: [AzQueue]
        do {
            queues = try JSONDecoder().decode([AzQueue].self, from: data)
        } catch {
            throw AzError.decoding(error)
        }
        return queues.map {
            QueueInfo(name: $0.name,
                      resourceId: $0.id,
                      deadLetterCount: $0.countDetails?.deadLetterMessageCount ?? 0,
                      duplicateDetection: $0.requiresDuplicateDetection ?? false)
        }
    }

    /// An Entra ID access token for the Service Bus data plane, cached until
    /// shortly before it expires.
    func accessToken() async throws -> String {
        if let cachedToken, cachedToken.expiresOn.timeIntervalSinceNow > 120 {
            return cachedToken.value
        }
        let data = try await run(["account", "get-access-token", "--resource", Self.serviceBusResource])
        let token: AzToken
        do {
            token = try JSONDecoder().decode(AzToken.self, from: data)
        } catch {
            throw AzError.decoding(error)
        }
        // Without an expiry, assume a conservative 5-minute lifetime.
        let expiresOn = token.expiresOn.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(300)
        cachedToken = (token.accessToken, expiresOn)
        return token.accessToken
    }

    /// Drops the cached token (e.g. after the data plane rejected it).
    func invalidateToken() {
        cachedToken = nil
    }

    /// The Azure Portal deep link to the queue's Service Bus Explorer.
    static func portalURL(resourceId: String) -> URL? {
        guard !resourceId.isEmpty else { return nil }
        return URL(string: "https://portal.azure.com/#resource\(resourceId)/explorer")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case AzError.notInstalled: return "az CLI not found"
        case AzError.notAuthenticated: return "not signed in (run az login)"
        case AzError.timedOut: return "az timed out"
        case AzError.failed(let message): return message
        case AzError.decoding: return "unexpected az output"
        default: return error.localizedDescription
        }
    }

    // MARK: - Process runner

    private func run(_ args: [String], timeout: TimeInterval = 45) async throws -> Data {
        guard let path = Self.resolvePath() else { throw AzError.notInstalled }
        var environment = ProcessInfo.processInfo.environment
        let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], basePath].compactMap { $0 }.joined(separator: ":")
        environment["AZURE_CORE_COLLECT_TELEMETRY"] = "no"
        environment["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true"
        environment["AZURE_CORE_NO_COLOR"] = "true"

        let result: CLIRunner.Result
        do {
            result = try await CLIRunner.run(path: path, args: args + ["--only-show-errors", "--output", "json"],
                                             environment: environment, timeout: timeout)
        } catch CLIRunner.Failure.timedOut {
            throw AzError.timedOut
        } catch CLIRunner.Failure.launch(let message) {
            throw AzError.failed("could not launch az: \(message)")
        }
        guard result.code == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = detail.lowercased()
            if lower.contains("az login") || lower.contains("aadsts") || lower.contains("refresh token")
                || lower.contains("interactive authentication") {
                throw AzError.notAuthenticated
            }
            // az prefixes errors with "ERROR: " — keep only the first line.
            let firstLine = detail.split(separator: "\n").first.map(String.init) ?? ""
            let message = firstLine.hasPrefix("ERROR: ") ? String(firstLine.dropFirst(7)) : firstLine
            throw AzError.failed(message.isEmpty ? "az exited \(result.code)" : message)
        }
        return result.stdout
    }
}

// MARK: - Decoded az payloads

private struct AzAccount: Decodable {
    struct User: Decodable { let name: String? }
    let name: String?
    let user: User?
}

private struct AzQueue: Decodable {
    struct CountDetails: Decodable { let deadLetterMessageCount: Int? }
    let name: String
    let id: String
    let requiresDuplicateDetection: Bool?
    let countDetails: CountDetails?
}

/// `az account get-access-token`. `expires_on` is a POSIX timestamp — an Int in
/// current az versions, a String in older ones, so both are accepted.
private struct AzToken: Decodable {
    let accessToken: String
    let expiresOn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresOn = "expires_on"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        if let number = try? c.decode(Double.self, forKey: .expiresOn) {
            expiresOn = number
        } else if let string = try? c.decode(String.self, forKey: .expiresOn) {
            expiresOn = Double(string)
        } else {
            expiresOn = nil
        }
    }
}
