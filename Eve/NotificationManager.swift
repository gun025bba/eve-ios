import Foundation
import UIKit
import UserNotifications

/// Auxiliary local notifications (bridge `notify_schedule` / `notify_cancel`). NOT a push replacement:
/// there is no APNs on a free Apple ID, so the web can only ask the OS to show a generic reminder after a delay.
/// Security: the notification text is fixed in the shell. The web never supplies title/body, so message
/// content can never reach the lock screen. Authorization is requested lazily, and only while the app is active.
/// Validation is in `NotifyValidation`, the atomic limit/closed logic in `NotificationScheduler` (both unit-tested).
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // Fixed, generic text (no conversation content).
    static let title = "Eve"
    static let body = "응답이 준비되었을 수 있어요. 앱을 열어 확인하세요."

    private let scheduler = NotificationScheduler(
        center: SystemNotificationCenter(),
        isAppActive: { await MainActor.run { UIApplication.shared.applicationState == .active } })

    /// Call once at launch so foreground presentation is controlled by the shell.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func schedule(id: String, afterSec: Int) async -> NotifyFailure? { await scheduler.schedule(id: id, afterSec: afterSec) }
    func cancel(id: String) async { await scheduler.cancel(id: id) }

    /// Unpair step 1 (before the wipe): close the scheduler and cancel everything.
    func closeForUnpair() async { await scheduler.closeAndCancelAll() }
    /// Unpair step 2 (after wipe + reload): cancel once more; the next pairing's `hello` reopens.
    func finishUnpair() async { await scheduler.finishUnpair() }
    /// Bridge `hello` of a (new) document.
    func pairingHello() async { await scheduler.pairingHello() }

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

/// The real center behind the `NotificationCentering` seam.
struct SystemNotificationCenter: NotificationCentering {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> NotifyAuthStatus {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(identifier: String, afterSec: Int) async throws {
        let content = UNMutableNotificationContent()
        content.title = NotificationManager.title
        content.body = NotificationManager.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(afterSec), repeats: false)
        // Same identifier replaces a pending request, so re-scheduling an id is idempotent.
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    func pending() async -> [PendingNotification] {
        await center.pendingNotificationRequests().map {
            PendingNotification(identifier: $0.identifier,
                                fireDate: ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate())
        }
    }

    func removePending(_ identifiers: [String]) async { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) async { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    func removeAllDelivered() async { center.removeAllDeliveredNotifications() }
}
