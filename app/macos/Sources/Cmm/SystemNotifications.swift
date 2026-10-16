import CmmKit
import UserNotifications

// The thin adaptor between CmmKit's notification protocols and macOS's notification centre. It only passes things through; the
// rules (when to ask, when to speak, what to say) are CmmKit's, tested with fakes. No test makes one of these (a source test
// checks it), so no test can ask the person anything or show them a notification.

/// What macOS lets cmm do with notifications, and its one question about them. Only the settings model asks, and only when the
/// weekly reminder is switched on (or the one-time card's Turn on): never at launch, never to deliver.
struct SystemNotificationPermission: NotificationPermission {
    func status() async -> NotificationAuthorization {
        guard SystemBundle.isApp else { return .notAsked }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.authorization(settings.authorizationStatus)
    }

    /// Banners only: no sound and no badge, which the board's quiet weekly note does not need.
    func request() async -> NotificationAuthorization {
        guard SystemBundle.isApp else { return .notAsked }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        return await status()
    }

    static func authorization(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notAsked
        case .authorized, .provisional: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }
}
