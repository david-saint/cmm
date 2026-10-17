import XCTest
@testable import CmmKit

/// The wall clock, by hand: nothing fires until a test says the moment has come.
final class FakeWallClock: WallClockTimer, @unchecked Sendable {
    final class Entry: ScheduledActivity, @unchecked Sendable {
        let date: Date
        let fire: @Sendable () -> Void
        private let cancelled = Locked(false)

        init(date: Date, fire: @escaping @Sendable () -> Void) {
            self.date = date
            self.fire = fire
        }

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func cancel() {
            cancelled.withLock { $0 = true }
        }
    }

    private let entries = Locked<[Entry]>([])

    var scheduled: [Entry] { entries.withLock { $0 } }
    /// The moment the one timer that is still set is set for.
    var pending: [Date] { scheduled.filter { !$0.isCancelled }.map(\.date) }

    func schedule(at date: Date, fire: @escaping @Sendable () -> Void) -> any ScheduledActivity {
        let entry = Entry(date: date, fire: fire)
        entries.withLock { $0.append(entry) }
        return entry
    }

    /// The timer that is still set fires (the time has come, or the Mac woke after it).
    @discardableResult
    func fire() -> Bool {
        guard let entry = scheduled.last(where: { !$0.isCancelled }) else { return false }
        entry.fire()
        return true
    }
}

/// The notes that would have been shown.
final class RecordingPoster: NotificationPoster, @unchecked Sendable {
    private let posted = Locked<[WeeklyNotification]>([])
    var notes: [WeeklyNotification] { posted.withLock { $0 } }

    func post(_ note: WeeklyNotification) async {
        posted.withLock { $0.append(note) }
    }
}

// MARK: the reminder's scan

/// The weekly reminder's scan is the window's own (spec R7, the board `C-Notification`): it uses a fresh plan as it is, waits for
/// a scan that is running, never takes a screen from someone using it, and never starts a cleaning.
@MainActor
final class WeeklyScanTests: XCTestCase {
    private let ten = TestCalendars.rome.local(2026, 10, 19, 10, 0)

    @MainActor
    private final class Rig {
        let client: FakeCmmClient
        let model: AppModel
        var windowOpen = true
        var scannedAt: Date?
        var clock: Date

        init(plans: [Result<Plan, CmmError>], at start: Date) {
            client = FakeCmmClient(plans: plans)
            model = AppModel(client: client, now: { start })
            clock = start
        }
    }

    private func scan(_ rig: Rig, waitLimit: TimeInterval = 10) -> WeeklyScan {
        WeeklyScan(
            model: rig.model, mainWindowOpen: { rig.windowOpen }, lastScanAt: { rig.scannedAt }, now: { [clock = rig.clock] in clock },
            waitLimit: waitLimit, pause: { _ in try? await Task.sleep(for: .milliseconds(10)) }
        )
    }

    private func plans() throws -> (Plan, Plan) {
        let first = try TestPlans.fixture("plan-c.json")
        let second = TestPlans.plan([TestPlans.item("/Users/test/second", bytes: gigabytes(3))], freeBytes: gigabytes(12))
        return (first, second)
    }

    func testAFreshPlanOnTheRestScreenIsUsedAsItIsSoTheTicksStay() async throws {
        let (first, second) = try plans()
        let rig = Rig(plans: [.success(first), .success(second)], at: ten)
        await rig.model.scan()
        rig.model.toggle(try XCTUnwrap(rig.model.selection?.groups.first))  // the person's ticks
        let ticked = rig.model.selection?.selectedCount
        rig.scannedAt = ten.addingTimeInterval(-14 * 60)
        let plan = try await scan(rig).scan()
        XCTAssertEqual(plan, first)
        XCTAssertEqual(rig.client.planCalls, 1, "no second scan")
        XCTAssertEqual(rig.model.selection?.selectedCount, ticked)
    }

    func testAnOlderPlanIsScannedAgainByTheWindowItself() async throws {
        let (first, second) = try plans()
        let rig = Rig(plans: [.success(first), .success(second)], at: ten)
        await rig.model.scan()
        rig.scannedAt = ten.addingTimeInterval(-16 * 60)
        let plan = try await scan(rig).scan()
        XCTAssertEqual(plan, second)
        XCTAssertEqual(rig.client.planCalls, 2)
        XCTAssertEqual(rig.model.plan, second, "the window shows the same numbers the note gives")
    }

