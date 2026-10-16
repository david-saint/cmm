import XCTest
@testable import CmmKit

/// The weekly reminder's rules (spec R7 as the board `C-Notification` refines it): when it is next due, with calendar
/// arithmetic that survives the clock changes; whether it is due now (the day of the scheduled moment, once per occurrence,
/// never twice in a week); and whether what a scan found is worth a notification, and what it says.
final class WeeklyPlannerTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let tokyo = TestCalendars.make("Asia/Tokyo")
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func planner(_ calendar: Calendar? = nil, _ schedule: WeeklySchedule = .standard) -> WeeklyPlanner {
        WeeklyPlanner(calendar: calendar ?? rome, schedule: schedule)
    }

    private func components(_ date: Date, in calendar: Calendar? = nil) -> DateComponents {
        (calendar ?? rome).dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
    }

    // MARK: the schedule

    func testTheStandardScheduleIsMondayAtTen() {
        XCTAssertEqual(WeeklySchedule.standard, WeeklySchedule(weekday: 2, hour: 10, minute: 0))
    }

    func testWhatIsNotAWeekdayOrATimeIsTheNearestThatIs() {
        let low = WeeklySchedule(weekday: 0, hour: -3, minute: -1)
        XCTAssertEqual([low.weekday, low.hour, low.minute], [1, 0, 0])
        let high = WeeklySchedule(weekday: 9, hour: 25, minute: 99)
        XCTAssertEqual([high.weekday, high.hour, high.minute], [7, 23, 59])
        let fine = WeeklySchedule(weekday: 7, hour: 23, minute: 59)
        XCTAssertEqual([fine.weekday, fine.hour, fine.minute], [7, 23, 59])
    }

    // MARK: the next time

    func testTheNextMondayAtTenIsStrictlyAfterNow() {
        let planner = planner()
        let thursday = rome.local(2026, 10, 15, 11, 0)
        XCTAssertEqual(planner.nextFire(after: thursday), rome.local(2026, 10, 19, 10, 0))

        let monday = rome.local(2026, 10, 19, 10, 0)
        XCTAssertEqual(planner.nextFire(after: monday.addingTimeInterval(-1)), monday, "a second before: today")
        XCTAssertEqual(planner.nextFire(after: monday), rome.local(2026, 10, 26, 10, 0), "at the moment itself: next week's")
        XCTAssertEqual(planner.nextFire(after: monday.addingTimeInterval(1)), rome.local(2026, 10, 26, 10, 0))
    }

    func testTheLastTimeIsAtOrBeforeNow() {
        let planner = planner()
        let monday = rome.local(2026, 10, 19, 10, 0)
        XCTAssertEqual(planner.lastFire(onOrBefore: monday), monday, "at the moment itself: that moment")
        XCTAssertEqual(planner.lastFire(onOrBefore: monday.addingTimeInterval(-1)), rome.local(2026, 10, 12, 10, 0))
        XCTAssertEqual(planner.lastFire(onOrBefore: rome.local(2026, 10, 24, 12, 0)), monday)
    }

    // MARK: the clocks change

    func testAMondayAtTenIsAtTenWhateverTheClocksDo() throws {
        let zone = rome.timeZone
        let spring = try XCTUnwrap(zone.nextDaylightSavingTimeTransition(after: rome.local(2026, 1, 1)), "Rome puts its clocks forward")
        let autumn = try XCTUnwrap(zone.nextDaylightSavingTimeTransition(after: spring), "and back")
        XCTAssertGreaterThan(zone.daylightSavingTimeOffset(for: spring.addingTimeInterval(1)), 0)
        XCTAssertEqual(zone.daylightSavingTimeOffset(for: autumn.addingTimeInterval(1)), 0)

        /// The Monday at ten before and after a transition, found by the calendar's own arithmetic.
        func mondays(around transition: Date) throws -> (before: Date, after: Date) {
            let sunday = rome.startOfDay(for: transition)
            XCTAssertEqual(rome.component(.weekday, from: sunday), 1, "the clocks change on a Sunday")
            let before = try XCTUnwrap(rome.date(bySettingHour: 10, minute: 0, second: 0, of: try XCTUnwrap(rome.date(byAdding: .day, value: -6, to: sunday))))
            let after = try XCTUnwrap(rome.date(bySettingHour: 10, minute: 0, second: 0, of: try XCTUnwrap(rome.date(byAdding: .day, value: 1, to: sunday))))
            return (before, after)
        }

        let planner = planner()
        let springMondays = try mondays(around: spring)
        XCTAssertEqual(planner.nextFire(after: springMondays.before), springMondays.after)
        XCTAssertEqual(springMondays.after.timeIntervalSince(springMondays.before), 167 * hour, "the week the clocks go forward has 167 hours")

        let autumnMondays = try mondays(around: autumn)
        XCTAssertEqual(planner.nextFire(after: autumnMondays.before), autumnMondays.after)
        XCTAssertEqual(autumnMondays.after.timeIntervalSince(autumnMondays.before), 169 * hour, "the week they go back has 169")

        for monday in [springMondays.after, autumnMondays.after] {
            XCTAssertEqual([components(monday).weekday, components(monday).hour, components(monday).minute], [2, 10, 0])
        }
        // and the last time looks back across the change just as well
        XCTAssertEqual(planner.lastFire(onOrBefore: springMondays.after.addingTimeInterval(day)), springMondays.after)
        XCTAssertEqual(planner.lastFire(onOrBefore: springMondays.after.addingTimeInterval(-1)), springMondays.before)
    }

    func testATimeThatDoesNotExistThatDayComesJustAfterTheGap() throws {
        // Sunday 02:30: on 29 March 2026 the clocks jump from 02:00 to 03:00
        let sunday = WeeklySchedule(weekday: 1, hour: 2, minute: 30)
        let planner = planner(rome, sunday)
        let spring = try XCTUnwrap(rome.timeZone.nextDaylightSavingTimeTransition(after: rome.local(2026, 1, 1)))
        let fire = planner.nextFire(after: rome.local(2026, 3, 28, 12, 0))
        XCTAssertGreaterThanOrEqual(fire, spring, "not in the hour that was skipped")
        XCTAssertLessThan(fire, spring.addingTimeInterval(hour), "and as soon after it as there is")
        XCTAssertEqual(components(fire).day, 29, "still that Sunday")
        XCTAssertEqual(planner.nextFire(after: fire), rome.local(2026, 4, 5, 2, 30), "and the next week at 02:30 again")
        XCTAssertEqual(planner.lastFire(onOrBefore: fire), fire)
        XCTAssertEqual(planner.lastFire(onOrBefore: fire.addingTimeInterval(-1)), rome.local(2026, 3, 22, 2, 30))
    }

    /// `Calendar.nextDate(after:matching:)` came back with 5 April here: asked on the Sunday before a clock change for the next
    /// "Sunday at 02:30", it skipped the whole week of the change. (Asked from Wednesday it was right, which is what made it a
    /// trap.) The planner looks day by day instead.
    func testTheWeekOfAClockChangeIsNotSkippedWhateverDayTheQuestionIsAskedOn() throws {
        let planner = planner(rome, WeeklySchedule(weekday: 1, hour: 2, minute: 30))
        let spring = try XCTUnwrap(rome.timeZone.nextDaylightSavingTimeTransition(after: rome.local(2026, 1, 1)))
        for asked in [rome.local(2026, 3, 22, 2, 30), rome.local(2026, 3, 22, 3, 0), rome.local(2026, 3, 22, 23, 0), rome.local(2026, 3, 25, 12, 0), rome.local(2026, 3, 28, 12, 0)] {
            let fire = planner.nextFire(after: asked)
            XCTAssertGreaterThanOrEqual(fire, spring, "asked \(asked)")
            XCTAssertLessThan(fire, spring.addingTimeInterval(hour), "asked \(asked): the Sunday of the change, just after the gap")
        }
    }

    func testATimeThatHappensTwiceThatDayIsTheFirstOne() throws {
        // Sunday 02:30: on 25 October 2026 the clocks go back from 03:00 to 02:00, so 02:30 is on the clock twice
        let sunday = WeeklySchedule(weekday: 1, hour: 2, minute: 30)
        let planner = planner(rome, sunday)
        let fire = planner.nextFire(after: rome.local(2026, 10, 24, 12, 0))
        XCTAssertEqual(fire, TestTime.utc("2026-10-25T00:30:00Z"), "02:30 summer time, the first")
        let next = planner.nextFire(after: fire)
        XCTAssertEqual(next, rome.local(2026, 11, 1, 2, 30), "not the same Sunday's second 02:30")
        XCTAssertEqual(next.timeIntervalSince(fire), 169 * hour)
        XCTAssertEqual(planner.lastFire(onOrBefore: TestTime.utc("2026-10-25T01:45:00Z")), fire, "the second 02:30 is not another fire")
    }

    func testAZoneWithNoClockChangesIsExactlyAWeekApart() throws {
        XCTAssertNil(tokyo.timeZone.nextDaylightSavingTimeTransition(after: tokyo.local(2026, 1, 1)), "the test needs a zone that never changes")
        let planner = planner(tokyo)
        var fire = planner.nextFire(after: tokyo.local(2026, 1, 1))
        XCTAssertEqual(fire, tokyo.local(2026, 1, 5, 10, 0))
        for _ in 0..<60 {
            let next = planner.nextFire(after: fire)
            XCTAssertEqual(next.timeIntervalSince(fire), 7 * day)
            fire = next
        }
    }

    /// Every schedule that a clock change can touch, swept through a year of moments: the next time is after now and never more
    /// than a week and an hour away, the last is at or before now and never more than a week and an hour back, they are
    /// neighbours, and consecutive fires are a week apart give or take the hour the clocks moved.
    func testEveryScheduleHasExactlyOneFirePerWeekThroughAYearOfClockChanges() {
        let schedules = [
            WeeklySchedule.standard, WeeklySchedule(weekday: 1, hour: 2, minute: 30), WeeklySchedule(weekday: 1, hour: 2, minute: 0),
            WeeklySchedule(weekday: 1, hour: 3, minute: 0), WeeklySchedule(weekday: 1, hour: 0, minute: 0),
            WeeklySchedule(weekday: 2, hour: 0, minute: 0), WeeklySchedule(weekday: 7, hour: 23, minute: 59),
        ]
        let start = rome.local(2026, 1, 1)
        let end = rome.local(2027, 1, 1)
        for schedule in schedules {
            let planner = planner(rome, schedule)
            var moment = start
            while moment < end {
                let next = planner.nextFire(after: moment)
                let last = planner.lastFire(onOrBefore: moment)
                XCTAssertGreaterThan(next, moment, "\(schedule) after \(moment)")
                XCTAssertLessThanOrEqual(next.timeIntervalSince(moment), 7 * day + hour, "\(schedule) after \(moment)")
                XCTAssertLessThanOrEqual(last, moment, "\(schedule) at \(moment)")
                XCTAssertLessThanOrEqual(moment.timeIntervalSince(last), 7 * day + hour, "\(schedule) at \(moment)")
                XCTAssertGreaterThan(planner.nextFire(after: last), moment, "no fire between the last and the next: \(schedule) at \(moment)")
                let spacing = next.timeIntervalSince(last)
                XCTAssertTrue((7 * day - hour)...(7 * day + hour) ~= spacing, "\(schedule): fires \(spacing / hour) hours apart around \(moment)")
                let c = components(next)
                XCTAssertEqual(c.weekday, schedule.weekday, "\(schedule) fires on its weekday: \(next)")
                moment = moment.addingTimeInterval(61 * 60)
            }
        }
    }

    // MARK: whether it is due now

    private func assertDue(_ decision: WeeklyPlanner.Decision, for scheduled: Date, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(decision, .due(scheduledFor: scheduled), message, line: line)
    }

    func testNotDueBeforeTheTimeAndDueFromThenToMidnight() {
        let planner = planner()
        let monday = rome.local(2026, 10, 19, 10, 0)
        XCTAssertEqual(planner.decision(now: monday.addingTimeInterval(-1), lastWeeklyDate: nil), .wait(until: monday))
        assertDue(planner.decision(now: monday, lastWeeklyDate: nil), for: monday, "at the moment itself")
        assertDue(planner.decision(now: monday.addingTimeInterval(1), lastWeeklyDate: nil), for: monday)
        assertDue(planner.decision(now: rome.local(2026, 10, 19, 18, 30), lastWeeklyDate: nil), for: monday, "a Mac that slept through 10:00, awake at half past six")
        assertDue(planner.decision(now: rome.local(2026, 10, 19, 23, 59, 59), lastWeeklyDate: nil), for: monday, "until midnight")
        XCTAssertEqual(
            planner.decision(now: rome.local(2026, 10, 20, 0, 0, 0), lastWeeklyDate: nil), .wait(until: rome.local(2026, 10, 26, 10, 0)),
            "after the day a week is skipped, not caught up on Tuesday"
        )
        XCTAssertEqual(planner.decision(now: rome.local(2026, 10, 22, 9, 0), lastWeeklyDate: nil), .wait(until: rome.local(2026, 10, 26, 10, 0)))
    }

    func testTheDayIsTheCalendarsDayNotTwentyFourHours() {
        // a schedule at 23:30: woken at 00:10 the next day is a different day, 40 minutes later
        let late = planner(rome, WeeklySchedule(weekday: 2, hour: 23, minute: 30))
        let monday = rome.local(2026, 10, 19, 23, 30)
        assertDue(late.decision(now: rome.local(2026, 10, 19, 23, 45), lastWeeklyDate: nil), for: monday)
        XCTAssertEqual(late.decision(now: rome.local(2026, 10, 20, 0, 10), lastWeeklyDate: nil), .wait(until: rome.local(2026, 10, 26, 23, 30)))
    }

    func testOnceForEachOccurrence() {
        let planner = planner()
        let monday = rome.local(2026, 10, 19, 10, 0)
        let ran = rome.local(2026, 10, 19, 10, 0, 5)
        XCTAssertEqual(planner.decision(now: rome.local(2026, 10, 19, 10, 30), lastWeeklyDate: ran), .wait(until: rome.local(2026, 10, 26, 10, 0)), "it ran at 10:00:05")
        XCTAssertEqual(planner.decision(now: rome.local(2026, 10, 19, 23, 0), lastWeeklyDate: ran), .wait(until: rome.local(2026, 10, 26, 10, 0)), "not again that evening")
        // last week's note does not stand in for this week's
        assertDue(planner.decision(now: rome.local(2026, 10, 19, 10, 0, 2), lastWeeklyDate: rome.local(2026, 10, 12, 10, 0, 5)), for: monday)
        // a note exactly at the scheduled moment is that occurrence's
        XCTAssertEqual(planner.decision(now: rome.local(2026, 10, 19, 11, 0), lastWeeklyDate: monday), .wait(until: rome.local(2026, 10, 26, 10, 0)))
    }

    func testANoteFromTheFutureDoesNotSilenceItForEver() {
        let planner = planner()
        let monday = rome.local(2026, 10, 19, 10, 0)
        let future = rome.local(2026, 10, 19, 10, 0).addingTimeInterval(3 * day)
        assertDue(planner.decision(now: monday.addingTimeInterval(60), lastWeeklyDate: future), for: monday, "the clock was set back, or the file was edited")
        XCTAssertEqual(
            planner.decision(now: monday.addingTimeInterval(60), lastWeeklyDate: monday.addingTimeInterval(61)), .due(scheduledFor: monday),
            "even a minute ahead"
        )
    }

    func testNeverTwiceInAWeekEvenWhenThePersonMovesTheDay() {
        // it came on Monday at 10:00; on Tuesday the person moves the reminder to Wednesday at 09:00
        let wednesday = planner(rome, WeeklySchedule(weekday: 4, hour: 9, minute: 0))
        let ran = rome.local(2026, 10, 19, 10, 0, 5)
        XCTAssertEqual(
            wednesday.decision(now: rome.local(2026, 10, 21, 9, 30), lastWeeklyDate: ran), .wait(until: rome.local(2026, 10, 28, 9, 0)),
            "two days after the last one: not yet"
        )
        // the same for a Friday, and a Saturday at ten is four days and some hours after
        let friday = planner(rome, WeeklySchedule(weekday: 6, hour: 9, minute: 0))
        XCTAssertEqual(friday.decision(now: rome.local(2026, 10, 23, 9, 30), lastWeeklyDate: ran), .wait(until: rome.local(2026, 10, 30, 9, 0)))
        // five days exactly is enough, a second less is not
        let saturday = planner(rome, WeeklySchedule(weekday: 7, hour: 10, minute: 0))
        let fiveDays = rome.local(2026, 10, 24, 10, 0)
        let exactly = fiveDays.addingTimeInterval(-5 * day)
        assertDue(saturday.decision(now: fiveDays, lastWeeklyDate: exactly), for: fiveDays, "five days exactly")
        XCTAssertEqual(
            saturday.decision(now: fiveDays, lastWeeklyDate: exactly.addingTimeInterval(1)), .wait(until: rome.local(2026, 10, 31, 10, 0)),
            "a second short of five days"
        )
        XCTAssertEqual(WeeklyPlanner.minimumSpacing, 5 * 86_400)
    }

    func testTheWorstLegitimatePairIsStillFarEnoughApart() {
        // a schedule at midnight on Monday; caught up at 23:59 on the Monday before the clocks go forward; the next one on time
        // after the change: 5 days, 23 hours and a minute apart
        let midnight = planner(rome, WeeklySchedule(weekday: 2, hour: 0, minute: 0))
        let caughtUp = rome.local(2026, 3, 23, 23, 59)
        let next = rome.local(2026, 3, 30, 0, 0)
        XCTAssertEqual(next.timeIntervalSince(caughtUp), 5 * day + 23 * hour + 60, "the clocks went forward in between")
        assertDue(midnight.decision(now: next, lastWeeklyDate: caughtUp), for: next)
    }

    func testTheDayOfAClockChange() throws {
        let sunday = WeeklySchedule(weekday: 1, hour: 2, minute: 30)
        let planner = planner(rome, sunday)
        let fire = planner.nextFire(after: rome.local(2026, 3, 28, 12, 0))
        let spring = try XCTUnwrap(rome.timeZone.nextDaylightSavingTimeTransition(after: rome.local(2026, 1, 1)))
        XCTAssertEqual(planner.decision(now: spring.addingTimeInterval(-1), lastWeeklyDate: nil), .wait(until: fire), "01:59:59, before the gap")
        assertDue(planner.decision(now: fire, lastWeeklyDate: nil), for: fire, "as soon as the gap is over")
        assertDue(planner.decision(now: fire.addingTimeInterval(5 * hour), lastWeeklyDate: nil), for: fire, "and for the rest of the day")
        XCTAssertEqual(planner.decision(now: rome.local(2026, 3, 30, 0, 5), lastWeeklyDate: nil), .wait(until: rome.local(2026, 4, 5, 2, 30)))
    }

    // MARK: whether a scan is worth a notification, and what it says

    private func note(free: Int64, canGo: Int64) -> WeeklyNotification? { WeeklyNotification(free: free, canGo: canGo) }

    func testTheBoardsTwoNotifications() throws {
        let normal = try XCTUnwrap(note(free: 19_800_000_000, canGo: gigabytes(8.4)))
        XCTAssertEqual(normal.title, "19.8 GB free")
        XCTAssertEqual(normal.body, "8 GB can go.", "8.4 rounded down")
        let low = try XCTUnwrap(note(free: 8_100_000_000, canGo: gigabytes(12.3)))
        XCTAssertEqual(low.title, "Only 8.1 GB free")
        XCTAssertEqual(low.body, "12 GB can go.", "12.3 rounded down")
        // between ten and fifteen the normal words (C-Notification)
        let between = try XCTUnwrap(note(free: gigabytes(13.6), canGo: gigabytes(1.4)))
        XCTAssertEqual(between.title, "13.6 GB free")
        XCTAssertEqual(between.body, "1 GB can go.")
    }

    func testItSpeaksWhenAtLeastTwoGigabytesCanGoOrFreeSpaceIsUnderFifteenAndSomethingCan() {
        XCTAssertNotNil(note(free: 20_000_000_000, canGo: 2_000_000_000), "exactly 2 GB can go")
        XCTAssertNil(note(free: 20_000_000_000, canGo: 1_999_999_999), "a byte under, with room to spare")
        XCTAssertNil(note(free: 15_000_000_000, canGo: 1_500_000_000), "exactly 15 GB free is not under 15")
        XCTAssertNotNil(note(free: 14_999_999_999, canGo: 1_500_000_000), "a byte under 15")
        XCTAssertNotNil(note(free: 14_999_999_999, canGo: 1), "anything at all can go")
        XCTAssertEqual(WeeklyNotification.atLeastBytes, 2_000_000_000)
        XCTAssertEqual(WeeklyNotification.freeBelowBytes, 15_000_000_000)
    }

    func testWhenNothingCanGoItNeverSpeaksNotEvenAboutALowDisk() {
        XCTAssertNil(note(free: 28_400_000_000, canGo: 0), "no all clear")
        XCTAssertNil(note(free: 1_000_000_000, canGo: 0), "even with the disk nearly full: there is nothing to do about it here")
        XCTAssertNil(note(free: 0, canGo: 0))
        XCTAssertNil(note(free: 5_000_000_000, canGo: -7), "a negative size is nothing")
    }

    func testOnlyIsForUnderTenGigabytes() throws {
        XCTAssertEqual(try XCTUnwrap(note(free: 9_999_999_999, canGo: 3_000_000_000)).title, "Only 10.0 GB free", "9.99 GB is under 10 and is written 10.0")
        XCTAssertEqual(try XCTUnwrap(note(free: 10_000_000_000, canGo: 3_000_000_000)).title, "10.0 GB free")
        XCTAssertEqual(try XCTUnwrap(note(free: 0, canGo: 3_000_000_000)).title, "Only 0 GB free")
        XCTAssertEqual(WeeklyNotification.onlyBelowBytes, 10_000_000_000)
    }

    func testWhatCanGoIsWholeGigabytesRoundedDownAndUnderOneItSaysSo() throws {
        func body(_ canGo: Int64) throws -> String { try XCTUnwrap(note(free: 5_000_000_000, canGo: canGo)).body }
        XCTAssertEqual(try body(gigabytes(8.4)), "8 GB can go.")
        XCTAssertEqual(try body(gigabytes(8.999)), "8 GB can go.", "rounded down, not to the nearest")
        XCTAssertEqual(try body(1_000_000_000), "1 GB can go.")
        XCTAssertEqual(try body(999_999_999), "Under 1 GB can go.", "never 0 GB")
        XCTAssertEqual(try body(1), "Under 1 GB can go.")
        XCTAssertEqual(try body(gigabytes(250)), "250 GB can go.")
    }

    func testTheNoteIsTheSameEveryWeekAndNotTimeSensitive() throws {
        let one = try XCTUnwrap(note(free: 19_800_000_000, canGo: gigabytes(8.4)))
        let two = try XCTUnwrap(note(free: 12_000_000_000, canGo: gigabytes(3)))
        XCTAssertEqual(one.identifier, two.identifier, "so each Monday's replaces last week's")
        XCTAssertEqual(one.identifier, WeeklyNotification.identifier)
        XCTAssertEqual(one.level, .active)
    }

    func testNothingItSaysHasAPathAGroupOrDocker() {
        let sizes: [Int64] = [-5, 0, 1, 999_999_999, 1_000_000_000, 2_000_000_000, 9_999_999_999, 10_000_000_000, 14_999_999_999, 15_000_000_000,
                              gigabytes(8.4), gigabytes(12.3), 1_000_000_000_000, Int64.max]
        var spoken = 0
        for free in sizes {
            for canGo in sizes {
                guard let note = note(free: free, canGo: canGo) else { continue }
                spoken += 1
                for text in [note.identifier, note.title, note.body] {
                    XCTAssertFalse(text.contains("/"), text)
                    XCTAssertFalse(text.lowercased().contains("docker"), text)
                    XCTAssertFalse(text.contains("~"), text)
                }
            }
        }
        XCTAssertGreaterThan(spoken, 50, "the sweep reached the notifications")
    }

    // MARK: what a plan makes of it

    func testTheBoardsPlanSpeaksAsTheBoardDoes() throws {
        let plan = try TestPlans.fixture("plan-c.json")
        guard case .notify(let note) = planner().outcome(for: plan) else { return XCTFail("8.4 GB can go") }
        XCTAssertEqual(note.title, "19.8 GB free")
        XCTAssertEqual(note.body, "8 GB can go.", "Docker's 9.0 GB, which is freed inside Docker's disk image, is not in it")
    }

    func testCanGoIsTheSafeItemsThatFreeTheDiskAndNothingElse() {
        let plan = TestPlans.plan([
            TestPlans.item("/a", group: "A", rule: "a", bytes: gigabytes(1)),
            TestPlans.item("/a", group: "A", rule: "a", bytes: gigabytes(1)),  // the same path again counts once
            TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gigabytes(9), tier: .review, action: .command, freesInside: "Docker's disk image"),
            TestPlans.item("x: prune", group: "X", rule: "x", bytes: gigabytes(20), action: .command, freesInside: "X's disk image"),
            TestPlans.item("/m", group: "M", rule: "m", bytes: gigabytes(30), tier: .manual),
        ], freeBytes: 5_000_000_000)
        guard case .notify(let note) = planner().outcome(for: plan) else { return XCTFail("free space is low and something can go") }
        XCTAssertEqual(note.title, "Only 5.0 GB free")
        XCTAssertEqual(note.body, "1 GB can go.")
    }

    func testAPlanWithNothingToGoIsQuiet() throws {
        XCTAssertEqual(planner().outcome(for: TestPlans.plan([], freeBytes: 3_000_000_000)), .quiet)
        let onlyDocker = TestPlans.plan(
            [TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gigabytes(9), tier: .review, action: .command, freesInside: "Docker's disk image")],
            freeBytes: 3_000_000_000
        )
        XCTAssertEqual(planner().outcome(for: onlyDocker), .quiet, "Docker's review figure is not something that can go")
        XCTAssertEqual(planner().outcome(for: try TestPlans.fixture("plan-empty.json")), .quiet)
    }

    func testAPlanWithLittleToGoAndRoomToSpareIsQuiet() {
        let plan = TestPlans.plan([TestPlans.item("/a", group: "A", rule: "a", bytes: gigabytes(1.5))], freeBytes: 30_000_000_000)
        XCTAssertEqual(planner().outcome(for: plan), .quiet)
    }
}
