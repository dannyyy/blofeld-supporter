import Foundation
import AppKit

enum LogLevel: String {
    case info = "INFO"
    case success = "OK"
    case error = "ERROR"
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
}

/// Records app events both to an in-memory ring buffer (shown in the Activity
/// popover) and to a rolling log file (`blofeld.log`), so failures are never
/// silent.
@MainActor
final class EventLog: ObservableObject {
    static let shared = EventLog()

    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 300
    private let fileURL = AppPaths.logURL
    private lazy var formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToFile(entry)
    }

    func clear() {
        entries.removeAll()
        try? "".data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    var logFileURL: URL { fileURL }

    /// Opens the log file in the default text editor, creating it first if it
    /// does not exist yet (so the button never just focuses an empty Finder).
    func openLogFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "".data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
        NSWorkspace.shared.open(fileURL)
    }

    private func appendToFile(_ entry: LogEntry) {
        let line = "\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
