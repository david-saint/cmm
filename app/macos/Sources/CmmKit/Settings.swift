import Foundation
import Observation

/// Every preference the app keeps, and nothing else is ever kept (spec R9): no path, no size, no history of the app's own.
public enum SettingsKey: String, CaseIterable, Sendable {
    case detailsFace
    case menuBarEnabled
    case weeklyReminderEnabled
    case historyEnabled
    case optInAnswered
    case lastWeeklyDate
    case weeklyWeekday
    case weeklyMinuteOfDay
}

/// Where the preferences are kept. The app's is the user defaults; a test hands in a dictionary in memory, so no test ever
/// writes to the real preferences.
public protocol SettingsStore: Sendable {
    func value(for key: SettingsKey) -> Any?
    /// Nil removes the key.
    func set(_ value: Any?, for key: SettingsKey)
}

/// The app's own preferences. It cannot be made with another suite: there is one, and it is the app's.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let standard = UserDefaultsSettingsStore()

    private let defaults = UserDefaults.standard

    private init() {}

    public func value(for key: SettingsKey) -> Any? {
        defaults.object(forKey: key.rawValue)
    }

    public func set(_ value: Any?, for key: SettingsKey) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}

/// The preferences, typed. What is missing or damaged reads as its default (or the nearest value that can be), so a preference
/// that was edited by hand can change what the app does but never crash it.
public struct Settings: Sendable {
    public let store: any SettingsStore

    public init(store: any SettingsStore) {
        self.store = store
    }

    /// The app's preferences.
    public static let standard = Settings(store: UserDefaultsSettingsStore.standard)

    public var detailsFace: DetailsFace {
        get { DetailsFace.restored(from: store.value(for: .detailsFace) as? String) }
        nonmutating set { store.set(newValue.rawValue, for: .detailsFace) }
    }

    public var menuBarEnabled: Bool {
        get { bool(.menuBarEnabled) }
        nonmutating set { store.set(newValue, for: .menuBarEnabled) }
    }

    public var weeklyReminderEnabled: Bool {
        get { bool(.weeklyReminderEnabled) }
        nonmutating set { store.set(newValue, for: .weeklyReminderEnabled) }
    }

    public var historyEnabled: Bool {
        get { bool(.historyEnabled) }
        nonmutating set { store.set(newValue, for: .historyEnabled) }
    }

    /// The one-time card was answered, either way.
    public var optInAnswered: Bool {
        get { bool(.optInAnswered) }
        nonmutating set { store.set(newValue, for: .optInAnswered) }
    }

    /// When the weekly reminder last finished a check.
    public var lastWeeklyDate: Date? {
        get { store.value(for: .lastWeeklyDate) as? Date }
        nonmutating set { store.set(newValue, for: .lastWeeklyDate) }
    }

    /// The weekday and the time of day, kept as two small numbers (the calendar's weekday, and minutes since midnight).
    public var weeklySchedule: WeeklySchedule {
        get {
            let standard = WeeklySchedule.standard
            let weekday = integer(.weeklyWeekday) ?? standard.weekday
            let minuteOfDay = min(max(integer(.weeklyMinuteOfDay) ?? standard.hour * 60 + standard.minute, 0), 24 * 60 - 1)
            return WeeklySchedule(weekday: weekday, hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        }
        nonmutating set {
            store.set(newValue.weekday, for: .weeklyWeekday)
            store.set(newValue.hour * 60 + newValue.minute, for: .weeklyMinuteOfDay)
        }
    }

    private func bool(_ key: SettingsKey) -> Bool {
        store.value(for: key) as? Bool ?? false
    }

    private func integer(_ key: SettingsKey) -> Int? {
        store.value(for: key) as? Int
    }
}

/// The preferences as the Settings window and the one-time card use them: the switches the person has chosen, written as they
/// are chosen, and what the system says about the two things the system owns (Open at login and notifications), which is read
/// and never kept.
@MainActor
@Observable
public final class SettingsModel {
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let loginControl: any LoginItem
    @ObservationIgnored private let permission: any NotificationPermission