    func testAPlanWithNoKnownTimeOrFromTheFutureIsNotFresh() async throws {
        let (first, second) = try plans()
        let rig = Rig(plans: [.success(first), .success(second), .success(first)], at: ten)
        await rig.model.scan()
        rig.scannedAt = nil
        _ = try await scan(rig).scan()
        XCTAssertEqual(rig.client.planCalls, 2)
        rig.scannedAt = ten.addingTimeInterval(60)
        _ = try await scan(rig).scan()
        XCTAssertEqual(rig.client.planCalls, 3)
    }

    func testAWindowThatNeverScannedScans() async throws {
        let (first, _) = try plans()
        let rig = Rig(plans: [.success(first)], at: ten)
        rig.windowOpen = false
        let plan = try await scan(rig).scan()
        XCTAssertEqual(plan, first)
        XCTAssertEqual(rig.model.phase, .ready)
    }

    func testAScanThatIsRunningIsWaitedForAndItsPlanUsed() async throws {
        let (first, _) = try plans()
        let rig = Rig(plans: [.success(first)], at: ten)
        let gate = rig.client.holdPlans()
        let running = Task { await rig.model.scan() }
        await eventuallyOnMain { rig.model.phase == .scanning }
        let asked = Task { try await scan(rig).scan() }
        try? await Task.sleep(for: .milliseconds(100))
        gate.open()
        let plan = try await asked.value
        await running.value
        XCTAssertEqual(plan, first)
        XCTAssertEqual(rig.client.planCalls, 1, "the reminder did not start a scan of its own")
    }

    func testAScanThatRunsTooLongIsNotWaitedForForEver() async throws {
        let (first, _) = try plans()
        let rig = Rig(plans: [.success(first)], at: ten)
        let gate = rig.client.holdPlans()
        let running = Task { await rig.model.scan() }
        await eventuallyOnMain { rig.model.phase == .scanning }
        do {
            _ = try await scan(rig, waitLimit: 3).scan()
            XCTFail("it waited for ever")
        } catch let refusal as WeeklyScan.Refusal {
            XCTAssertEqual(refusal, .stillScanning)
        }
        gate.open()
        await running.value
    }

    func testTheCleaningTheCardAndAResultInAnOpenWindowAreNeverTakenAway() async throws {
        let (first, _) = try plans()
        // the confirmation card
        let card = Rig(plans: [.success(first)], at: ten)
        await card.model.scan()
        card.model.requestClean()
        for open in [true, false] {
            card.windowOpen = open
            await assertRefused(card, .screenInUse)
            XCTAssertNotNil(card.model.confirmation, "the card is still there")
        }

        // the done screen, while the window is open
        let done = Rig(plans: [.success(first)], at: ten)
        done.client.script(.replay([Events.done(deleted: 9, freed: gigabytes(8.4))], error: nil))
        await done.model.scan()
        done.model.requestClean()
        await done.model.confirmClean(try XCTUnwrap(done.model.confirmation))
        XCTAssertEqual(done.model.phase, .done)
        await assertRefused(done, .screenInUse)
        XCTAssertEqual(done.model.phase, .done)
        XCTAssertEqual(done.client.planCalls, 1)

        // the error screen, while the window is open
        let failed = Rig(plans: [.failure(.planFailed(status: 2, stderr: "no")), .success(first)], at: ten)
        await failed.model.scan()
        XCTAssertEqual(failed.model.phase, .failed)
        await assertRefused(failed, .screenInUse)
        XCTAssertEqual(failed.client.planCalls, 1)

        // a cleaning that runs, whatever the window
        let cleaning = Rig(plans: [.success(first)], at: ten)
        cleaning.client.script(.live)
        await cleaning.model.scan()
        cleaning.model.requestClean()
        let confirmation = try XCTUnwrap(cleaning.model.confirmation)
        let run = Task { await cleaning.model.confirmClean(confirmation) }
        _ = await cleaning.client.waitForApply()
        for open in [true, false] {
            cleaning.windowOpen = open
            await assertRefused(cleaning, .screenInUse)
        }
        XCTAssertEqual(cleaning.model.phase, .cleaning)
        XCTAssertEqual(cleaning.client.applyCalls.count, 1, "the reminder never starts a cleaning")
        cleaning.client.send(Events.done(deleted: 9, freed: gigabytes(8.4)))
        cleaning.client.finish()
        await run.value
    }

