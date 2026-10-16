import XCTest
@testable import CmmKit

/// The scans the weekly reminder asks for, scripted: the last result repeats, every call is counted, and a gate can hold one.
final class ScriptedScans: @unchecked Sendable {
    private struct Contents {
        var results: [Result<Plan, CmmError>]
        var calls = 0
        var gate: FakeCmmClient.Gate?
    }

    private let box: Locked<Contents>

    init(_ results: [Result<Plan, CmmError>]) {
        box = Locked(Contents(results: results))
    }

    var calls: Int { box.withLock { $0.calls } }

    func hold() -> FakeCmmClient.Gate {
        let gate = FakeCmmClient.Gate()
        box.withLock { $0.gate = gate }
        return gate
    }

    func scan() async throws -> Plan {
        let gate = box.withLock { contents -> FakeCmmClient.Gate? in
            contents.calls += 1
            return contents.gate
        }
        await gate?.wait()
        return try box.withLock { contents in
            let result = contents.results.count > 1 ? contents.results.removeFirst() : contents.results[0]
            return try result.get()
        }
    }
}

/// The weekly reminder, start to finish (spec R7): when it checks, what it records, when it stays quiet, and that it never
/// asks macOS anything.
@MainActor
final class WeeklyReminderTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let monday = TestCalendars.rome.local(2026, 10, 19, 10, 0)

    @MainActor
    private final class Rig {
        let store: MemorySettingsStore
        let permission = FakeNotificationPermission()
        let settings: SettingsModel
        let clock: Locked<Date>
        let scans: ScriptedScans
        let delivered = Locked<[WeeklyNotification]>([])
        let log = Locked<[String]>([])
        let reminder: WeeklyReminder

        init(
            at start: Date, calendar: Calendar, scans results: [Result<Plan, CmmError>],
            enabled: Bool = true, schedule: WeeklySchedule? = nil, lastCheck: Date? = nil
        ) {
            var values: [SettingsKey: Any] = [.weeklyReminderEnabled: enabled]
            if let lastCheck { values[.lastWeeklyDate] = lastCheck }
            if let schedule {
                values[.weeklyWeekday] = schedule.weekday
                values[.weeklyMinuteOfDay] = schedule.hour * 60 + schedule.minute
            }
            let store = MemorySettingsStore(values)
            let settings = SettingsModel(settings: Settings(store: store), loginItem: FakeLoginItem(), notifications: permission)
            let clock = Locked(start)
            let scripted = ScriptedScans(results)
            let delivered = delivered
            let log = log
            self.store = store
            self.settings = settings
            self.clock = clock
            self.scans = scripted
            reminder = WeeklyReminder(
                settings: settings, calendar: calendar,
                now: { clock.withLock { $0 } },
                scan: { try await scripted.scan() },
                deliver: { note in delivered.withLock { $0.append(note) } },
                log: { line in log.withLock { $0.append(line) } }
            )
        }

        var notes: [WeeklyNotification] { delivered.withLock { $0 } }
        var lines: [String] { log.withLock { $0 } }
        var lastCheck: Date? { Settings(store: store).lastWeeklyDate }

        func move(to date: Date) {
            clock.withLock { $0 = date }
        }
    }

    private func rig(
        at start: Date? = nil, scans: [Result<Plan, CmmError>]? = nil, enabled: Bool = true,
        schedule: WeeklySchedule? = nil, lastCheck: Date? = nil
    ) throws -> Rig {
        let results = try scans ?? [.success(try TestPlans.fixture("plan-c.json"))]
        return Rig(at: start ?? monday, calendar: rome, scans: results, enabled: enabled, schedule: schedule, lastCheck: lastCheck)
    }

    private let quietPlan = TestPlans.plan([], freeBytes: 28_400_000_000)

    // MARK: switched off

    func testItDoesNothingWhileTheReminderIsOff() async throws {
        let rig = try rig(enabled: false)
        let outcome = await rig.reminder.check()
        XCTAssertEqual(outcome, .off)
        XCTAssertEqual(rig.scans.calls, 0)
        XCTAssertTrue(rig.notes.isEmpty)
        XCTAssertNil(rig.lastCheck)
        XCTAssertNil(rig.reminder.nextCheck())
    }

    // MARK: when it is due

    func testBeforeTheTimeOnTheDayItWaitsForTheTime() async throws {
        let rig = try rig(at: monday.addingTimeInterval(-1))
        let outcome = await rig.reminder.check()
        XCTAssertEqual(outcome, .notDue(until: monday))
        XCTAssertEqual(rig.scans.calls, 0)
        XCTAssertNil(rig.lastCheck)
    }

    func testOnAnotherDayItWaitsForNextMonday() async throws {
        let rig = try rig(at: rome.local(2026, 10, 14, 11, 0))
        let outcome = await rig.reminder.check()
        XCTAssertEqual(outcome, .notDue(until: monday))
        XCTAssertEqual(rig.scans.calls, 0)
    }

    func testAtTheTimeItScansAndSpeaksAtOnceAsTheBoardDoes() async throws {
        let rig = try rig()
        let outcome = await rig.reminder.check()
        let note = try XCTUnwrap(rig.notes.first)
        XCTAssertEqual(outcome, .delivered(note))
        XCTAssertEqual(rig.notes.count, 1)
        XCTAssertEqual(rig.scans.calls, 1)
        XCTAssertEqual(note.title, "19.8 GB free")
        XCTAssertEqual(note.body, "8 GB can go.")
        XCTAssertEqual(rig.lastCheck, monday, "the week's check is written down")
        XCTAssertEqual(rig.settings.lastWeeklyDate, monday)
    }

    func testItSpeaksOnceAWeek() async throws {
        let rig = try rig()
        await rig.reminder.check()
        rig.move(to: rome.local(2026, 10, 19, 15, 0))
        let again = await rig.reminder.check()
        XCTAssertEqual(again, .notDue(until: rome.local(2026, 10, 26, 10, 0)))
        XCTAssertEqual(rig.scans.calls, 1, "no second scan the same day")
        XCTAssertEqual(rig.notes.count, 1)
    }

    func testNextWeekItIsDueAgain() async throws {
        let rig = try rig()
        await rig.reminder.check()
        rig.move(to: rome.local(2026, 10, 26, 10, 0))
        let outcome = await rig.reminder.check()
        guard case .delivered = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(rig.scans.calls, 2)
        XCTAssertEqual(rig.notes.count, 2)
        XCTAssertEqual(rig.lastCheck, rome.local(2026, 10, 26, 10, 0))
    }

    // MARK: staying quiet

    func testAScanWorthNoNoteIsStillACompletedCheck() async throws {
        let rig = try rig(scans: [.success(quietPlan)])
        let outcome = await rig.reminder.check()
        XCTAssertEqual(outcome, .quiet)
        XCTAssertTrue(rig.notes.isEmpty, "nothing can go: no notification at all")
        XCTAssertEqual(rig.lastCheck, monday, "but the week's check is done")
        rig.move(to: rome.local(2026, 10, 19, 17, 0))
        let again = await rig.reminder.check()
        XCTAssertEqual(again, .notDue(until: rome.local(2026, 10, 26, 10, 0)))
        XCTAssertEqual(rig.scans.calls, 1)
    }

    func testAFailedScanSaysNothingWritesNothingDownAndIsTriedAgainWhenAsked() async throws {
        let rig = try rig(scans: [.failure(.planFailed(status: 1, stderr: "could not read /Users/saint/secret")), .success(try TestPlans.fixture("plan-c.json"))])
        let failed = await rig.reminder.check()
        XCTAssertEqual(failed, .scanFailed)
        XCTAssertTrue(rig.notes.isEmpty)
        XCTAssertNil(rig.lastCheck, "nothing was checked, so nothing is written down")
        XCTAssertEqual(rig.lines.count, 1)
        let line = try XCTUnwrap(rig.lines.first)
        XCTAssertTrue(line.contains("cmm could not make a plan"), line)
        XCTAssertFalse(line.contains("/"), "no path in the log: \(line)")
        XCTAssertFalse(line.contains("secret"), line)

        rig.move(to: rome.local(2026, 10, 19, 15, 30))  // the Mac wakes in the afternoon
        let retried = await rig.reminder.check()
        guard case .delivered = retried else { return XCTFail("\(retried)") }
        XCTAssertEqual(rig.scans.calls, 2)
        XCTAssertEqual(rig.lastCheck, rome.local(2026, 10, 19, 15, 30))
    }

    func testAnErrorThatIsNotCmmsIsLoggedByItsTypeAndNotItsText() async throws {
        struct Odd: Error, CustomStringConvertible { var description: String { "failed at /Users/saint/secret" } }
        let store = MemorySettingsStore([.weeklyReminderEnabled: true])
        let permission = FakeNotificationPermission()
        let settings = SettingsModel(settings: Settings(store: store), loginItem: FakeLoginItem(), notifications: permission)
        let lines = Locked<[String]>([])
        let moment = monday
        let reminder = WeeklyReminder(
            settings: settings, calendar: rome, now: { moment },
            scan: { throw Odd() }, deliver: { _ in }, log: { line in lines.withLock { $0.append(line) } }
        )
        let outcome = await reminder.check()
        XCTAssertEqual(outcome, .scanFailed)
        let line = try XCTUnwrap(lines.withLock { $0 }.first)
        XCTAssertTrue(line.contains("Odd"), line)
        XCTAssertFalse(line.contains("/"), line)
        XCTAssertFalse(line.contains("secret"), line)
    }

    // MARK: a Mac that was asleep

    func testAMacThatSleptThroughTheTimeIsCaughtUpThatDay() async throws {
        let rig = try rig(at: rome.local(2026, 10, 19, 15, 30))
        let outcome = await rig.reminder.check()
        guard case .delivered = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(rig.scans.calls, 1)
    }

    func testButTheDayAfterTheWeekIsSkipped() async throws {
        let rig = try rig(at: rome.local(2026, 10, 20, 8, 0))
        let outcome = await rig.reminder.check()
        XCTAssertEqual(outcome, .notDue(until: rome.local(2026, 10, 26, 10, 0)))
        XCTAssertEqual(rig.scans.calls, 0)
    }

    func testAClockThatWasSetBackDoesNotSilenceItForEver() async throws {
        // the last check says next year: that cannot be, so it does not count
        let rig = try rig(lastCheck: rome.local(2027, 3, 1, 10, 0))
        let outcome = await rig.reminder.check()
        guard case .delivered = outcome else { return XCTFail("\(outcome)") }
    }

    // MARK: the person's schedule

    func testItKeepsTheDayAndTheTimeThePersonChose() async throws {
        let wednesday = WeeklySchedule(weekday: 4, hour: 18, minute: 30)
        let onTheDay = try rig(at: rome.local(2026, 10, 21, 18, 30), schedule: wednesday)
        let outcome = await onTheDay.reminder.check()
        guard case .delivered = outcome else { return XCTFail("\(outcome)") }

        let onAMonday = try rig(at: monday, schedule: wednesday)
        let notMonday = await onAMonday.reminder.check()
        XCTAssertEqual(notMonday, .notDue(until: rome.local(2026, 10, 21, 18, 30)))
        XCTAssertEqual(onAMonday.scans.calls, 0)
    }

    func testTheNextCheckIsTheNextMomentOfTheSchedule() async throws {
        let rig = try rig(at: rome.local(2026, 10, 14, 11, 0))
        XCTAssertEqual(rig.reminder.nextCheck(), monday)
        rig.move(to: monday)
        await rig.reminder.check()
        XCTAssertEqual(rig.reminder.nextCheck(), rome.local(2026, 10, 26, 10, 0), "once this week's is done, next week's")
        rig.settings.weeklySchedule = WeeklySchedule(weekday: 4, hour: 9, minute: 15)
        XCTAssertEqual(rig.reminder.nextCheck(), rome.local(2026, 10, 21, 9, 15), "and the new schedule at once")
    }

    // MARK: one at a time, and off means off

    /// A check running in the background of the test, with what it came to; waiting for it can fail the test, never hang it.
    private func begin(_ rig: Rig) -> (job: SamplerJob, outcome: Locked<WeeklyReminder.Outcome?>) {
        let outcome = Locked<WeeklyReminder.Outcome?>(nil)
        let job = SamplerJob {
            let result = await rig.reminder.check()
            outcome.withLock { $0 = result }
        }
        return (job, outcome)
    }

    private func finish(_ job: SamplerJob, _ what: String) async throws {
        let reached = await eventuallyOnMain(timeout: 3) { job.isFinished }
        if !reached { throw SamplerStuck("\(what) never returned") }
    }

    func testOnlyOneCheckRunsAtATime() async throws {
        let rig = try rig()
        let gate = rig.scans.hold()
        let first = begin(rig)
        await eventuallyOnMain(timeout: 3) { rig.scans.calls == 1 }
        XCTAssertTrue(rig.reminder.isChecking)

        let second = begin(rig)
        try await finish(second.job, "the second check, which should be turned away at once")
        XCTAssertEqual(second.outcome.withLock { $0 }, .busy)
        XCTAssertEqual(rig.scans.calls, 1, "a second scan is not started")

        gate.open()
        try await finish(first.job, "the first check")
        guard case .delivered? = first.outcome.withLock({ $0 }) else { return XCTFail("\(String(describing: first.outcome.withLock { $0 }))") }
        XCTAssertEqual(rig.notes.count, 1)
        XCTAssertFalse(rig.reminder.isChecking)
    }

    func testAnotherCheckAtTheSameInstantFindsTheWeekDone() async throws {
        let rig = try rig()
        await rig.reminder.check()
        let again = await rig.reminder.check()  // the clock has not moved
        XCTAssertEqual(again, .notDue(until: rome.local(2026, 10, 26, 10, 0)))
        XCTAssertEqual(rig.scans.calls, 1)
        XCTAssertEqual(rig.notes.count, 1)
    }

    func testTurningTheReminderOffWhileItScansSpeaksNothingAndWritesNothingDown() async throws {
        let rig = try rig()
        let gate = rig.scans.hold()
        let checking = Task { await rig.reminder.check() }
        await eventuallyOnMain(timeout: 3) { rig.scans.calls == 1 }

        await rig.settings.setWeeklyReminder(false)
        gate.open()
        let outcome = await checking.value
        XCTAssertEqual(outcome, .off)
        XCTAssertTrue(rig.notes.isEmpty)
        XCTAssertNil(rig.lastCheck)
        XCTAssertFalse(rig.reminder.isChecking)
    }

    // MARK: what it never does

    func testItNeverAsksMacOSAnything() async throws {
        let rig = try rig(scans: [.success(try TestPlans.fixture("plan-c.json"))])
        await rig.reminder.check()
        rig.move(to: rome.local(2026, 10, 26, 10, 0))
        await rig.reminder.check()
        _ = rig.reminder.nextCheck()
        XCTAssertEqual(rig.permission.requestCalls, 0)
        XCTAssertEqual(rig.permission.statusCalls, 0)
    }

    func testItWritesDownTheCheckAndNothingElse() async throws {
        let rig = try rig()
        let before = rig.store.writes
        await rig.reminder.check()
        XCTAssertEqual(Array(rig.store.writes.dropFirst(before.count)), ["lastWeeklyDate"])
    }
}
