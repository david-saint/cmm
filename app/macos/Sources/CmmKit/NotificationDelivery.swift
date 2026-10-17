import Foundation

/// A click on the weekly note (the board `C-Notification`): the note has no buttons, so the one thing a person can do with it is
/// click it, and that opens the window at rest. Anything else that comes back from the notification centre does nothing.
public enum NotificationClick {
    /// What the system calls a click on the note itself (`UNNotificationDefaultActionIdentifier`; a test checks the two agree).
    public static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"

    public static func opensWindow(identifier: String, action: String) -> Bool {
        identifier == WeeklyNotification.identifier && action == defaultAction
    }
}

/// What posts a note now: in the app, macOS's notification centre; in a test, a list.
public protocol NotificationPoster: Sendable {
    func post(_ note: WeeklyNotification) async
}

/// The weekly note's way out (the board `C-Notification`): it is handed to macOS only when macOS lets cmm show it. When it does
/// not (the person said no, or was never asked), nothing happens and only Settings says so. The question itself is never put
/// from here: that is the reminder switch's, once.
public struct NotificationDelivery: Sendable {
    private let permission: any NotificationPermission
    private let poster: any NotificationPoster

    public init(permission: any NotificationPermission, poster: any NotificationPoster) {
        self.permission = permission
        self.poster = poster
    }

    /// Hands the note to macOS if macOS will show it. Returns whether it did.
    @discardableResult
    public func deliver(_ note: WeeklyNotification) async -> Bool {
        guard await permission.status() == .allowed else { return false }
        await poster.post(note)
        return true
    }
}
