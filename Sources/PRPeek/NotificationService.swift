import AppKit
import UserNotifications
import PRPeekCore

/// Delivers NotificationEvents. First-run permission request; if denied, every
/// deliver() is a no-op (degrade to the in-app badge — the app stays useful).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    private var requested = false
    /// Called with a URL when the user clicks a notification.
    var onOpen: (@MainActor (URL) -> Void)?

    /// UNUserNotificationCenter aborts (NSException) when the process has no app
    /// bundle id — i.e. a bare `swift run` binary. Degrade to in-app badge then,
    /// which is the same path as "permission denied". Run the packaged .app
    /// (Scripts/make-app.sh) to get real notifications.
    private var notificationsSupported: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorizationIfNeeded() {
        guard notificationsSupported else {
            AppTelemetry.notifications.info("Notifications unsupported without app bundle identifier")
            return
        }
        guard !requested else { return }
        requested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                AppTelemetry.notifications.info("Notification authorization resolved granted=\(granted, privacy: .public)")
            }
        }
    }

    func deliver(_ events: [NotificationEvent]) {
        guard notificationsSupported, authorized, !events.isEmpty else { return } // denied/no-bundle -> silent degrade
        AppTelemetry.notifications.info("Delivering notifications count=\(events.count, privacy: .public)")
        let center = UNUserNotificationCenter.current()
        for e in events {
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body = e.body
            content.userInfo = ["url": e.url.absoluteString]
            let req = UNNotificationRequest(identifier: e.id, content: content, trigger: nil)
            center.add(req)
        }
    }

    // Click -> open the PR. nonisolated: the delegate requirement isn't
    // main-actor; extract the Sendable url string, then hop to main.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: s) else { return }
        await MainActor.run {
            AppTelemetry.notifications.info("Notification opened")
            self.onOpen?(url)
        }
    }

    // Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
