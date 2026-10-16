import XCTest
@testable import CmmKit

/// The menu bar item and its popover (spec R5 and the boards `C-MenuBar-States` and `C-MenuBar-Dark`): which state it is in,
/// what each state writes, and what it knows between one look and the next. The popover never offers a cleaning.
@MainActor
final class MenuBarStateTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    /// Thursday 15 October 2026, 11:00 in Rome.
    private var now: Date { rome.local(2026, 10, 15, 11, 0) }
    private var fiveMinutesAgo: Date { now.addingTimeInterval(-300) }

    // MARK: building a moment

    private func boardPlan() throws -> Plan { try TestPlans.fixture("plan-c.json") }

    /// A plan with `free` free, safe things worth `safe` and Docker's worth `docker`, on a 228 GB disk.
    private func plan(free: Int64, safe: [Int64], docker: Int64 = 0, extra: [PlanItem] = []) -> Plan {
        var items = safe.enumerated().map { offset, bytes in
            TestPlans.item("/Users/test/safe\(offset)", group: "Group \(offset)", rule: "r\(offset)", bytes: bytes)
        }
        if docker > 0 {
            items.append(TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: docker, tier: .review, action: .command, freesInside: "Docker's disk image"))
        }
        return TestPlans.plan(items + extra, freeBytes: free, capacityBytes: 228_000_000_000)
    }

    private func summary(freed: Int64, before: Int64 = 19_800_000_000, at: Date? = nil) -> CleanSummary {
        CleanSummary(
            done: DoneEvent(
                deleted: 3, skipped: 0, failed: 0, freedBytes: freed, freedInsideBytes: 0, freeBefore: before, freeAfter: before + freed,
                stopped: false, warnings: [], log: nil
            ),
            items: [], unreadableLines: 0, reviewHeld: 0, finishedAt: at ?? now
        )
    }

    private func scanned(_ plan: Plan, at: Date? = nil) -> MenuBarContext {
        var context = MenuBarContext()
        context.recordScan(plan: plan, at: at ?? fiveMinutesAgo)
        return context
    }

    private func presentation(
        _ context: MenuBarContext, phase: AppModel.Phase = .ready, confirmationOpen: Bool = false, at: Date? = nil
    ) -> MenuBarPresentation {
        context.presentation(
            phase: phase, confirmationOpen: confirmationOpen, volumeName: "Macintosh HD", now: at ?? now, calendar: rome, locale: british
        )
    }

    // MARK: what the last scan keeps

    func testTheLastScanKeepsWhatTheBoardsPopoverShows() throws {
        let scan = LastScan(plan: try boardPlan(), scannedAt: fiveMinutesAgo)
        XCTAssertEqual(scan.canGo, gigabytes(8.4), "the safe items: Docker's 9.0 GB is a review item and never counts")
        XCTAssertEqual(scan.free, 19_800_000_000)
        XCTAssertEqual(scan.capacity, 228_000_000_000)
        XCTAssertEqual(scan.reviewBytes, gigabytes(9.0))
        XCTAssertEqual(scan.groups.map(\.title), ["Idle lane dependencies", "uv cache", "Go build cache"])
        XCTAssertEqual(scan.groups.map(\.sizeText), ["3.6 GB", "2.5 GB", "1.2 GB"])
        XCTAssertEqual(scan.groups.map(\.bytes), [gigabytes(3.6), gigabytes(2.5), gigabytes(1.2)])
    }

    func testTheScanIsDatedByCmmAndNeverLaterThanWhenTheAppGotIt() throws {
        // the board's plan says 14:00 in Rome, which is 12:00 UTC: three hours after `now`
        XCTAssertEqual(LastScan(plan: try boardPlan(), scannedAt: now).at, now, "cmm's clock is ahead of ours: ours")
        XCTAssertEqual(LastScan(plan: try boardPlan(), scannedAt: TestTime.utc("2026-10-15T13:00:00Z")).at, TestTime.utc("2026-10-15T12:00:00Z"), "cmm's word")
        let undated = TestPlans.plan([], freeBytes: 5)
        XCTAssertEqual(LastScan(plan: undated, scannedAt: now).at, now, "no date from cmm: when the app got it")
    }

    func testOnlySafeItemsThatFreeTheDiskCanGo() {
        let plan = TestPlans.plan([
            TestPlans.item("/a", group: "A", rule: "a", bytes: gigabytes(1)),
            TestPlans.item("/b", group: "B", rule: "b", bytes: gigabytes(2), tier: .review),
            TestPlans.item("/c", group: "C", rule: "c", bytes: gigabytes(4), tier: .manual),
            TestPlans.item("/d", group: "D", rule: "d", bytes: gigabytes(8), tier: .other("experimental")),
            // a safe item whose space is freed inside another program's storage is not space the disk gets
            TestPlans.item("x: prune", group: "X", rule: "x", bytes: gigabytes(16), action: .command, freesInside: "X's disk image"),
        ], freeBytes: 20_000_000_000)
        let scan = LastScan(plan: plan, scannedAt: now)
        XCTAssertEqual(scan.canGo, gigabytes(1))
        XCTAssertEqual(scan.groups.map(\.title), ["A"])
        XCTAssertEqual(scan.reviewBytes, gigabytes(2))
    }

    func testTheListHasThreeGroupsAtMostLargestFirstAndNamesSameSizedOnesInOrder() {
        let plan = TestPlans.plan([
            TestPlans.item("/e", group: "Echo", rule: "e", bytes: 5), TestPlans.item("/a", group: "Alpha", rule: "a", bytes: 5),
            TestPlans.item("/d", group: "Delta", rule: "d", bytes: 9), TestPlans.item("/c", group: "Charlie", rule: "c", bytes: 7),
            TestPlans.item("/b", group: "Bravo", rule: "b", bytes: 5),
        ])
        XCTAssertEqual(LastScan(plan: plan, scannedAt: now).groups.map(\.title), ["Delta", "Charlie", "Alpha"])
    }

    func testAGroupTheCatalogKnowsIsNamedByTheCatalog() throws {
        let scan = LastScan(plan: try boardPlan(), scannedAt: now)
        XCTAssertEqual(scan.groups.first?.title, "Idle lane dependencies", "not the plan's long label with its parenthesis")
    }

    // MARK: which state

    func testReady() throws {
        let context = scanned(try boardPlan())
        XCTAssertEqual(context.state(phase: .ready, now: now), .ready(canGo: gigabytes(8.4), free: 19_800_000_000))
    }

    func testNothingToCleanWhenNothingSafeCanGo() throws {
        XCTAssertEqual(scanned(plan(free: 28_400_000_000, safe: [])).state(phase: .empty, now: now), .nothingToClean(free: 28_400_000_000))
        // only Docker's: for a look, never for "can go"
        XCTAssertEqual(
            scanned(plan(free: 28_400_000_000, safe: [], docker: gigabytes(9))).state(phase: .ready, now: now),
            .nothingToClean(free: 28_400_000_000)
        )
        let onlyManual = TestPlans.plan([TestPlans.item("/c", bytes: gigabytes(4), tier: .manual)], freeBytes: 28_400_000_000)
        XCTAssertEqual(scanned(onlyManual).state(phase: .ready, now: now), .nothingToClean(free: 28_400_000_000))
    }

    func testLowIsUnderTenGigabytesAndTenExactlyIsNot() {
        let safe = [gigabytes(12.3)]
        XCTAssertEqual(scanned(plan(free: 9_999_999_999, safe: safe)).state(phase: .ready, now: now), .low(free: 9_999_999_999, canGo: gigabytes(12.3)))
        XCTAssertEqual(scanned(plan(free: 10_000_000_000, safe: safe)).state(phase: .ready, now: now), .ready(canGo: gigabytes(12.3), free: 10_000_000_000))
        XCTAssertEqual(MenuBarState.lowBelowBytes, 10_000_000_000)
    }

    func testLowBeatsReadyAndNothingToCleanAndWorksWithNothingToGo() {
        XCTAssertEqual(scanned(plan(free: 8_100_000_000, safe: [])).state(phase: .ready, now: now), .low(free: 8_100_000_000, canGo: 0))
        // Between 10 and 15 GB nothing changes here: only the Monday reminder starts to speak
        XCTAssertEqual(scanned(plan(free: 14_900_000_000, safe: [gigabytes(1)])).state(phase: .ready, now: now), .ready(canGo: gigabytes(1), free: 14_900_000_000))
    }

    func testWorkingStatesComeFromThePhaseWhateverIsRemembered() throws {
        let context = scanned(try boardPlan())
        XCTAssertEqual(context.state(phase: .scanning, now: now), .scanning)
        XCTAssertEqual(context.state(phase: .cleaning, now: now), .cleaning)
        XCTAssertEqual(MenuBarContext().state(phase: .scanning, now: now), .scanning, "even before there is anything to remember")
    }

    func testWithoutAScanItIsUnknownAndEveryOtherPhaseUsesWhatWasScanned() throws {
        XCTAssertEqual(MenuBarContext().state(phase: .idle, now: now), .unknown)
        XCTAssertEqual(MenuBarContext().state(phase: .failed, now: now), .unknown)
        let context = scanned(try boardPlan())
        for phase in [AppModel.Phase.idle, .ready, .empty, .done, .failed] {
            XCTAssertEqual(context.state(phase: phase, now: now), .ready(canGo: gigabytes(8.4), free: 19_800_000_000), "\(phase)")
        }
    }

    // MARK: just cleaned

    func testJustCleanedLastsAnHourAndThenTheDefaultReturns() throws {
        var context = scanned(try boardPlan(), at: now.addingTimeInterval(-3 * 3_600))
        context.recordCleaning(summary(freed: gigabytes(5.4), at: now))
        XCTAssertEqual(context.state(phase: .done, now: now), .justCleaned(freed: gigabytes(5.4), free: gigabytes(25.2)))
        XCTAssertEqual(context.state(phase: .done, now: now.addingTimeInterval(3_599)), .justCleaned(freed: gigabytes(5.4), free: gigabytes(25.2)))
        XCTAssertNotEqual(context.state(phase: .done, now: now.addingTimeInterval(3_600)), .justCleaned(freed: gigabytes(5.4), free: gigabytes(25.2)), "an hour is over")
        XCTAssertEqual(MenuBarState.justCleanedFor, 3_600)
    }

    func testJustCleanedBeatsLowAndReady() throws {
        var low = scanned(plan(free: 8_100_000_000, safe: [gigabytes(12.3)]), at: now.addingTimeInterval(-3_600))
        low.recordCleaning(summary(freed: gigabytes(2), before: 6_000_000_000, at: now))
        XCTAssertEqual(low.state(phase: .done, now: now), .justCleaned(freed: gigabytes(2), free: gigabytes(8)), "still low, and the item's dot says so")
    }

    func testAfterTheHourWithNoNewScanTheOldNumbersAreNotTrueAnymoreSoItIsUnknown() throws {
        var context = scanned(try boardPlan(), at: now.addingTimeInterval(-7_200))
        context.recordCleaning(summary(freed: gigabytes(5.4), at: now.addingTimeInterval(-3_600)))
        XCTAssertEqual(
            context.state(phase: .done, now: now), .unknown,
            "8.4 GB 'can go' was cleaned an hour ago: nothing says what can go now until the next scan"
        )
    }

    func testAfterTheHourWithANewerScanTheDefaultReturnsFromIt() throws {
        var context = scanned(try boardPlan(), at: now.addingTimeInterval(-7_200))
        context.recordCleaning(summary(freed: gigabytes(5.4), at: now.addingTimeInterval(-3_700)))
        context.recordScan(plan: plan(free: 25_200_000_000, safe: [gigabytes(1)]), at: now.addingTimeInterval(-3_650))
        XCTAssertEqual(context.state(phase: .ready, now: now), .ready(canGo: gigabytes(1), free: 25_200_000_000))
    }

    func testAScanAfterTheCleaningDoesNotEndJustCleanedEarly() throws {
        var context = MenuBarContext()
        context.recordCleaning(summary(freed: gigabytes(5.4), at: now.addingTimeInterval(-600)))
        context.recordScan(plan: plan(free: 25_200_000_000, safe: [gigabytes(1)]), at: now.addingTimeInterval(-300))
        XCTAssertEqual(context.state(phase: .ready, now: now), .justCleaned(freed: gigabytes(5.4), free: 25_200_000_000))
    }

    func testACleaningThatFreedNothingOnTheDiskIsNotJustCleanedAndDoesNotAgeTheScan() throws {
        // Docker's prune: nothing came back to the disk
        var context = scanned(try boardPlan())
        context.recordCleaning(summary(freed: 0, at: now))
        XCTAssertNil(context.cleaning)
        XCTAssertEqual(context.state(phase: .done, now: now), .ready(canGo: gigabytes(8.4), free: 19_800_000_000))
    }

    func testACleaningDatedAfterNowIsNotJustCleaned() throws {
        var context = scanned(try boardPlan())
        context.recordCleaning(summary(freed: gigabytes(5.4), at: now.addingTimeInterval(60)))
        XCTAssertEqual(context.state(phase: .done, now: now), .unknown, "the clock is wrong somewhere: it says nothing rather than something false")
    }

    func testTheNewestCleaningIsTheOneKept() {
        var context = MenuBarContext()
        context.recordCleaning(summary(freed: gigabytes(1), at: now.addingTimeInterval(-100)))
        context.recordCleaning(summary(freed: gigabytes(2), at: now.addingTimeInterval(-300)))
        XCTAssertEqual(context.cleaning?.freedBytes, gigabytes(1), "an older one does not replace it")
        context.recordCleaning(summary(freed: gigabytes(3), at: now.addingTimeInterval(-50)))
        XCTAssertEqual(context.cleaning?.freedBytes, gigabytes(3))
    }

    // MARK: how much is free: the freshest word

    func testTheFreshestReadingWinsWhoeverSaidIt() throws {
        var context = scanned(try boardPlan(), at: now.addingTimeInterval(-600))
        XCTAssertEqual(context.reading?.bytes, 19_800_000_000)
        // a note taken after the scan
        context.recordSample(SampleResult(recorded: true, t: now.addingTimeInterval(-60), freeBytes: 18_000_000_000, capacityBytes: 228_000_000_000), receivedAt: now)
        XCTAssertEqual(context.reading?.bytes, 18_000_000_000)
        XCTAssertEqual(context.state(phase: .ready, now: now), .ready(canGo: gigabytes(8.4), free: 18_000_000_000), "the number in the title is today's")
        // an older note does not take its place
        context.recordSample(SampleResult(recorded: false, t: now.addingTimeInterval(-900), freeBytes: 30_000_000_000, capacityBytes: nil), receivedAt: now)
        XCTAssertEqual(context.reading?.bytes, 18_000_000_000)
        // and a scan after that does
        context.recordScan(plan: plan(free: 17_000_000_000, safe: [gigabytes(1)]), at: now.addingTimeInterval(-10))
        XCTAssertEqual(context.reading?.bytes, 17_000_000_000)
    }

    func testASampleWithoutATimeIsDatedWhenTheAppGotIt() {
        var context = MenuBarContext()
        context.recordSample(SampleResult(recorded: false, t: nil, freeBytes: 7, capacityBytes: nil), receivedAt: now)
        XCTAssertEqual(context.reading, FreeReading(bytes: 7, capacity: nil, at: now))
    }

    func testTwoReadingsAtTheSameMomentTakeTheLaterToArrive() throws {
        var context = scanned(try boardPlan(), at: now)
        context.recordSample(SampleResult(recorded: true, t: now, freeBytes: 11_000_000_000, capacityBytes: nil), receivedAt: now)
        XCTAssertEqual(context.reading?.bytes, 11_000_000_000)
    }

    func testTheDiskNowOfAHistoryReportIsAReadingAndItsNewestCleaningIsRemembered() throws {
        var json = HistoryJSON()
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":24000000000,"capacity_bytes":228000000000}"#
        json.generatedAt = TestTime.iso(now.addingTimeInterval(-30))
        json.runs = [
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-3 * 86_400)), freed: 0, inside: gigabytes(9)),
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-4 * 86_400)), freed: gigabytes(5.4), before: gigabytes(19.8)),
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-9 * 86_400)), freed: gigabytes(2.2)),
        ]
        var context = MenuBarContext()
        context.recordHistory(try json.report(), now: now)
        XCTAssertEqual(context.reading, FreeReading(bytes: 24_000_000_000, capacity: 228_000_000_000, at: now.addingTimeInterval(-30)))
        XCTAssertEqual(context.cleaning, CleaningRecord.newest(in: try json.report(), now: now))
        XCTAssertEqual(context.cleaning?.freedBytes, gigabytes(5.4), "the Docker-only run, newer, is skipped")
        XCTAssertEqual(context.cleaning?.freeAfter, gigabytes(25.2))
        XCTAssertEqual(context.cleaning?.finishedAt, now.addingTimeInterval(-4 * 86_400))
    }

    func testAHistoryThatCannotSayHowMuchIsFreeSaysNothingAboutIt() throws {
        var json = HistoryJSON()
        json.host = #"{"volume":"","free_bytes":0}"#
        var context = MenuBarContext()
        context.recordHistory(try json.report(), now: now)
        XCTAssertNil(context.reading, "unknown is not an empty disk")
        XCTAssertNil(context.cleaning)
    }

    func testAnOlderCleaningInTheHistoryDoesNotReplaceANewerOneAlreadyKnown() throws {
        var context = MenuBarContext()
        context.recordCleaning(summary(freed: gigabytes(7), at: now.addingTimeInterval(-60)))
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-86_400)), freed: gigabytes(1))]
        context.recordHistory(try json.report(), now: now)
        XCTAssertEqual(context.cleaning?.freedBytes, gigabytes(7))
    }

    func testACleaningRecordIsMadeOnlyOfACleaningThatGaveSomethingBack() {
        XCTAssertNil(CleaningRecord(summary: summary(freed: 0)))
        let record = CleaningRecord(summary: summary(freed: gigabytes(5.4), before: gigabytes(19.8), at: now))
        XCTAssertEqual(record?.freeAfter, gigabytes(25.2))
        XCTAssertEqual(record?.finishedAt, now)
    }

    // MARK: the item

    func testTheItemSaysTheFreeSpaceAndAnAmberDotUnderTenGigabytes() throws {
        let normal = presentation(scanned(try boardPlan())).item
        XCTAssertEqual(normal, MenuBarItem(title: "19.8 GB", isLow: false, accessibilityLabel: "19.8 GB free"))

        let low = presentation(scanned(plan(free: 8_100_000_000, safe: [gigabytes(12.3)]))).item
        XCTAssertEqual(low, MenuBarItem(title: "8.1 GB", isLow: true, accessibilityLabel: "8.1 GB free, low on space"))
    }

    func testTheItemKeepsItsNumberWhileItWorksAndHasNoneUntilSomethingSaidIt() throws {
        XCTAssertEqual(presentation(scanned(try boardPlan()), phase: .scanning).item.title, "19.8 GB")
        XCTAssertEqual(presentation(scanned(try boardPlan()), phase: .cleaning).item.title, "19.8 GB")
        let empty = presentation(MenuBarContext(), phase: .idle).item
        XCTAssertEqual(empty, MenuBarItem(title: nil, isLow: false, accessibilityLabel: "cmm"))
    }

    func testTheItemIsLowAfterACleaningThatLeftTheDiskLow() throws {
        var context = scanned(plan(free: 4_000_000_000, safe: [gigabytes(3)]), at: now.addingTimeInterval(-7_200))
        context.recordCleaning(summary(freed: gigabytes(2), before: 4_000_000_000, at: now.addingTimeInterval(-60)))
        let item = presentation(context, phase: .done).item
        XCTAssertEqual(item.title, "6.0 GB")
        XCTAssertTrue(item.isLow)
    }

    // MARK: the popover, state by state (the board)

    private func lastCleanedTuesday(_ context: inout MenuBarContext) {
        // Tuesday 13 October, 14:06 in Rome
        context.recordCleaning(summary(freed: gigabytes(5.4), at: rome.local(2026, 10, 13, 14, 6)))
    }

    func testDefault() throws {
        var context = scanned(try boardPlan())
        lastCleanedTuesday(&context)
        let popover = presentation(context).popover

        XCTAssertEqual(popover.header, MenuBarPopover.Header(lead: nil, detail: "Macintosh HD \u{00B7} 19.8 GB free"))
        XCTAssertEqual(popover.number, SizeText.Parts(value: "8.4", unit: "GB"))
        XCTAssertEqual(popover.sentence, "can go.")
        XCTAssertNil(popover.note)
        XCTAssertEqual(popover.groups.map(\.title), ["Idle lane dependencies", "uv cache", "Go build cache"])
        XCTAssertEqual(popover.groups.map(\.sizeText), ["3.6 GB", "2.5 GB", "1.2 GB"])
        XCTAssertEqual(popover.historyRow?.text, "Last cleaned Tue \u{00B7} 5.4 GB")
        XCTAssertEqual(popover.scanTitle, "Scan")
        XCTAssertTrue(popover.canScan)
        XCTAssertFalse(popover.isBusy)
        XCTAssertEqual(popover.spoken, "8.4 GB can go. 19.8 GB free.")
        // the band of the board: used, Docker's dotted slice, what can go, what is free
        let band = try XCTUnwrap(popover.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .selected, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gigabytes(190.8), gigabytes(9), gigabytes(8.4), gigabytes(19.8)])
    }

    func testNothingToClean() throws {
        var context = scanned(plan(free: 28_400_000_000, safe: []))
        lastCleanedTuesday(&context)
        let popover = presentation(context, phase: .empty).popover

        XCTAssertEqual(popover.header.text, "Macintosh HD")
        XCTAssertEqual(popover.number, SizeText.Parts(value: "28.4", unit: "GB"))
        XCTAssertEqual(popover.sentence, "free. Nothing to clean.")
        XCTAssertEqual(popover.groups, [])
        XCTAssertEqual(popover.historyRow?.text, "Last cleaned Tue \u{00B7} 5.4 GB")
        XCTAssertEqual(popover.spoken, "28.4 GB free. Nothing to clean.")
        let band = try XCTUnwrap(popover.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gigabytes(199.6), gigabytes(28.4)])
    }

    func testLowOnSpace() throws {
        var context = scanned(plan(free: 8_100_000_000, safe: [gigabytes(6.1), gigabytes(3.4), gigabytes(1.6), gigabytes(1.2)], docker: gigabytes(9)))
        context.recordCleaning(summary(freed: gigabytes(5.4), at: rome.local(2026, 10, 7, 9, 0)))
        // the scan came after the cleaning, so what it says still holds
        context.recordScan(plan: plan(free: 8_100_000_000, safe: [gigabytes(6.1), gigabytes(3.4), gigabytes(1.6), gigabytes(1.2)], docker: gigabytes(9)), at: fiveMinutesAgo)
        let popover = presentation(context).popover

        XCTAssertEqual(popover.header, MenuBarPopover.Header(lead: "Low on space", detail: "8.1 GB free"))
        XCTAssertEqual(popover.header.text, "Low on space \u{00B7} 8.1 GB free")
        XCTAssertEqual(popover.number, SizeText.Parts(value: "12.3", unit: "GB"))
        XCTAssertEqual(popover.sentence, "can go.")
        XCTAssertEqual(popover.groups.map(\.sizeText), ["6.1 GB", "3.4 GB", "1.6 GB"])
        XCTAssertEqual(popover.historyRow?.text, "Last cleaned 7 Oct \u{00B7} 5.4 GB", "eight days ago: a date, not a weekday")
        XCTAssertEqual(popover.spoken, "Low on space. 12.3 GB can go. 8.1 GB free.")
    }

    func testLowOnSpaceWithNothingToGoSaysSoInsteadOfZero() throws {
        let popover = presentation(scanned(plan(free: 8_100_000_000, safe: []))).popover
        XCTAssertEqual(popover.header.lead, "Low on space")
        XCTAssertEqual(popover.number, SizeText.Parts(value: "8.1", unit: "GB"))
        XCTAssertEqual(popover.sentence, "free. Nothing to clean.")
        XCTAssertEqual(popover.spoken, "Low on space. 8.1 GB free. Nothing to clean.")
    }

    func testScanning() throws {
        var context = scanned(try boardPlan())
        lastCleanedTuesday(&context)
        let popover = presentation(context, phase: .scanning).popover

        XCTAssertEqual(popover.header.text, "Macintosh HD \u{00B7} 19.8 GB free")
        XCTAssertNil(popover.number)
        XCTAssertEqual(popover.sentence, "Checking what can go\u{2026}")
        XCTAssertEqual(popover.note, "Only looks. Nothing is removed from here.")
        XCTAssertEqual(popover.groups, [], "the list comes back with the scan")
        XCTAssertEqual(popover.scanTitle, "Scanning\u{2026}")
        XCTAssertFalse(popover.canScan)
        XCTAssertTrue(popover.isBusy)
        XCTAssertEqual(popover.historyRow?.text, "Last cleaned Tue \u{00B7} 5.4 GB")
        XCTAssertEqual(popover.spoken, "Checking what can go. Only looks. Nothing is removed from here.")
        XCTAssertEqual(try XCTUnwrap(popover.band).segments.map(\.kind), [.used, .free])
    }

    func testJustCleaned() throws {
        var context = scanned(try boardPlan(), at: now.addingTimeInterval(-7_200))
        let finished = now.addingTimeInterval(-60)
        context.recordCleaning(summary(freed: gigabytes(5.4), before: 19_800_000_000, at: finished))
        let shown = presentation(context, phase: .done)
        let popover = shown.popover

        XCTAssertEqual(popover.header.text, "Macintosh HD \u{00B7} 25.2 GB free")
        XCTAssertEqual(popover.number, SizeText.Parts(value: "5.4", unit: "GB"))
        XCTAssertEqual(popover.sentence, "freed just now.")
        XCTAssertEqual(popover.groups, [])
        XCTAssertEqual(popover.historyRow?.text, "See it in History")
        XCTAssertEqual(popover.spoken, "Freed 5.4 GB. 25.2 GB free.")
        XCTAssertEqual(shown.changesAt, finished.addingTimeInterval(3_600), "the moment it goes back to what it was")
        // the board's band: used, what was freed (outlined), what was free before
        let band = try XCTUnwrap(popover.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .freed, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gigabytes(202.8), gigabytes(5.4), gigabytes(19.8)])
    }

    func testCleaningAndUnknown() throws {
        let cleaning = presentation(scanned(try boardPlan()), phase: .cleaning).popover
        XCTAssertEqual(cleaning.sentence, "Cleaning\u{2026}")
        XCTAssertNil(cleaning.number)
        XCTAssertFalse(cleaning.canScan)
        XCTAssertTrue(cleaning.isBusy)
        XCTAssertEqual(cleaning.scanTitle, "Scan")
        XCTAssertEqual(cleaning.spoken, "Cleaning.")

        let unknown = presentation(MenuBarContext(), phase: .idle).popover
        XCTAssertEqual(unknown.sentence, "Scan to see what can go.")
        XCTAssertNil(unknown.number)
        XCTAssertNil(unknown.band)
        XCTAssertEqual(unknown.header.text, "Macintosh HD")
        XCTAssertTrue(unknown.canScan)
        XCTAssertFalse(unknown.isBusy)
        XCTAssertNil(unknown.historyRow)
        XCTAssertEqual(unknown.spoken, "Scan to see what can go.")
    }

    func testTheVolumeNameIsLeftOutWhenThereIsNone() throws {
        let popover = scanned(try boardPlan()).presentation(
            phase: .ready, confirmationOpen: false, volumeName: "", now: now, calendar: rome, locale: british
        ).popover
        XCTAssertEqual(popover.header.text, "19.8 GB free")
    }

    // MARK: Scan is the window's scan

    func testScanIsOfferedExactlyWhenTheWindowOffersRescan() throws {
        let context = scanned(try boardPlan())
        for phase in [AppModel.Phase.idle, .ready, .empty, .done, .failed] {
            XCTAssertTrue(presentation(context, phase: phase).popover.canScan, "\(phase)")
            XCTAssertFalse(presentation(context, phase: phase, confirmationOpen: true).popover.canScan, "\(phase) with the card open: ⌘R is off, so is this")
        }
        for phase in [AppModel.Phase.scanning, .cleaning] {
            XCTAssertFalse(presentation(context, phase: phase).popover.canScan, "\(phase)")
        }
    }

    // MARK: the row that says when it was last cleaned

    private func lastCleaned(ago days: Int, hour: Int = 14, freed: Int64 = gigabytes(5.4), now at: Date? = nil) throws -> String? {
        var context = scanned(try boardPlan(), at: (at ?? now).addingTimeInterval(-60))
        let moment = rome.date(byAdding: .day, value: -days, to: rome.local(2026, 10, 15, hour, 6))!
        context.recordCleaning(summary(freed: freed, at: moment))
        return presentation(context, at: at).popover.historyRow?.text
    }

    func testTheRowSaysTheWeekdayWithinAWeekAndTheDateAfter() throws {
        // Thursday 15 October at 11:00 is `now`
        XCTAssertEqual(try lastCleaned(ago: 0, hour: 9), "Last cleaned Thu \u{00B7} 5.4 GB", "earlier today")
        XCTAssertEqual(try lastCleaned(ago: 1), "Last cleaned Wed \u{00B7} 5.4 GB")
        XCTAssertEqual(try lastCleaned(ago: 2), "Last cleaned Tue \u{00B7} 5.4 GB")
        XCTAssertEqual(try lastCleaned(ago: 6), "Last cleaned Fri \u{00B7} 5.4 GB", "the last day that cannot be taken for today's weekday")
        XCTAssertEqual(try lastCleaned(ago: 7), "Last cleaned 8 Oct \u{00B7} 5.4 GB", "seven days ago is Thursday again: a date")
        XCTAssertEqual(try lastCleaned(ago: 30), "Last cleaned 15 Sep \u{00B7} 5.4 GB")
    }

    func testTheRowSaysTheYearWhenItWasMoreThanAYearAgo() throws {
        var context = scanned(try boardPlan())
        context.recordCleaning(summary(freed: gigabytes(5.4), at: rome.local(2025, 10, 14, 14, 6)))
        XCTAssertEqual(presentation(context).popover.historyRow?.text, "Last cleaned 14 Oct 2025 \u{00B7} 5.4 GB")
    }

    func testTheRowIsAboutTheNewestCleaningThatGaveBackSomethingNotADockerOnlyRun() throws {
        var context = scanned(try boardPlan())
        context.recordCleaning(summary(freed: gigabytes(2.2), at: rome.local(2026, 10, 13, 9, 0)))
        context.recordCleaning(summary(freed: 0, at: rome.local(2026, 10, 14, 9, 0)))
        XCTAssertEqual(presentation(context).popover.historyRow?.text, "Last cleaned Tue \u{00B7} 2.2 GB")
        XCTAssertNil(presentation(scanned(try boardPlan())).popover.historyRow, "never cleaned: no row")
    }

    // MARK: when it says something else by itself

    func testOnlyJustCleanedChangesByItself() throws {
        XCTAssertNil(presentation(scanned(try boardPlan())).changesAt)
        XCTAssertNil(presentation(scanned(try boardPlan()), phase: .scanning).changesAt)
        XCTAssertNil(presentation(MenuBarContext(), phase: .idle).changesAt)
    }

    // MARK: with the real model

    func testItFollowsTheWindowsOwnScan() async throws {
        let moment = now
        let model = AppModel(client: FakeCmmClient(plan: try boardPlan()), now: { moment })
        var context = MenuBarContext()
        XCTAssertEqual(context.state(phase: model.phase, now: now), .unknown)
        await model.scan()
        context.recordScan(plan: try XCTUnwrap(model.plan), at: now)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(context.state(phase: model.phase, now: now), .ready(canGo: gigabytes(8.4), free: 19_800_000_000))
        XCTAssertEqual(context.state(phase: model.phase, now: now), .ready(canGo: model.selection!.plannedBytes, free: model.plan!.host.freeBytes), "the same number the window calls safe to remove")
    }

    // MARK: what the popover can ask for

    func testThePopoverCannotAskForACleaning() {
        XCTAssertEqual(MenuBarAction.allCases.map(\.rawValue), ["scan", "openWindow", "openHistory", "openSettings", "quit"])
        XCTAssertFalse(MenuBarAction.allCases.map { $0.rawValue.lowercased() }.contains { $0.contains("clean") || $0.contains("delete") || $0.contains("remove") })
    }
}
