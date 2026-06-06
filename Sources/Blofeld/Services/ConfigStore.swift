import Foundation

/// Persists `AppConfig` as JSON in Application Support so configured hosts and
/// settings survive relaunches.
///
/// Every save first copies the previous file to `config.backup.json`; `load()`
/// falls back to that backup if the main file is missing or corrupt. The
/// storage directory can be overridden with the `BLOFELD_CONFIG_DIR`
/// environment variable (used by tests so they never touch real settings).
struct ConfigStore {
    private var fileURL: URL { AppPaths.configURL }
    private var backupURL: URL { AppPaths.configBackupURL }

    func load() -> AppConfig? {
        if let config = decode(fileURL) { return config }
        // Main file missing or corrupt — recover from the last good backup.
        return decode(backupURL)
    }

    func save(_ config: AppConfig) {
        // Preserve the previous good file before overwriting it.
        if let existing = try? Data(contentsOf: fileURL) {
            try? existing.write(to: backupURL, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func decode(_ url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }
}
