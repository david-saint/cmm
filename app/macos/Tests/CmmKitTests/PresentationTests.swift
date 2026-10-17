import XCTest
@testable import CmmKit

/// The cleaning, done, empty and confirmation screens as values, with the numbers of the C boards.
final class PresentationTests: XCTestCase {
    private let home = "/Users/test"
    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    // MARK: building a run like the board's

    /// Nine items confirmed (all of the safe ones), in the plan's order.
    private func queue() throws -> [PlanItem] {
        let plan = try TestPlans.fixture("plan-c.json")
        return plan.items.filter { $0.tier == .safe }
    }

    private func item(_ path: String, in queue: [PlanItem]) throws -> PlanItem {
        try XCTUnwrap(queue.first { $0.path == path }, path)
    }

    private func event(_ item: PlanItem, _ status: ItemStatus, reason: String = "") -> ItemEvent {
        ItemEvent(
            rule: item.rule, group: item.group, path: item.path, status: status, reason: reason,
            bytes: item.bytes, freedBytes: status == .deleted ? item.bytes : 0
        )
    }

    /// The board's moment: 5 of 9 reported, 3.1 GB freed, 2.3 GB still to go, Go build cache being removed.
    private func boardProgress() throws -> CleanProgress {
        let queue = try queue()
        var progress = CleanProgress(
            expected: 9, queue: queue, selectedBytes: gb(8.4), reviewHeld: gb(9), startFree: gb(19.8)
        )
        progress.selected = 9
        progress.items = [
            event(try item("/Users/test/lane-builds/lane-a/node_modules", in: queue), .deleted),
            event(try item("/Users/test/lane-builds/lane-a/ios/Pods", in: queue), .deleted),
            event(try item("/Users/test/lane-builds/lane-b/node_modules", in: queue), .deleted),
            event(try item("/Users/test/lane-builds/lane-c/node_modules", in: queue), .failed, reason: "permission denied"),
            event(try item("/Users/test/.cache/uv", in: queue), .skipped, reason: "uv is running"),
        ]
        return progress
    }

    // MARK: cleaning

    func testTheCleaningScreenOfTheBoard() throws {
        let c = CleaningPresentation(progress: try boardProgress(), capacity: gb(228), home: home)
        XCTAssertEqual(c.label, "Cleaning · 5 of 9 · each item is checked again right before it goes")
        XCTAssertEqual(c.number, SizeText.Parts(value: "3.1", unit: "GB"))
        XCTAssertEqual(c.sentence, "freed so far.")
        XCTAssertEqual(c.fraction, 5.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(c.stopTitle, "Stop")
        XCTAssertTrue(c.stopEnabled)
    }

    func testTheBoardsFiveRowsNewestFirstAndFading() throws {
        let rows = CleaningPresentation(progress: try boardProgress(), capacity: gb(228), home: home).rows
        XCTAssertEqual(rows.map(\.word), ["Removing", "Skipped", "Failed", "Deleted", "Deleted"])
        XCTAssertEqual(rows.map(\.path), [
            "~/Library/Caches/go-build", "~/.cache/uv", "~/lane-builds/lane-c/node_modules",
            "~/lane-builds/lane-b/node_modules", "~/lane-builds/lane-a/ios/Pods",
        ])
        XCTAssertEqual(rows.map(\.reason), [nil, "uv is running", "permission denied", nil, nil])
        XCTAssertEqual(rows.map(\.sizeText), ["1.2 GB", "2.5 GB", "0.5 GB", "0.8 GB", "0.9 GB"])
        XCTAssertEqual(rows.map(\.opacity), [1.0, 0.9, 0.78, 0.5, 0.3])
        XCTAssertEqual(rows.map(\.kind), [.removing, .skipped, .failed, .deleted, .deleted])
    }

    func testTheBoardsBandAndCaption() throws {
        let c = CleaningPresentation(progress: try boardProgress(), capacity: gb(228), home: home)
        let band = try XCTUnwrap(c.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .selected, .freed, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gb(193.8), gb(9), gb(2.3), gb(3.1), gb(19.8)])
        XCTAssertEqual(c.caption.trailingText, "22.9 GB free now · 2.3 GB still to go")
        XCTAssertEqual(c.bandSentence, "Disk 228 GB: 22.9 GB free, 2.3 GB still to go")
    }

