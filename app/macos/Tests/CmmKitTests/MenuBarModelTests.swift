import XCTest
@testable import CmmKit

/// Waits that a test ends by hand: each one is written down with how long it was asked to be, and lasts until the test wakes it.
/// Whatever is still asleep when the test ends is woken, so nothing is left waiting.
final class HandHeldSleeps: @unchecked Sendable {
    private let sleepers = Locked<[(seconds: TimeInterval, wake: CheckedContinuation<Void, Never>)]>([])
    private let asked = Locked<[TimeInterval]>([])

    /// Every wait asked for, in order.
    var requested: [TimeInterval] { asked.withLock { $0 } }
    var asleep: Int { sleepers.withLock { $0.count } }

    func sleep(_ seconds: TimeInterval) async {
        asked.withLock { $0.append(seconds) }
        await withCheckedContinuation { continuation in
            sleepers.withLock { $0.append((seconds, continuation)) }
        }
    }

    /// Wakes everyone who is asleep.
    func wakeAll() {
        let woken = sleepers.withLock { all -> [CheckedContinuation<Void, Never>] in
            defer { all = [] }
            return all.map(\.wake)
        }
        for continuation in woken { continuation.resume() }
    }
}

/// The menu bar item's memory and what it shows (spec R5): what the window's scans and cleanings, the free-space notes and the
/// history tell it, and the two moments it changes of its own accord.
@MainActor
final class MenuBarModelTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    /// Thursday 15 October 2026, 11:00 in Rome.
    private var eleven: Date { rome.local(2026, 10, 15, 11, 0) }

    private final class Rig {
        let clock: Locked<Date>
        let sleeps = HandHeldSleeps()
        let model: MenuBarModel

        @MainActor
        init(at start: Date, calendar: Calendar) {
            let clock = Locked(start)
            let sleeps = sleeps
            self.clock = clock
            model = MenuBarModel(now: { clock.withLock { $0 } }, calendar: calendar, sleep: { await sleeps.sleep($0) })
        }

        func move(to date: Date) { clock.withLock { $0 = date } }
    }

    private func rig(at start: Date? = nil) -> Rig {
        let rig = Rig(at: start ?? eleven, calendar: rome)
        addTeardownBlock { rig.sleeps.wakeAll() }
        return rig
    }

    private func show(_ rig: Rig, phase: AppModel.Phase = .ready, card: Bool = false) -> MenuBarPresentation {
        rig.model.presentation(phase: phase, confirmationOpen: card, volumeName: { _ in "Macintosh HD" }, calendar: rome, locale: british)
    }

    private func summary(freed: Int64, before: Int64 = gigabytes(19.8), at: Date) -> CleanSummary {
        CleanSummary(
            done: DoneEvent(
                deleted: 3, skipped: 0, failed: 0, freedBytes: freed, freedInsideBytes: 0, freeBefore: before, freeAfter: before + freed,
                stopped: false, warnings: [], log: nil
            ),
            items: [], unreadableLines: 0, reviewHeld: 0, finishedAt: at
        )
    }

    // MARK: what it is told

    func testTheWindowsScanIsWhatThePopoverShows() throws {
        let rig = rig()
        let plan = try TestPlans.fixture("plan-c.json")
        rig.model.recordScan(plan)
        let shown = show(rig)
        XCTAssertEqual(shown.state, .ready(canGo: gigabytes(8.4), free: 19_800_000_000))
        XCTAssertEqual(shown.popover.header.text, "Macintosh HD \u{00B7} 19.8 GB free")
        XCTAssertEqual(shown.popover.groups.count, 3)
        XCTAssertEqual(shown.item.title, "19.8 GB")
        XCTAssertEqual(rig.model.volume, plan.host.volume, "the volume the header names is the plan's")
    }

    func testTheHeaderNamesTheVolumeCmmNamedOrTheStartupVolume() throws {
        let rig = rig()
        var asked: [String] = []
        _ = rig.model.presentation(phase: .idle, confirmationOpen: false, volumeName: { asked.append($0); return "" }, calendar: rome, locale: british)
        XCTAssertEqual(asked, [MenuBarModel.defaultVolume], "nothing has named a volume: the one cmm reads")
        rig.model.recordScan(TestPlans.plan([TestPlans.item("/Volumes/Work/x", bytes: gigabytes(3))], freeBytes: gigabytes(40), volume: "/Volumes/Work"))
        _ = rig.model.presentation(phase: .ready, confirmationOpen: false, volumeName: { asked.append($0); return "Work" }, calendar: rome, locale: british)
        XCTAssertEqual(asked.last, "/Volumes/Work")
    }

    func testAFreeSpaceNoteMovesTheNumberInTheMenuBar() throws {
        let rig = rig()
        rig.model.recordScan(try TestPlans.fixture("plan-c.json"))
        rig.move(to: eleven.addingTimeInterval(600))
        rig.model.recordSample(SampleResult(recorded: true, t: nil, freeBytes: gigabytes(21), capacityBytes: nil), receivedAt: eleven.addingTimeInterval(600))
        XCTAssertEqual(show(rig).item.title, "21.0 GB")
    }

    func testAHistoryReportGivesTheLastCleanedRowAndNamesTheVolume() throws {
        let rig = rig()
        var json = HistoryJSON()
        json.generatedAt = "2026-10-15T08:59:00Z"
        json.runs = [HistoryJSON.run(finished: "2026-10-13T12:06:00Z", freed: gigabytes(5.4))]
        rig.model.recordHistory(try json.report())
        XCTAssertEqual(show(rig, phase: .idle).popover.historyRow?.text, "Last cleaned Tue \u{00B7} 5.4 GB")
        XCTAssertEqual(rig.model.volume, "/System/Volumes/Data")
    }

    // MARK: the moments it changes of its own accord

    func testJustCleanedLastsAnHourAndThenThePopoverChangesWithoutAnythingHappening() async throws {
        let rig = rig(at: eleven.addingTimeInterval(-300))
        rig.model.recordScan(try TestPlans.fixture("plan-c.json"))
        rig.move(to: eleven)
        rig.model.recordCleaning(summary(freed: gigabytes(5.4), at: eleven))
        guard case .justCleaned(let freed, _) = show(rig).state else { return XCTFail("\(show(rig).state)") }
        XCTAssertEqual(freed, gigabytes(5.4))
        await eventuallyOnMain { rig.sleeps.requested.last == 3_600 }
        XCTAssertEqual(rig.sleeps.requested.last, 3_600, "it waits for the end of the hour (midnight is later)")

        let tick = rig.model.tick
        rig.move(to: eleven.addingTimeInterval(3_600))
        rig.sleeps.wakeAll()
        await eventuallyOnMain { rig.model.tick != tick }
        XCTAssertEqual(rig.model.tick, tick + 1, "the views draw the presentation again")
        XCTAssertEqual(show(rig).state, .unknown, "the scan is older than the cleaning: nothing says what can go now")
        await eventuallyOnMain { rig.sleeps.asleep == 1 }
        XCTAssertEqual(rig.sleeps.requested.last, 12 * 3_600, "and then it waits for midnight")
    }

    func testMidnightIsAMomentTooBecauseLastCleanedTueBecomesADate() async throws {
        let rig = rig(at: rome.local(2026, 10, 15, 23, 30))
        rig.model.recordScan(try TestPlans.fixture("plan-c.json"))
        await eventuallyOnMain { !rig.sleeps.requested.isEmpty }
        XCTAssertEqual(rig.sleeps.requested, [1_800])
    }

    func testANewRecordDoesNotStackUpWaits() async throws {
        let rig = rig()
        let plan = try TestPlans.fixture("plan-c.json")
        rig.model.recordScan(plan)
        rig.model.recordScan(plan)
        rig.model.recordSample(SampleResult(recorded: true, t: nil, freeBytes: gigabytes(20), capacityBytes: nil), receivedAt: eleven)
        await eventuallyOnMain { rig.sleeps.asleep == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.sleeps.asleep, 1, "one wait for the one next moment")
    }

    // MARK: the popover's Scan

    func testThePopoversScanFollowsTheWindowsRuleAndNeverTakesAScreenInUse() throws {
        let rig = rig()
        rig.model.recordScan(try TestPlans.fixture("plan-c.json"))
        for phase in [AppModel.Phase.idle, .scanning, .ready, .empty, .cleaning, .done, .failed] {
            for card in [false, true] {
                for open in [false, true] {
                    let popover = show(rig, phase: phase, card: card).popover
                    let enabled = MenuBarModel.scanEnabled(popover, phase: phase, confirmationOpen: card, mainWindowOpen: open)
                    let expected: Bool
                    switch phase {
                    case .scanning, .cleaning: expected = false
                    case .done, .failed: expected = !card && !open
                    default: expected = !card
                    }
                    XCTAssertEqual(enabled, expected, "\(phase), card \(card), window open \(open)")
                }
            }
        }
    }
}

