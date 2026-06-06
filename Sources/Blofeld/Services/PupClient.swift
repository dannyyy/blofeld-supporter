import Foundation

enum PupError: Error {
    case notInstalled
    case notAuthenticated
    case timedOut
    case failed(String)
    case decoding(Error)
}

/// Thin async wrapper over the Datadog `pup` CLI — the app's only subprocess.
///
/// All invocations are forced into `--no-agent --read-only --output json`:
///  - `--no-agent` pins the JSON shape (pup's *agent* mode wraps results under a
///    `data` envelope; *no-agent* puts `monitors` at the top level — see the
///    decoded DTOs below). The app must be deterministic regardless of how pup
///    auto-detects its runtime.
///  - `--read-only` guarantees pup can never perform a write, even if the args
///    were ever wrong — the app only ever searches and opens links.
///
/// A LaunchServices-launched `.app` has a minimal PATH and does *not* read
/// `~/.zshrc`, so the binary is resolved by absolute path. pup persists its own
/// site/credentials, so no `DD_SITE` is required at runtime.
struct PupClient {

    /// Resolves the `pup` binary. `BLOFELD_PUP_PATH` overrides for tests.
    static func resolvePath() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BLOFELD_PUP_PATH"],
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = ["/opt/homebrew/bin/pup", "/usr/local/bin/pup", "/usr/bin/pup"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    var pupPath: String? { Self.resolvePath() }

    // MARK: - High level

    /// Whether pup is installed and authenticated; returns the authenticated
    /// site on success. `sitesToTry` lists the `DD_SITE` values to probe in order
    /// (the app has no ambient `DD_SITE`, and pup stores credentials per-site, so
    /// we must say which site to check). The first authenticated site wins. Pass
    /// a single explicit site to respect a user override, or the known-site list
    /// to auto-detect. An empty string probes pup's default site.
    func availability(sitesToTry: [String]) async -> PupAvailability {
        guard let path = pupPath else { return .notInstalled }
        let sites = sitesToTry.isEmpty ? [""] : sitesToTry
        var lastError: String?
        for site in sites {
            do {
                let result = try await run(path: path, args: ["auth", "status"], site: site)
                if let status = try? JSONDecoder().decode(PupAuthStatus.self, from: result.stdout),
                   status.authenticated, let resolved = status.site, !resolved.isEmpty {
                    return .ok(site: resolved)
                }
                // authenticated == false for this site — try the next one.
            } catch PupError.timedOut {
                return .error("pup timed out")
            } catch {
                lastError = PupClient.describe(error)
            }
        }
        return lastError.map { .error($0) } ?? .notAuthenticated
    }

    /// The mapped monitors on the fetched page plus the *total* number the query
    /// matched (from the response `counts`), so callers can report "+N more".
    struct MonitorSearchResult { let monitors: [MonitorStatus]; let totalMatched: Int }

    /// Runs `pup monitors search` and maps the matched monitors. `site` builds the
    /// per-monitor browser deep links.
    func searchMonitors(query: String, site: String?, perPage: Int) async throws -> MonitorSearchResult {
        guard let path = pupPath else { throw PupError.notInstalled }
        let result = try await run(path: path,
            args: ["monitors", "search", "--query", query, "--per-page", String(perPage)],
            site: site)
        guard result.code == 0 else {
            let lower = result.stderr.lowercased()
            if lower.contains("401") || lower.contains("403") || lower.contains("unauthor") || lower.contains("authenticat") {
                throw PupError.notAuthenticated
            }
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PupError.failed(detail.isEmpty ? "pup exited \(result.code)" : detail)
        }
        let response: PupSearchResponse
        do {
            response = try JSONDecoder().decode(PupSearchResponse.self, from: result.stdout)
        } catch {
            throw PupError.decoding(error)
        }
        let monitors = response.monitors.map { m in
            MonitorStatus(
                id: m.id,
                name: m.name,
                state: MonitorState(apiStatus: m.status),
                priority: m.priority,
                tags: m.tags ?? [],
                url: PupClient.monitorURL(site: site, id: m.id))
        }
        // `counts.status` totals the whole match (not just this page); fall back
        // to the page size when absent.
        let total = response.counts?.status?.reduce(0) { $0 + $1.count } ?? monitors.count
        return MonitorSearchResult(monitors: monitors, totalMatched: max(total, monitors.count))
    }

    /// The Datadog browser deep link for a monitor, e.g.
    /// `https://app.datadoghq.eu/monitors/12345`.
    static func monitorURL(site: String?, id: Int) -> URL? {
        guard let site, !site.isEmpty else { return nil }
        return URL(string: "https://app.\(site)/monitors/\(id)")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case PupError.notInstalled: return "pup CLI not found"
        case PupError.notAuthenticated: return "not authenticated"
        case PupError.timedOut: return "pup timed out"
        case PupError.failed(let message): return message
        case PupError.decoding: return "unexpected pup output"
        default: return error.localizedDescription
        }
    }

    // MARK: - Process runner

    private struct RunResult { let code: Int32; let stdout: Data; let stderr: String }

    private func run(path: String, args: [String], site: String? = nil, timeout: TimeInterval = 25) async throws -> RunResult {
        let fullArgs = args + ["--no-agent", "--read-only", "--output", "json"]
        // A LaunchServices-launched app inherits the launchd environment, which
        // has no DD_SITE — so set it explicitly here (pup picks the credentials
        // for that site). An empty/nil site leaves pup on its default site.
        var environment = ProcessInfo.processInfo.environment
        if let site, !site.isEmpty { environment["DD_SITE"] = site }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = fullArgs
                process.environment = environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: PupError.failed("could not launch pup: \(error.localizedDescription)"))
                    return
                }

                // Watchdog: terminate a hung process so a slow query can't wedge
                // polling. `didTimeout` is read on this worker thread and written
                // on the watchdog thread, so it's guarded by a serial queue.
                let flagQ = DispatchQueue(label: "com.danflash.blofeld.pup.timeout")
                var didTimeout = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        flagQ.sync { didTimeout = true }
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // pup's stderr is tiny (a refresh notice or a short error), so a
                // sequential drain after the large stdout won't fill its 64K pipe.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if flagQ.sync(execute: { didTimeout }) {
                    continuation.resume(throwing: PupError.timedOut)
                    return
                }
                let errString = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: RunResult(code: process.terminationStatus, stdout: outData, stderr: errString))
            }
        }
    }
}

// MARK: - Decoded pup payloads (no-agent shape)

/// `pup auth status --output json` — identical in agent and no-agent modes.
private struct PupAuthStatus: Decodable {
    let authenticated: Bool
    let site: String?
}

/// `pup monitors search --no-agent` returns `monitors` at the top level.
/// (Agent mode would nest it under `data`; we always pass `--no-agent`.)
private struct PupSearchResponse: Decodable {
    let monitors: [PupMonitor]
    let counts: PupCounts?
}

private struct PupMonitor: Decodable {
    let id: Int
    let name: String
    let status: String
    let priority: Int?
    let tags: [String]?
}

/// Aggregate counts across the whole query match. We only need the per-status
/// counts to compute the true total (each entry's `name` is irrelevant here).
private struct PupCounts: Decodable {
    let status: [PupCount]?
}

private struct PupCount: Decodable {
    let count: Int
}
