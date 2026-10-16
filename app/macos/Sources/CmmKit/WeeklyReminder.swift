import Foundation

/// The weekly reminder from the moment it is asked to look to the note it posts (spec R7 and the board `C-Notification`). The
/// app asks it to check at the scheduled time, at launch and at wake; it asks the planner whether a check is due, scans if it
/// is, posts the note at once if the scan is worth one, and writes down that the week's check is done, whether or not it
/// spoke, so that it does not scan again until next week.
///
/// A scan that fails writes nothing down, so the next time the app is asked that day (a wake, a launch) it tries again. Only
/// one check runs at a time. It never asks macOS about notifications: that is the reminder switch's job, once.
@MainActor
public final class WeeklyReminder {
    public enum Outcome: Equatable, Sendable {
        /// The reminder is switched off: nothing was looked at.
        case off
        /// Not the day, or this week's check is done: look again then.
        case notDue(until: Date)
        /// Another check is running.
        case busy
        /// The scan failed: nothing was posted and nothing was written down.
        case scanFailed
        /// Checked, and nothing worth a note.
        case quiet
        case delivered(WeeklyNotification)
    }

    public private(set) var isChecking = false

    private let settings: SettingsModel
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let scan: @MainActor () async throws -> Plan
    private let deliver: @MainActor (WeeklyNotification) async -> Void
    private let log: @Sendable (String) -> Void

    /// `scan` makes the scan the reminder is for (the window's own, so that the window opens on the same numbers); `deliver`
    /// posts the note at once; `log` takes the one quiet line a failed scan leaves.
    public init(
        settings: SettingsModel,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        scan: @escaping @MainActor () async throws -> Plan,
        deliver: @escaping @MainActor (WeeklyNotification) async -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.settings = settings
        self.calendar = calendar
        self.now = now
        self.scan = scan
        self.deliver = deliver
        self.log = log
    }

    /// Look now: is a check due, and if so, make it.
    @discardableResult
    public func check() async -> Outcome {
        guard settings.weeklyReminderEnabled else { return .off }
        guard !isChecking else { return .busy }

        let planner = WeeklyPlanner(calendar: calendar, schedule: settings.weeklySchedule)
        if case .wait(let until) = planner.decision(now: now(), lastWeeklyDate: settings.lastWeeklyDate) {
            return .notDue(until: until)
        }

        isChecking = true
        defer { isChecking = false }
        let plan: Plan
        do {
            plan = try await scan()
        } catch {
            log(Self.line(for: error))
            return .scanFailed
        }
        // Switched off while the scan ran: it was asked to stop, so it says nothing and writes nothing down.
        guard settings.weeklyReminderEnabled else { return .off }

        var outcome = Outcome.quiet
        if case .notify(let note) = planner.outcome(for: plan) {
            await deliver(note)
            outcome = .delivered(note)
        }
        settings.lastWeeklyDate = now()
        return outcome
    }

    /// When to look next: the next moment of the schedule, or nil while the reminder is off.
    public func nextCheck() -> Date? {
        guard settings.weeklyReminderEnabled else { return nil }
        return WeeklyPlanner(calendar: calendar, schedule: settings.weeklySchedule).nextFire(after: now())
    }

    /// One line that says what went wrong and never what cmm printed (it can hold a path).
    private static func line(for error: any Error) -> String {
        let what = (error as? CmmError)?.title ?? String(describing: type(of: error))
        return "No weekly reminder: \(what)."
    }
}
