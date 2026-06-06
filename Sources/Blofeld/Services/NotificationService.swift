import Foundation
import UserNotifications

/// Emits local notifications when an endpoint's error count increases.
///
/// Also publishes the current authorization status so the Settings "Debugging"
/// section can show whether notification registration is valid and fire a test
/// notification on demand.
@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Live system authorization status (refreshed on `start`, `refreshStatus`
    /// and after each authorization request).
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Last error reported by the notification center, if any.
    @Published private(set) var lastError: String?

    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                self?.lastError = error?.localizedDescription
                self?.refreshStatus()
            }
        }
    }

    /// Re-query the current authorization status from the system.
    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    /// Ask the system for authorization again (e.g. from the Debugging panel).
    /// Only prompts while undetermined; once denied the user must use System
    /// Settings, so we just refresh the status.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                self?.lastError = error?.localizedDescription
                self?.refreshStatus()
            }
        }
    }

    func notifyIncrease(endpoint: String, host: String, delta: Int, total: Int) {
        let content = UNMutableNotificationContent()
        content.title = "New errors in \(endpoint)"
        let plural = delta == 1 ? "" : "s"
        content.body = "+\(delta) new error\(plural) (\(total) unresolved) on \(host)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Emit a one-off test notification and report success/failure via the log
    /// and `lastError`. Re-checks status afterwards so the panel stays current.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Blofeld test notification"
        content.body = "If you can see this banner, notifications are working."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.lastError = error.localizedDescription
                    EventLog.shared.log(.error, "Test notification failed: \(error.localizedDescription)")
                } else {
                    self?.lastError = nil
                    EventLog.shared.log(.info, "Test notification sent")
                }
                self?.refreshStatus()
            }
        }
    }

    // Show banners even though the app is an accessory (menu-bar) app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension UNAuthorizationStatus {
    /// Human-readable label for the Debugging panel.
    var label: String {
        switch self {
        case .notDetermined: return "Not requested yet"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    /// Whether notifications can currently be delivered.
    var isValid: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        @unknown default: return false
        }
    }
}