    func testStillToGoIsWhatWasSelectedMinusEverythingReportedWhateverItsStatus() throws {
        // 8.4 selected - (3.1 deleted + 2.5 skipped + 0.5 failed) = 2.3: skipped and failed bytes are not "to go".
        let progress = try boardProgress()
        XCTAssertEqual(progress.toGoBytes, gb(2.3))
        XCTAssertEqual(progress.freedBytes, gb(3.1))
        XCTAssertEqual(progress.freeNow, gb(22.9))
    }

    func testTheInFlightItemIsTheFirstConfirmedOneNotYetReported() throws {
        let queue = try queue()
        var progress = CleanProgress(expected: 9, queue: queue, selectedBytes: gb(8.4), startFree: gb(19.8))
        XCTAssertEqual(progress.inFlight?.path, queue[0].path)

        progress.items = [event(queue[0], .deleted)]
        XCTAssertEqual(progress.inFlight?.path, queue[1].path)

        progress.items = queue.map { event($0, .deleted) }
        XCTAssertNil(progress.inFlight, "everything is reported: nothing is being removed")
    }

    func testBeforeAnyReportTheFirstItemIsBeingRemoved() throws {
        let progress = CleanProgress(expected: 9, queue: try queue(), selectedBytes: gb(8.4), reviewHeld: 0, startFree: gb(19.8))
        let c = CleaningPresentation(progress: progress, capacity: gb(228), home: home)
        XCTAssertEqual(c.label, "Cleaning · 0 of 9 · each item is checked again right before it goes")
        XCTAssertEqual(c.number.text, "0 GB")
        XCTAssertEqual(c.fraction, 0)
        XCTAssertEqual(c.rows.map(\.word), ["Removing"])
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now · 8.4 GB still to go")
    }

    func testWhenEverythingIsReportedNothingIsBeingRemoved() throws {
        var progress = try boardProgress()
        let queue = try queue()
        progress.items = queue.map { event($0, .deleted) }
        let c = CleaningPresentation(progress: progress, capacity: gb(228), home: home)
        XCTAssertFalse(c.rows.contains { $0.kind == .removing })
        XCTAssertEqual(c.label, "Cleaning · 9 of 9 · each item is checked again right before it goes")
        XCTAssertEqual(c.caption.trailingText, "28.2 GB free now")
    }

    func testStoppingSaysSoAndDisablesStop() throws {
        var progress = try boardProgress()
        progress.stopRequested = true
        let c = CleaningPresentation(progress: progress, capacity: gb(228), home: home)
        XCTAssertEqual(c.label, "Stopping after the current item · 5 of 9")
        XCTAssertEqual(c.stopTitle, "Stopping…")
        XCTAssertFalse(c.stopEnabled)
    }

    func testAReportForAPathThatWasNotConfirmedStillShows() throws {
        var progress = try boardProgress()
        progress.items.append(ItemEvent(rule: "", group: "", path: "/Users/test/elsewhere", status: .skipped,
                                        reason: "not in the current plan", bytes: 0, freedBytes: 0))
        let c = CleaningPresentation(progress: progress, capacity: gb(228), home: home)
        XCTAssertEqual(c.rows[1].path, "~/elsewhere")
        XCTAssertEqual(c.rows[1].reason, "not in the current plan")
        XCTAssertGreaterThanOrEqual(progress.toGoBytes, 0)
    }

    func testToGoNeverGoesNegative() throws {
        var progress = CleanProgress(expected: 1, queue: [], selectedBytes: 100, startFree: 0)
        progress.items = [ItemEvent(rule: "", group: "", path: "/x", status: .deleted, reason: "", bytes: 5_000, freedBytes: 5_000)]
        XCTAssertEqual(progress.toGoBytes, 0)
    }

    func testACommandItemIsShownByItsLabel() throws {
        let queue = try queue()
        let brew = try item("homebrew: cleanup", in: queue)
        var progress = CleanProgress(expected: 1, queue: [brew], selectedBytes: brew.bytes, startFree: gb(19.8))
        progress.items = [event(brew, .deleted)]
        let c = CleaningPresentation(progress: progress, capacity: nil, home: home)
        XCTAssertEqual(c.rows.first?.path, "homebrew: cleanup")
        XCTAssertNil(c.band, "no capacity, no band")
        XCTAssertEqual(c.caption.leading, nil)
    }

