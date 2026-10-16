import Foundation

/// When the weekly reminder comes: a weekday and a time of day, in the person's own calendar.
public struct WeeklySchedule: Equatable, Sendable {
    /// The calendar's numbering: 1 is Sunday, 2 is Monday, 7 is Saturday.
    public let weekday: Int
    public let hour: Int
    public let minute: Int

    /// Monday at 10:00.
    public static let standard = WeeklySchedule(weekday: 2, hour: 10, minute: 0)

    /// What cannot be a weekday or a time is the nearest that can, so a damaged preference can never give the planner nonsense.
    public init(weekday: Int, hour: Int, minute: Int) {
        self.weekday = min(max(weekday, 1), 7)
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

/// The weekly reminder's rules, as pure functions of the clock, the calendar and what is known: when it is next due, whether it
/// is due now, and whether what a scan found is worth a notification. Nothing here starts anything or remembers anything.
public struct WeeklyPlanner: Sendable {
    /// Two reminders are never closer than this. The worst legitimate pair (a schedule at midnight, one caught up at 23:59 on
    /// its day, the next on time in a week with a clock change) is just under six days apart; a person who moves the weekday
    /// right after a reminder came is a few days after it.
    public static let minimumSpacing: TimeInterval = 5 * 86_400

    public let calendar: Calendar
    public let schedule: WeeklySchedule

    public init(calendar: Calendar, schedule: WeeklySchedule = .standard) {
        self.calendar = calendar
        self.schedule = schedule
    }

    /// The next moment the schedule names, strictly after `date`: the weekday and the time on the calendar's own clock, so a
    /// Monday at 10:00 is at 10:00 whatever the clocks did in between. A time the clocks skip that day is the first moment
    /// after the gap, and one they pass twice is the first of them, so every week has exactly one.
    ///
    /// It looks day by day and sets the time on the day it means. (`Calendar.nextDate(after:matching:)` would be shorter, but
    /// it was found, by the test that sweeps a year, to skip the whole week of a clock change when the time falls in the gap and
    /// the search starts a few days before it: from the Sunday before, "Sunday at 02:30" came back two weeks later.)
    public func nextFire(after date: Date) -> Date {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<9 {
            if calendar.component(.weekday, from: day) == schedule.weekday,
               let candidate = calendar.date(
                   bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: day,
                   matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
               ),
               candidate > date {
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return date.addingTimeInterval(7 * 86_400)  // not reached with a real calendar, and never a crash
    }

    /// The latest moment the schedule names at or before `date`. Found by walking forward (the schedule's moments are a week
    /// apart, give or take the hour a clock change moves them), so it always agrees with `nextFire`.
    public func lastFire(onOrBefore date: Date) -> Date {
        var candidate = nextFire(after: date.addingTimeInterval(-8 * 86_400))
        var last = candidate
        while candidate <= date {
            last = candidate
            candidate = nextFire(after: candidate)
        }
        return last
    }

    public enum Decision: Equatable, Sendable {
        /// Check now: this is the occurrence it is for.
        case due(scheduledFor: Date)
        /// Not now; look again then.
        case wait(until: Date)
    }

    /// Whether to check now. Called at the time itself, at launch and at wake: it is due on the day of the scheduled moment,
    /// from that moment to midnight (a Mac that slept through 10:00 is caught up when it wakes that day, and after that day
    /// the week is skipped), once for each occurrence, and never within five days of the last one.
    public func decision(now: Date, lastWeeklyDate: Date?) -> Decision {
        let scheduled = lastFire(onOrBefore: now)
        // A note from the future (the clock was set back, or the file was edited) is no note: it must not silence it for ever.
        let last = lastWeeklyDate.flatMap { $0 <= now ? $0 : nil }
        let onTheDay = calendar.isDate(now, inSameDayAs: scheduled)
        let alreadyDone = last.map { $0 >= scheduled } ?? false
        let farEnoughAfterTheLast = last.map { now.timeIntervalSince($0) >= Self.minimumSpacing } ?? true
        if onTheDay, !alreadyDone, farEnoughAfterTheLast { return .due(scheduledFor: scheduled) }
        return .wait(until: nextFire(after: now))
    }

    public enum Outcome: Equatable, Sendable {
        case notify(WeeklyNotification)
        /// Checked, and nothing worth a notification.
        case quiet
    }

    /// What to do with a scan that was made for the reminder.
    public func outcome(for plan: Plan) -> Outcome {
        // What can go is what the popover calls it: the safe items that give the disk its space back, counted once each.
        let figures = PlanFigures(plan)
        guard let note = WeeklyNotification(free: figures.free, canGo: figures.canGo) else { return .quiet }
        return .notify(note)
    }
}
