import Foundation
import UserNotifications

/// Auxiliary local notifications (bridge `notify_schedule` / `notify_cancel`). NOT a push replacement:
/// there is no APNs on a free Apple ID, so the web can only ask the OS to show a generic reminder after a delay.
/// Security: the notification text is fixed in the shell. The web never supplies title/body, so message
/// content can never reach the lock screen. Authorization is requested lazily on the first schedule call.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let idPrefix = "eve.notify."
    static let minAfterSec = 5
    static let maxAfterSec = 3600
    static let maxPending = 8
    // Fixed, generic text (no conversation content).
    static let title = "Eve"
    static let body = "응답이 준비되었을 수 있어요. 앱을 열어 확인하세요."

    enum Failure: String, Error {
        case invalidArgument = "invalid_argument"
        case permissionDenied = "permission_denied"
        case limitReached = "limit_reached"
        case failed = "notify_failed"
    }

    /// Call once at launch so foreground presentation is controlled by the shell.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Validation (pure)

    /// `id`: 1-64 chars of [A-Za-z0-9_-]. `afterSec`: finite number within the allowed range.
    static func parseSchedule(_ payload: [String: Any]) -> Result<(id: String, afterSec: Int), Failure> {
        guard let id = parseID(payload) else { return .failure(.invalidArgument) }
        guard let n = payload["afterSec"] as? Double, n.isFinite,
              n >= Double(minAfterSec), n <= Double(maxAfterSec) else { return .failure(.invalidArgument) }
        return .success((id, Int(n.rounded())))
    }

    private static let idChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func parseID(_ payload: [String: Any]) -> String? {
        guard let id = payload["id"] as? String, (1...64).contains(id.count),
              id.unicodeScalars.allSatisfy({ idChars.contains($0) })
        else { return nil }
        return id
    }

    // MARK: Actions

    func schedule(id: String, afterSec: Int) async -> Failure? {
        let center = UNUserNotificationCenter.current()

        // Lazy authorization: prompt only on first use.
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return .permissionDenied
        }

        let identifier = Self.idPrefix + id
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.idPrefix) }
        if pending.count >= Self.maxPending, !pending.contains(where: { $0.identifier == identifier }) {
            return .limitReached
        }

        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = Self.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(afterSec), repeats: false)
        // Same identifier replaces a pending request, so re-scheduling an id is idempotent.
        do { try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) }
        catch { return .failed }
        return nil
    }

    /// Idempotent: removes the pending and the already delivered notification for `id`.
    func cancel(id: String) {
        let center = UNUserNotificationCenter.current()
        let identifier = Self.idPrefix + id
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Unpair / sign-out: nothing from this session should stay scheduled.
    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeAllDeliveredNotifications()
    }

    /// App came to the foreground: the user is looking at the answer, drop already delivered reminders.
    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    /// If the app is in the foreground the user is already looking at Eve: do not show a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
