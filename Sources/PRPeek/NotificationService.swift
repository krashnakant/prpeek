import AppKit
import UserNotifications
import PRPeekCore

/// Delivers NotificationEvents with interactive notification actions (Open, Copy URL, Snooze).
/// First-run permission request; if denied, every deliver() is a no-op (degrades to the in-app badge).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let categoryID = "PR_ALERT_CATEGORY"
    private static let actionOpenID = "ACTION_OPEN"
    private static let actionCopyID = "ACTION_COPY_URL"
    private static let actionSnoozeID = "ACTION_SNOOZE_1H"

    private var authorized = false
    private var requested = false

    /// Called with a URL when the user clicks the notification or selects "Open in Browser".
    var onOpen: (@MainActor (URL) -> Void)?
    /// Called with a PR key when the user selects "Snooze (1 hour)".
    var onSnoozePRKey: (@MainActor (String) -> Void)?

    /// UNUserNotificationCenter aborts (NSException) when the process has no app
    /// bundle id — i.e. a bare `swift run` binary. Degrade to in-app badge then,
    /// which is the same path as "permission denied". Run the packaged .app
    /// (Scripts/make-app.sh) to get real notifications.
    private var notificationsSupported: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorizationIfNeeded() {
        guard notificationsSupported else {
            AppLog.notifications.info("Notifications unsupported without app bundle identifier")
            return
        }
        guard !requested else { return }
        requested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                AppLog.notifications.info("Notification authorization resolved granted=\(granted, privacy: .public)")
            }
        }
    }

    private func registerCategories() {
        let openAction = UNNotificationAction(identifier: Self.actionOpenID, title: "Open in Browser", options: .foreground)
        let copyAction = UNNotificationAction(identifier: Self.actionCopyID, title: "Copy URL", options: [])
        let snoozeAction = UNNotificationAction(identifier: Self.actionSnoozeID, title: "Snooze (1h)", options: [])

        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [openAction, copyAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func deliver(_ events: [NotificationEvent]) {
        guard notificationsSupported, authorized, !events.isEmpty else { return } // denied/no-bundle -> silent degrade
        AppLog.notifications.debug("Delivering notifications count=\(events.count, privacy: .public)")
        let center = UNUserNotificationCenter.current()
        for e in events {
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body = e.body
            content.userInfo = ["url": e.url.absoluteString, "prKey": e.prKey]
            content.categoryIdentifier = Self.categoryID
            let req = UNNotificationRequest(identifier: e.id, content: content, trigger: nil)
            center.add(req)
        }
    }

    // Interactive notification actions handler.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let s = userInfo["url"] as? String,
              let url = URL(string: s) else { return }
        let prKey = userInfo["prKey"] as? String ?? ""
        let actionID = response.actionIdentifier

        await MainActor.run {
            switch actionID {
            case Self.actionCopyID:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                AppLog.notifications.info("Copied PR URL from notification action")
            case Self.actionSnoozeID:
                AppLog.notifications.info("Snooze 1h from notification action")
                self.onSnoozePRKey?(prKey)
            default:
                // Tap on notification body or actionOpenID
                AppLog.notifications.info("Notification opened")
                self.onOpen?(url)
            }
        }
    }

    // Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
