import Foundation

/// What the Settings window says (the board `C-Settings`): exactly four switches, one sentence each, and the two places in System
/// Settings where macOS lets the person undo what cmm asked for. A sentence that names a place in System Settings carries it as a
/// link, which the window draws in the ink's own colour and makes clickable.
public enum SettingsCopy {
    /// A line of small print, with at most one link in it.
    public struct Line: Equatable, Sendable {
        public let before: String
        public let link: String?
        public let after: String
        public let destination: Destination?

        public var text: String { before + (link ?? "") + after }

        init(_ before: String, link: String? = nil, to destination: Destination? = nil, _ after: String = "") {
            self.before = before
            self.link = link
            self.after = after
            self.destination = destination
        }
    }

    /// Where a link goes: the two places macOS keeps what cmm asked for.
    public enum Destination: String, Equatable, Sendable {
        /// System Settings > General > Login Items (the app opens it with `SMAppService`).
        case loginItems
        /// System Settings > Notifications.
        case notifications

        /// The address the window's link carries. The Notifications pane is the system's own address; Login Items is opened by
        /// the system's own call, so its link carries a name that only the window answers.
        public var url: URL {
            switch self {
            case .loginItems: URL(string: "cmm-settings://login-items")!
            case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            }
        }

        public init?(url: URL) {
            switch url {
            case Destination.loginItems.url: self = .loginItems
            case Destination.notifications.url: self = .notifications
            default: return nil
            }
        }
    }

    public struct Switch: Equatable, Sendable {
        public let title: String
        public let detail: Line
    }

    public static let windowTitle = "cmm Settings"

    public static let menuBar = Switch(
        title: "Show in the menu bar", detail: Line("Free space next to the clock; click it to see what can go.")
    )

    public static let openAtLogin = Switch(
        title: "Open at login",
        detail: Line(
            "Starts cmm when you log in, so the menu bar item, the reminder and the history keep working. You can also turn it off in ",
            link: "System Settings > General > Login Items", to: .loginItems, "."
        )
    )
    /// Registered, but macOS waits for the person to allow it.
    public static let loginNeedsApproval = Line(
        "macOS is waiting for you to allow it in ", link: "System Settings > General > Login Items", to: .loginItems, "."
    )
    /// macOS refused to change it the last time it was asked.
    public static let loginRefused = Line(
        "macOS did not change this. You can in ", link: "System Settings > General > Login Items", to: .loginItems, "."
    )

    public static let reminder = Switch(
        title: "Weekly reminder",
        detail: Line("A notification once a week, only when at least 2 GB can go, or when free space is under 15 GB and something can go.")
    )
    /// Between the two pickers: "Monday at 10:00".
    public static let reminderAt = "at"
    public static let reminderSilence = Line(
        "macOS can also silence it in ", link: "System Settings > Notifications > cmm", to: .notifications, "."
    )
    /// The reminder is on and macOS will not show it: the one line that says so, and opens the place to change it.
    public static let reminderSilenced = Line(
        "Notifications are off for cmm in ", link: "System Settings > Notifications", to: .notifications, "."
    )

    public static let history = Switch(
        title: "Keep a free-space history", detail: Line("Records one number every 30 minutes, nothing else.")
    )

    /// The four switches, in the board's order.
    public static let switches = [menuBar, openAtLogin, reminder, history]

    // MARK: the reminder's pickers

    /// The weekdays as the person's calendar starts its week, with the calendar's own numbering (1 is Sunday).
    public static func weekdays(calendar: Calendar, locale: Locale) -> [(value: Int, title: String)] {
        var calendar = calendar
        calendar.locale = locale
        let names = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (weekday, names[weekday - 1])
        }
    }

    /// The times of day to choose from, every half hour, in the person's own way of writing a time; and the chosen one too, when
    /// it is not on the half hour (a preference set some other way).
    public static func times(chosen: Int, calendar: Calendar, locale: Locale) -> [(minuteOfDay: Int, title: String)] {
        var minutes = Array(stride(from: 0, to: 24 * 60, by: 30))
        let chosen = min(max(chosen, 0), 24 * 60 - 1)
        if !minutes.contains(chosen) {
            minutes.append(chosen)
            minutes.sort()
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_767_225_600))  // 1 January 2026, a day without a clock change
        return minutes.map { minute in
            let date = calendar.date(byAdding: .minute, value: minute, to: day) ?? day
            return (minute, formatter.string(from: date))
        }
    }
}