/// Following the window's model without a view: a finished scan and an ended cleaning are each reported once.
@MainActor
final class AppModelWatcherTests: XCTestCase {
    private final class Heard {
        var plans: [Plan] = []
        var cleanings: [CleanSummary?] = []
    }

    private let received = Date(timeIntervalSince1970: 2_000_000_000)

    private func watcher(_ model: AppModel, _ heard: Heard) -> AppModelWatcher {
        let received = received
        let watcher = AppModelWatcher(
            model: model, now: { received },
            scanFinished: { heard.plans.append($0) }, cleaningEnded: { heard.cleanings.append($0) }
        )
        watcher.start()
        addTeardownBlock { @MainActor in watcher.stop() }
        return watcher
    }

    func testAScanIsReportedOnceWithItsPlanAndItsTime() async throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let model = AppModel(client: FakeCmmClient(plan: plan))
        let heard = Heard()
        let watcher = watcher(model, heard)
        XCTAssertNil(watcher.lastScanAt)
        await model.scan()
        await eventuallyOnMain { heard.plans.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard.plans, [plan])
        XCTAssertEqual(watcher.lastScanAt, min(try XCTUnwrap(plan.generatedAt), received), "the earlier of cmm's time and the app's")
        XCTAssertEqual(heard.cleanings.count, 0)
    }

    func testEveryScanThatMakesANewPlanIsReported() async throws {
        let first = TestPlans.plan([TestPlans.item("/Users/test/a", bytes: gigabytes(3))], freeBytes: gigabytes(20))
        let second = TestPlans.plan([TestPlans.item("/Users/test/b", bytes: gigabytes(4))], freeBytes: gigabytes(21))
        let model = AppModel(client: FakeCmmClient(plans: [.success(first), .success(second)]))
        let heard = Heard()
        _ = watcher(model, heard)
        await model.scan()
        await eventuallyOnMain { heard.plans.count == 1 }
        await model.scan()
        await eventuallyOnMain { heard.plans.count == 2 }
        XCTAssertEqual(heard.plans, [first, second])
    }

    func testAScanThatFailsIsNotAFinishedScan() async throws {
        let model = AppModel(client: FakeCmmClient(plans: [.failure(.planFailed(status: 2, stderr: "no"))]))
        let heard = Heard()
        _ = watcher(model, heard)
        await model.scan()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(heard.plans, [])
        XCTAssertEqual(heard.cleanings.count, 0, "a failed scan is not a cleaning either")
    }

    func testAScanThatFinishedBeforeTheWatcherStartedIsReportedAtOnce() async throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let model = AppModel(client: FakeCmmClient(plan: plan))
        await model.scan()
        let heard = Heard()
        _ = watcher(model, heard)
        XCTAssertEqual(heard.plans, [plan])
    }

    func testACleaningThatEndsIsReportedWithItsSummaryAndOneThatFailsWithout() async throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.done(deleted: 9, freed: gigabytes(8.4))], error: nil))
        let model = AppModel(client: fake)
        let heard = Heard()
        _ = watcher(model, heard)
        await model.scan()
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        await eventuallyOnMain { heard.cleanings.count == 1 }
        XCTAssertEqual(heard.cleanings.first??.done.freedBytes, gigabytes(8.4))

        fake.script(.replay([], error: .applyFailed(status: 1, stderr: "cmm: the volume went away")))
        await model.scan()
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        await eventuallyOnMain { heard.cleanings.count == 2 }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(heard.cleanings.last ?? nil, "a cleaning that failed has no summary, and is still a cleaning that ended")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard.cleanings.count, 2, "each was reported once")
    }

    func testAStoppedWatcherHearsNothing() async throws {
        let model = AppModel(client: FakeCmmClient(plan: try TestPlans.fixture("plan-c.json")))
        let heard = Heard()
        let watcher = watcher(model, heard)
        watcher.stop()
        await model.scan()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(heard.plans, [])
    }
}
