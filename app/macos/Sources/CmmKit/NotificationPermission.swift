import Foundation

/// What macOS lets cmm do with notifications.
public enum NotificationAuthorization: Equatable, Sendable {
    /// macOS has not been asked yet, so it would show its own question.
    case notAsked
    case allowed
    /// The person said no, or turned notifications off for cmm in System Settings.
    case denied
}

/// The system's question about notifications (in the app this is `UNUserNotificationCenter`, which is the second phase's).
/// Only the settings model asks, and only when the weekly reminder is turned on: never at launch, never to deliver one.
public protocol NotificationPermission: Sendable {
    func status() async -> NotificationAuthorization
    /// Asks macOS, which shows its own question the first time and says what the person chose.
    func request() async -> NotificationAuthorization
}
