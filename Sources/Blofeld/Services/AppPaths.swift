import Foundation

/// Resolves the app's storage directory. Honors the `BLOFELD_CONFIG_DIR`
/// override (used by tests so they never touch real settings).
enum AppPaths {
    static var baseDirectory: URL {
        let fm = FileManager.default
        let base: URL
        if let override = ProcessInfo.processInfo.environment["BLOFELD_CONFIG_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            base = support.appendingPathComponent("com.danflash.blofeld-supporter", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var configURL: URL { baseDirectory.appendingPathComponent("config.json") }
    static var configBackupURL: URL { baseDirectory.appendingPathComponent("config.backup.json") }
    static var logURL: URL { baseDirectory.appendingPathComponent("blofeld.log") }
}