    func testOnlyTheFiveLatestRowsAreShown() throws {
        var progress = try boardProgress()
        progress.items = try queue().map { event($0, .deleted) } + [event(try item("homebrew: cleanup", in: try queue()), .deleted)]
        let c = CleaningPresentation(progress: progress, capacity: gb(228), home: home)
        XCTAssertEqual(c.rows.count, 5)
    }

    // MARK: done

    private func boardSummary(stopped: Bool = false, problems: Bool = true, finishedAt: Date = Date(timeIntervalSince1970: 1_792_065_780)) throws -> CleanSummary {
        let queue = try queue()
        var items = queue.filter { $0.path != "/Users/test/.cache/uv" && $0.path != "/Users/test/lane-builds/lane-c/node_modules" }
            .prefix(7).map { event($0, .deleted) }
        if problems {
            items.append(event(try item("/Users/test/.cache/uv", in: queue), .skipped, reason: "uv was running"))
            items.append(event(try item("/Users/test/lane-builds/lane-c/node_modules", in: queue), .failed, reason: "permission denied"))
        }
        let done = DoneEvent(
            deleted: 7, skipped: problems ? 1 : 0, failed: problems ? 1 : 0, freedBytes: gb(5.4), freeBefore: gb(19.8), freeAfter: gb(25.2),
            stopped: stopped, warnings: [], log: "/Users/test/.local/state/cmm/cleanup.log"
        )
        return CleanSummary(done: done, items: Array(items), unreadableLines: 0, reviewHeld: gb(9), finishedAt: finishedAt)
    }

