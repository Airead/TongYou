import AppKit
import UserNotifications

/// Posts macOS system notifications when a pane sends an OSC 9/777/1337
/// sequence and the pane is not currently visible (wrong window or tab).
///
/// Clicking the notification broadcasts a `focusPaneFromNotification`
/// notification so the owning window can bring the pane to the foreground.
@MainActor
final class SystemNotificationService: NSObject {
    static let shared = SystemNotificationService()

    /// NotificationCenter name used when a system notification is clicked.
    static let focusPaneNotification = Notification.Name(
        "io.github.airead.tongyou.focusPaneFromNotification"
    )

    private var hasRequestedAuthorization = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                GUILog.error("Notification authorization failed: \(error)", category: .session)
            } else if !granted {
                GUILog.debug("Notification authorization denied", category: .session)
            }
        }
    }

    // MARK: - Post

    /// Send a system notification for a pane. Replaces any previous
    /// notification for the same pane (same identifier).
    func send(paneID: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["paneID": paneID.uuidString]

        let request = UNNotificationRequest(
            identifier: paneID.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                GUILog.error("Failed to post notification: \(error)", category: .session)
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension SystemNotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard let paneIDString = userInfo["paneID"] as? String,
              let paneID = UUID(uuidString: paneIDString) else { return }

        NotificationCenter.default.post(
            name: Self.focusPaneNotification,
            object: nil,
            userInfo: ["paneID": paneID]
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the notification even when the app is in the foreground.
        completionHandler([.banner, .sound])
    }
}