    public var detailsFace: DetailsFace { didSet { if detailsFace != oldValue { settings.detailsFace = detailsFace } } }
    public var menuBarEnabled: Bool { didSet { if menuBarEnabled != oldValue { settings.menuBarEnabled = menuBarEnabled } } }
    public var historyEnabled: Bool { didSet { if historyEnabled != oldValue { settings.historyEnabled = historyEnabled } } }
    public var lastWeeklyDate: Date? { didSet { if lastWeeklyDate != oldValue { settings.lastWeeklyDate = lastWeeklyDate } } }
    public var weeklySchedule: WeeklySchedule { didSet { if weeklySchedule != oldValue { settings.weeklySchedule = weeklySchedule } } }
    /// Only `setWeeklyReminder` changes this: the reminder's switch is the one moment macOS is asked about notifications.
    public private(set) var weeklyReminderEnabled: Bool { didSet { if weeklyReminderEnabled != oldValue { settings.weeklyReminderEnabled = weeklyReminderEnabled } } }
    /// Only the two answers of the one-time card change this.
    public private(set) var optInAnswered: Bool { didSet { if optInAnswered != oldValue { settings.optInAnswered = optInAnswered } } }

    /// Open at login, as the system says.
    public private(set) var openAtLogin: LoginItemState
    /// The system refused to change Open at login the last time it was asked.
    public private(set) var openAtLoginFailed = false
    /// What macOS lets the reminder do, as of the last time it was read.
    public private(set) var notifications = NotificationAuthorization.notAsked

    public init(settings: Settings, loginItem: any LoginItem, notifications permission: any NotificationPermission) {
        self.settings = settings
        loginControl = loginItem
        self.permission = permission
        detailsFace = settings.detailsFace
        menuBarEnabled = settings.menuBarEnabled
        weeklyReminderEnabled = settings.weeklyReminderEnabled
        historyEnabled = settings.historyEnabled
        optInAnswered = settings.optInAnswered
        lastWeeklyDate = settings.lastWeeklyDate
        weeklySchedule = settings.weeklySchedule
        openAtLogin = loginItem.state
    }

    /// The reminder is on, but macOS will not show it.
    public var reminderIsSilenced: Bool { weeklyReminderEnabled && notifications == .denied }

    /// Reads what the system says again (when the window comes forward: the person may have changed it in System Settings).
    public func refresh() async {
        openAtLogin = loginControl.state
        notifications = await permission.status()
    }

    /// The reminder's switch. Turning it on is the one moment macOS is asked about notifications, and only if it has not been
    /// asked: after a no it is not asked again, and the reminder row says that macOS will not show it.
    public func setWeeklyReminder(_ on: Bool) async {
        weeklyReminderEnabled = on
        guard on else { return }
        let current = await permission.status()
        notifications = current == .notAsked ? await permission.request() : current
    }

    /// Open at login's switch. What the system says afterwards is what is shown, whether it worked or not.
    public func setOpenAtLogin(_ on: Bool) {
        do {
            try loginControl.setEnabled(on)
            openAtLoginFailed = false
        } catch {
            openAtLoginFailed = true
        }
        openAtLogin = loginControl.state
    }

    /// "Turn on" on the one-time card: the menu bar item, the weekly reminder, the free-space history and Open at login, and
    /// the question to macOS about notifications. The card is answered first, so it is gone while macOS's question is open.
    public func turnOnEverything() async {
        optInAnswered = true
        menuBarEnabled = true
        historyEnabled = true
        setOpenAtLogin(true)
        await setWeeklyReminder(true)
    }

    /// "Not now": nothing is turned on, and the card is not shown again.
    public func declineOptIn() {
        optInAnswered = true
    }
}