    func testAResultLeftInAClosedWindowWasDismissedAndIsScannedOver() async throws {
        let (first, second) = try plans()
        let rig = Rig(plans: [.success(first), .success(second)], at: ten)
        rig.client.script(.replay([Events.done(deleted: 9, freed: gigabytes(8.4))], error: nil))
        await rig.model.scan()
        rig.model.requestClean()
        await rig.model.confirmClean(try XCTUnwrap(rig.model.confirmation))
        rig.windowOpen = false
        let plan = try await scan(rig).scan()
        XCTAssertEqual(plan, second)
        XCTAssertEqual(rig.client.applyCalls.count, 1, "and still no second cleaning")
    }

    func testAScanThatFailsGivesNoPlan() async throws {
        let rig = Rig(plans: [.failure(.planFailed(status: 2, stderr: "no"))], at: ten)
        rig.windowOpen = false
        await assertRefused(rig, .noPlan)
    }

    private func assertRefused(_ rig: Rig, _ expected: WeeklyScan.Refusal, line: UInt = #line) async {
        do {
            _ = try await scan(rig).scan()
            XCTFail("it scanned", line: line)
        } catch let refusal as WeeklyScan.Refusal {
            XCTAssertEqual(refusal, expected, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }
}

// MARK: the way out

/// The weekly note is handed to macOS only when macOS lets cmm show it; the question is never put from here.
final class NotificationDeliveryTests: XCTestCase {
    private let note = WeeklyNotification(free: 19_800_000_000, canGo: 8_400_000_000)!

    func testOnlyAllowedNotesAreHandedOverAndNothingIsAsked() async {
        for (authorization, posted) in [(NotificationAuthorization.allowed, true), (.denied, false), (.notAsked, false)] {
            let permission = FakeNotificationPermission(authorization)
            let poster = RecordingPoster()
            let handed = await NotificationDelivery(permission: permission, poster: poster).deliver(note)
            XCTAssertEqual(handed, posted, "\(authorization)")
            XCTAssertEqual(poster.notes, posted ? [note] : [], "\(authorization)")
            XCTAssertEqual(permission.requestCalls, 0, "\(authorization): reading is not asking")
        }
    }

    func testTheNoteIsHandedOverAsItWasWritten() async {
        let poster = RecordingPoster()
        await NotificationDelivery(permission: FakeNotificationPermission(.allowed), poster: poster).deliver(note)
        let posted = poster.notes.first
        XCTAssertEqual(posted?.identifier, "cmm.weekly-reminder")
        XCTAssertEqual(posted?.title, "19.8 GB free")
        XCTAssertEqual(posted?.body, "8 GB can go.")
        XCTAssertEqual(posted?.level, .active)
    }
}

// MARK: the background services

/// The sampler and the Monday reminder as they run with the window closed (spec R6, R7): nothing until its switch is on; the
/// reminder looked at when cmm launches, when it is switched on, when its moment comes and every hour; a screen in use never
/// taken away and the check tried again ten minutes later; the note posted only when macOS shows it.
@MainActor
final class BackgroundServicesTests: XCTestCase {
    private let rome = TestCalendars.rome
    /// Monday 19 October 2026.
    private func monday(_ hour: Int, _ minute: Int = 0) -> Date { rome.local(2026, 10, 19, hour, minute) }
    private func wednesday(_ hour: Int, _ minute: Int = 0) -> Date { rome.local(2026, 10, 21, hour, minute) }

    private final class Rig {
        let clock: Locked<Date>
        let store: MemorySettingsStore
        let permission: FakeNotificationPermission
        let settings: SettingsModel
        let client: FakeCmmClient
        let model: AppModel
        let samplerScheduler = FakeActivityScheduler()
        let heartbeat = FakeActivityScheduler()
        let timer = FakeWallClock()
        let poster = RecordingPoster()
        let lines = Locked<[String]>([])
        var windowOpen = false
        var services: BackgroundServices!

        @MainActor
        init(at start: Date, calendar: Calendar, values: [SettingsKey: Any], notifications: NotificationAuthorization, answer: NotificationAuthorization) throws {
            let clock = Locked(start)
            self.clock = clock
            store = MemorySettingsStore(values)
            permission = FakeNotificationPermission(notifications, personAnswers: answer)
            settings = SettingsModel(settings: Settings(store: store), loginItem: FakeLoginItem(), notifications: permission)
            client = FakeCmmClient(plans: [.success(try TestPlans.fixture("plan-c.json"))])
            model = AppModel(client: client, now: { clock.withLock { $0 } })
            let lines = lines
            let log: @Sendable (String) -> Void = { line in lines.withLock { $0.append(line) } }
            let sampler = SamplerSchedule(client: client, scheduler: samplerScheduler, now: { clock.withLock { $0 } }, log: log)
            let watcher = AppModelWatcher(model: model, now: { clock.withLock { $0 } }, scanFinished: { _ in }, cleaningEnded: { _ in })
            watcher.start()
            let weekly = WeeklyScan(
                model: model, mainWindowOpen: { [unowned self] in self.windowOpen }, lastScanAt: { watcher.lastScanAt },
                now: { clock.withLock { $0 } }, pause: { _ in try? await Task.sleep(for: .milliseconds(5)) }
            )
            let delivery = NotificationDelivery(permission: permission, poster: poster)
            let reminder = WeeklyReminder(
                settings: settings, calendar: calendar, now: { clock.withLock { $0 } },
                scan: { try await weekly.scan() }, deliver: { await delivery.deliver($0) }, log: log
            )
            services = BackgroundServices(
                settings: settings, sampler: sampler, reminder: reminder, timer: timer, heartbeat: heartbeat, now: { clock.withLock { $0 } }
            )
        }

        func move(to date: Date) { clock.withLock { $0 = date } }
        var lastCheck: Date? { Settings(store: store).lastWeeklyDate }
    }

    private func rig(
        at start: Date, _ values: [SettingsKey: Any] = [:], notifications: NotificationAuthorization = .allowed,
        answer: NotificationAuthorization = .allowed
    ) throws -> Rig {
        try Rig(at: start, calendar: rome, values: values, notifications: notifications, answer: answer)
    }

    // MARK: off

    func testNothingRunsUntilItsSwitchIsOn() async throws {
        let rig = try rig(at: monday(10, 5))
        await rig.services.start()
        XCTAssertTrue(rig.samplerScheduler.activities.isEmpty)
        XCTAssertTrue(rig.heartbeat.activities.isEmpty)
        XCTAssertTrue(rig.timer.scheduled.isEmpty)
        XCTAssertEqual(rig.client.sampleCalls, 0)
        XCTAssertEqual(rig.client.planCalls, 0, "no scan")
        XCTAssertEqual(rig.permission.requestCalls, 0, "nothing asked")
        XCTAssertEqual(rig.poster.notes, [])
        await rig.services.cleaningEnded()
        XCTAssertEqual(rig.client.sampleCalls, 0, "a cleaning does not start the sampler")
    }

    // MARK: the sampler

    func testTheHistorySwitchStartsAndStopsTheSampler() async throws {
        let rig = try rig(at: wednesday(9), [.historyEnabled: true])
        await rig.services.start()
        XCTAssertEqual(rig.client.sampleCalls, 1, "a note at launch")
        let activity = try XCTUnwrap(rig.samplerScheduler.activities.last)
        XCTAssertEqual(activity.interval, 30 * 60)
        XCTAssertEqual(activity.tolerance, 10 * 60)

        rig.settings.historyEnabled = false
        await eventuallyOnMain { activity.isCancelled }
        XCTAssertTrue(activity.isCancelled)

        rig.settings.historyEnabled = true
        await eventuallyOnMain { rig.client.sampleCalls == 2 }
        XCTAssertEqual(rig.samplerScheduler.activities.count, 2, "turned on again: a new schedule and a note")
    }

    func testACleaningThatEndsAsksForOneMoreNote() async throws {
        let rig = try rig(at: wednesday(9), [.historyEnabled: true])
        await rig.services.start()
        await rig.services.cleaningEnded()
        XCTAssertEqual(rig.client.sampleCalls, 2)
    }

    // MARK: the reminder

    func testOnMondayAfterTenALaunchScansWithTheWindowAndPostsTheNote() async throws {
        let rig = try rig(at: monday(10, 5), [.weeklyReminderEnabled: true])
        await rig.services.start()
        XCTAssertEqual(rig.client.planCalls, 1, "the window's own scan")
        XCTAssertEqual(rig.model.phase, .ready, "the window has the numbers the note gives")
        XCTAssertEqual(rig.poster.notes.map(\.title), ["19.8 GB free"])
        XCTAssertEqual(rig.poster.notes.map(\.body), ["8 GB can go."])
        XCTAssertEqual(rig.lastCheck, monday(10, 5), "the week is written down")
        XCTAssertEqual(rig.timer.pending, [rome.local(2026, 10, 26, 10, 0)], "and the next look is next Monday at ten")
        XCTAssertEqual(rig.heartbeat.activities.last?.interval, 60 * 60, "an hourly heartbeat while the reminder is on")
        XCTAssertEqual(rig.permission.requestCalls, 0)
    }

    func testOnAnotherDayItOnlySetsTheTimerAndTheTimerChecksOnMonday() async throws {
        let rig = try rig(at: wednesday(15), [.weeklyReminderEnabled: true])
        await rig.services.start()
        XCTAssertEqual(rig.client.planCalls, 0)
        let monday = rome.local(2026, 10, 26, 10, 0)
        XCTAssertEqual(rig.timer.pending, [monday])

        rig.move(to: monday)
        rig.timer.fire()
        await eventuallyOnMain { rig.poster.notes.count == 1 }
        XCTAssertEqual(rig.client.planCalls, 1)
        await eventuallyOnMain { rig.timer.pending == [self.rome.local(2026, 11, 2, 10, 0)] }
        XCTAssertEqual(rig.timer.pending, [rome.local(2026, 11, 2, 10, 0)])
    }

    func testAScreenInUseIsNeverTakenAwayAndTheCheckIsTriedAgainTenMinutesLater() async throws {
        let rig = try rig(at: monday(9, 50), [.weeklyReminderEnabled: true])
        // the person cleaned at 09:50 and is looking at the result when ten o'clock comes
        rig.client.script(.replay([Events.done(deleted: 9, freed: gigabytes(8.4))], error: nil))
        await rig.model.scan()
        rig.model.requestClean()
        await rig.model.confirmClean(try XCTUnwrap(rig.model.confirmation))
        rig.windowOpen = true
        rig.move(to: monday(10))
        await rig.services.start()
        XCTAssertEqual(rig.services.lastOutcome, .scanFailed)
        XCTAssertEqual(rig.model.phase, .done, "the result stays on the screen")
        XCTAssertEqual(rig.poster.notes, [])
        XCTAssertNil(rig.lastCheck, "nothing written down")
        XCTAssertEqual(rig.timer.pending, [monday(10, 10)], "tried again in ten minutes")
        XCTAssertTrue(rig.lines.withLock { $0 }.contains { $0.hasPrefix("No weekly reminder") })

        // the person closed the window: the result was left behind, and the next try scans
        rig.windowOpen = false
        rig.move(to: monday(10, 10))
        rig.timer.fire()
        await eventuallyOnMain { rig.poster.notes.count == 1 }
        XCTAssertEqual(rig.lastCheck, monday(10, 10))
        XCTAssertEqual(rig.client.applyCalls.count, 1, "and the reminder never cleaned")
    }

    func testAfterTheDayItWaitsForNextWeek() async throws {
        let rig = try rig(at: monday(23, 55), [.weeklyReminderEnabled: true])
        rig.client.script(.live)
        await rig.model.scan()
        rig.model.requestClean()  // the card is up: the screen is in use
        await rig.services.start()
        XCTAssertEqual(rig.timer.pending, [rome.local(2026, 10, 20, 0, 5)])
        rig.move(to: rome.local(2026, 10, 20, 0, 5))
        rig.timer.fire()
        await eventuallyOnMain { rig.timer.pending == [self.rome.local(2026, 10, 26, 10, 0)] }
        XCTAssertEqual(rig.services.lastOutcome, .notDue(until: rome.local(2026, 10, 26, 10, 0)), "Monday is over: next week")
        XCTAssertEqual(rig.poster.notes, [])
    }

    func testTurningTheSwitchOnLooksOnceMacOSHasAnswered() async throws {
        let rig = try rig(at: monday(11), [:], notifications: .notAsked, answer: .allowed)
        await rig.services.start()
        XCTAssertEqual(rig.client.planCalls, 0)
        let gate = rig.permission.holdTheQuestion()
        let turning = Task { await rig.settings.setWeeklyReminder(true) }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.client.planCalls, 0, "not while macOS's question is on the screen")
        gate.open()
        await turning.value
        await eventuallyOnMain { rig.poster.notes.count == 1 }
        XCTAssertEqual(rig.poster.notes.count, 1, "Monday after ten, once macOS said yes")
        XCTAssertEqual(rig.permission.requestCalls, 1, "asked once, by the switch")
    }

    func testWithNotificationsOffNothingIsPostedAndNothingIsAskedAgain() async throws {
        let rig = try rig(at: monday(10, 5), [.weeklyReminderEnabled: true], notifications: .denied)
        await rig.services.start()
        XCTAssertTrue(rig.settings.reminderIsSilenced, "Settings says so")
        await rig.heartbeat.fire()
        XCTAssertEqual(rig.poster.notes, [], "macOS would not show it, so it is not handed over")
        XCTAssertEqual(rig.permission.requestCalls, 0)
    }

    func testChangingTheWeekdayOrTimeLooksAgain() async throws {
        let rig = try rig(at: wednesday(10), [.weeklyReminderEnabled: true])
        await rig.services.start()
        XCTAssertEqual(rig.poster.notes, [])
        rig.settings.weeklySchedule = WeeklySchedule(weekday: 4, hour: 9, minute: 0)  // Wednesdays at nine: this morning
        await eventuallyOnMain { rig.poster.notes.count == 1 }
        XCTAssertEqual(rig.poster.notes.count, 1, "the same day's moment has passed: it is caught up")
        rig.settings.weeklySchedule = WeeklySchedule(weekday: 6, hour: 9, minute: 0)  // Fridays
        let friday = rome.local(2026, 10, 23, 9, 0)
        await eventuallyOnMain { rig.timer.pending.first.map { $0 >= friday } ?? false }
        XCTAssertEqual(rig.poster.notes.count, 1, "never two in a week")
    }

    func testSwitchingTheReminderOffStopsTheTimerAndTheHeartbeat() async throws {
        let rig = try rig(at: wednesday(10), [.weeklyReminderEnabled: true])
        await rig.services.start()
        let beat = try XCTUnwrap(rig.heartbeat.activities.last)
        await rig.settings.setWeeklyReminder(false)
        await eventuallyOnMain { beat.isCancelled && rig.timer.pending.isEmpty }
        XCTAssertTrue(beat.isCancelled)
        XCTAssertEqual(rig.timer.pending, [])
        XCTAssertFalse(rig.services.heartbeatRunning)
    }

    func testTheHeartbeatLooksAndSetsTheTimerAgain() async throws {
        let rig = try rig(at: wednesday(10), [.weeklyReminderEnabled: true])
        await rig.services.start()
        let scheduled = rig.timer.scheduled.count
        await rig.heartbeat.fire()
        XCTAssertEqual(rig.services.lastOutcome, .notDue(until: rome.local(2026, 10, 26, 10, 0)))
        XCTAssertGreaterThan(rig.timer.scheduled.count, scheduled)
        XCTAssertEqual(rig.timer.pending.count, 1, "one timer set at a time")
    }
}
