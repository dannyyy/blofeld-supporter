import Foundation
import ServiceManagement

/// Registers/unregisters the app as a login item via the modern
/// `SMAppService` API (macOS 13+).
enum LaunchAtLogin {
    static func apply(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("[Blofeld] LaunchAtLogin \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