    /// 2026-10-15 14:03 in Europe/Berlin, which is what the board says; "now" is the same afternoon.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    private var finished: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 14, minute: 3))! }
    private var later: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 30))! }

    private func done(_ summary: CleanSummary, now: Date? = nil) -> DonePresentation {
        DonePresentation(summary: summary, capacity: gb(228), volumeName: "Macintosh HD", home: home,
                         now: now ?? later, calendar: calendar, locale: locale)
    }

    func testTheDoneScreenOfTheBoard() throws {
        let d = done(try boardSummary(finishedAt: finished))
        XCTAssertEqual(d.label, "Done · Macintosh HD · today at 14:03")
        XCTAssertEqual(d.number, SizeText.Parts(value: "25.2", unit: "GB"))
        XCTAssertEqual(d.sentence, "free now.")
        XCTAssertEqual(d.comparison.map(\.text).joined(), "Up from 19.8 GB. 5.4 GB freed.")
        XCTAssertEqual(d.comparison.filter(\.emphasized).map(\.text), ["5.4 GB freed."])
        XCTAssertEqual(d.deletedText, "7 deleted")
        XCTAssertEqual(d.skippedText, "1 skipped")
        XCTAssertEqual(d.failedText, "1 failed")
    }

    func testTheBoardsTwoIssueLinesAndTheLog() throws {
        let d = done(try boardSummary(finishedAt: finished))
        XCTAssertEqual(d.issues.map(\.path), ["~/.cache/uv", "~/lane-builds/lane-c/node_modules"])
        XCTAssertEqual(d.issues.map(\.message), [
            "skipped, uv was running · offered again next scan",
            "failed, permission denied",
        ])
        XCTAssertEqual(d.issues.map(\.revealPath), [nil, "/Users/test/lane-builds/lane-c/node_modules"],
                       "only a failure offers Show in Finder, as in the board")
        XCTAssertEqual(d.log?.path, "~/.local/state/cmm/cleanup.log")
        XCTAssertEqual(d.log?.revealPath, "/Users/test/.local/state/cmm/cleanup.log")
    }

    func testTheBoardsDoneBand() throws {
        let d = done(try boardSummary(finishedAt: finished))
        let band = try XCTUnwrap(d.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .freed, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gb(193.8), gb(9), gb(5.4), gb(19.8)])
        XCTAssertEqual(d.caption.trailingText, "19.8 GB → 25.2 GB free")
        XCTAssertEqual(d.bandSentence, "Disk 228 GB: 25.2 GB free, 5.4 GB freed")
    }

    func testTheNumbersAreCmmsOwnNotTheAppsOwn() throws {
        // What the clean really did differs from what was planned: the screen says what cmm reported.
        var summary = try boardSummary(finishedAt: finished)
        summary = CleanSummary(
            done: DoneEvent(deleted: 7, skipped: 0, failed: 0, freedBytes: gb(3.0), freeBefore: gb(19.8), freeAfter: gb(22.5),
                            stopped: false, warnings: [], log: nil),
            items: summary.items, unreadableLines: 0, reviewHeld: gb(9), finishedAt: finished
        )
        let d = done(summary)
        XCTAssertEqual(d.number.text, "22.5 GB", "free now is cmm's free_after, not free_before + freed")
        XCTAssertEqual(d.comparison.map(\.text).joined(), "Up from 19.8 GB. 3.0 GB freed.")
        XCTAssertNil(d.log, "no log line when nothing was logged")
    }

    func testACleanWithoutProblemsHasNoIssueLines() throws {
        let d = done(try boardSummary(problems: false, finishedAt: finished))
        XCTAssertTrue(d.issues.isEmpty)
        XCTAssertEqual(d.skippedText, "0 skipped")
    }

    func testAStoppedRunSaysSo() throws {
        let d = done(try boardSummary(stopped: true, finishedAt: finished))
        XCTAssertEqual(d.label, "Stopped · Macintosh HD · today at 14:03")
        XCTAssertTrue(d.notes.contains("Stopped early. Items after the one in progress were not touched."))
    }

    func testNothingFreedIsNotWrittenAsZeroGB() throws {
        let summary = CleanSummary(
            done: DoneEvent(deleted: 0, skipped: 1, failed: 0, freedBytes: 0, freeBefore: gb(19.8), freeAfter: gb(19.8),
                            stopped: false, warnings: [], log: nil),
            items: [], unreadableLines: 0, reviewHeld: 0, finishedAt: finished
        )
        XCTAssertEqual(done(summary).comparison.map(\.text).joined(), "Up from 19.8 GB. Nothing freed.")
    }

    func testWarningsAndUnreadableLinesAreCarried() throws {
        let summary = CleanSummary(
            done: DoneEvent(deleted: 1, skipped: 0, failed: 0, freedBytes: gb(1), freeBefore: gb(19.8), freeAfter: gb(20.8),
                            stopped: false, warnings: ["could not write the cleanup log: permission denied"], log: nil),
            items: [], unreadableLines: 2, reviewHeld: 0, finishedAt: finished
        )
        let d = done(summary)
        XCTAssertEqual(d.warnings, ["could not write the cleanup log: permission denied"])
        XCTAssertTrue(d.notes.contains("2 lines of cmm's output could not be read; the figures above are cmm's own."))
    }

    func testWhenTheCleanFinishedIsSaidPlainly() {
        XCTAssertEqual(FinishedAt.text(finished, now: later, calendar: calendar, locale: locale), "today at 14:03")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: later)!
        XCTAssertEqual(FinishedAt.text(finished, now: tomorrow, calendar: calendar, locale: locale), "yesterday at 14:03")
        let later2 = calendar.date(byAdding: .day, value: 5, to: later)!
        XCTAssertEqual(FinishedAt.text(finished, now: later2, calendar: calendar, locale: locale), "15 Oct at 14:03")
    }

    // MARK: nothing to clean

    func testTheEmptyScreenOfTheBoard() throws {
        let json = #"""
        {"schema_version":1,"generated_at":"2026-10-15T15:29:40+02:00",
         "host":{"volume":"/System/Volumes/Data","free_bytes":28200000000,"capacity_bytes":228000000000},
         "items":[],"skipped":[{"rule":"uv-cache","reason":"uv cache (Python packages; downloads again on demand): uv is running"}],
         "total_bytes":0}
        """#
        let plan = try Plan.parse(Data(json.utf8))
        let e = EmptyPresentation(plan: plan, volumeName: "Macintosh HD", now: later, calendar: calendar)
        XCTAssertEqual(e.label, "Macintosh HD · scanned just now")
        XCTAssertEqual(e.number, SizeText.Parts(value: "28.2", unit: "GB"))
        XCTAssertEqual(e.sentence, "free. Nothing to clean today.")
        XCTAssertEqual(e.heldSentence, "The uv cache was held back because uv is running. cmm looks again on the next scan.")
        let band = try XCTUnwrap(e.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gb(199.8), gb(28.2)])
        XCTAssertEqual(e.caption.trailingText, "28.2 GB free")
        XCTAssertEqual(e.bandSentence, "Disk 228 GB: 28.2 GB free")
    }

    func testNoCapacityNoBandAndAnUnnamedVolumeLeavesTheNameOut() throws {
        let plan = try Plan.parse(Fixture.data("plan-empty.json"))  // scanned 10:05, two skips, no capacity
        let e = EmptyPresentation(plan: plan, volumeName: "", now: later, calendar: calendar)
        XCTAssertNil(e.band)
        XCTAssertEqual(e.label, "Scanned 5 hours ago")
        XCTAssertEqual(e.heldSentence, "2 things were held back: Go build cache and Homebrew old versions. cmm looks again on the next scan.")
        XCTAssertEqual(e.caption.trailingText, "31.2 GB free")
        XCTAssertNil(e.caption.leading)
    }

    func testNothingHeldBackNoSentence() throws {
        let plan = TestPlans.plan([], freeBytes: gb(28.2), capacityBytes: gb(228))
        XCTAssertNil(EmptyPresentation(plan: plan, volumeName: "Macintosh HD", now: later, calendar: calendar).heldSentence)
    }

    func testHowLongAgoTheScanWas() {
        func age(_ seconds: Double) -> String { RelativeAge.text(since: later.addingTimeInterval(-seconds), now: later, calendar: calendar) }
        XCTAssertEqual(age(10), "just now")
        XCTAssertEqual(age(59), "just now")
        XCTAssertEqual(age(60), "1 min ago")
        XCTAssertEqual(age(5 * 60 + 20), "5 min ago")
        XCTAssertEqual(age(59 * 60), "59 min ago")
        XCTAssertEqual(age(60 * 60), "1 hour ago")
        XCTAssertEqual(age(3 * 3600 + 100), "3 hours ago")
        XCTAssertEqual(age(26 * 3600), "yesterday")
        XCTAssertEqual(age(4 * 86_400), "4 days ago")
        XCTAssertEqual(RelativeAge.text(since: nil, now: later, calendar: calendar), "just now", "no timestamp: the scan is the one just made")
        XCTAssertEqual(age(-30), "just now", "a clock that runs backwards does not say 'in the future'")
    }

    // MARK: the confirmation card

    func testTheConfirmationCardOfTheBoard() throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let selection = SelectionModel(plan: plan)
        let confirmation = CleanConfirmation(selection: selection.applySelection, generation: 1, freeBefore: plan.host.freeBytes)
        XCTAssertEqual(confirmation.prompt, "Delete 9 items (8.4 GB)?")
        XCTAssertEqual(confirmation.detail, "Each item is checked again right before it is removed.")
        XCTAssertEqual(confirmation.afterText, "Free space afterwards: about 28.2 GB.")
        XCTAssertEqual(confirmation.cancelTitle, "Cancel")
        XCTAssertEqual(confirmation.deleteTitle, "Delete 9 Items")
        XCTAssertEqual(confirmation.accessibilityLabel, "Delete 9 items, 8.4 GB")
    }

    func testOneItemIsSaidInTheSingularOnTheCard() throws {
        let plan = try TestPlans.fixture("plan-c.json")
        var selection = SelectionModel(plan: plan)
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.rule == "uv-cache" }?.items.first))
        let confirmation = CleanConfirmation(selection: selection.applySelection, generation: 1, freeBefore: plan.host.freeBytes)
        XCTAssertEqual(confirmation.prompt, "Delete 1 item (2.5 GB)?")
        XCTAssertEqual(confirmation.deleteTitle, "Delete 1 Item")
    }

    func testWithoutAKnownFreeSpaceThereIsNoPromiseAboutAfterwards() throws {
        let confirmation = CleanConfirmation(selection: ApplySelection(unchecked: ["/a"], bytes: 1), generation: 1)
        XCTAssertNil(confirmation.afterText)
    }
}
