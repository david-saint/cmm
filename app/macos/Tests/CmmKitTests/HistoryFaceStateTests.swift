import XCTest
@testable import CmmKit

/// What the History face keeps while it is open: which cleanings are open to their items.
@MainActor
final class HistoryFaceStateTests: XCTestCase {
    func testItOpensAtRest() {
        let state = HistoryFaceState()
        XCTAssertTrue(state.expanded.isEmpty)
    }

    func testToggleOpensAClosedCleaningAndClosesAnOpenOne() {
        let state = HistoryFaceState()
        state.toggle("a")
        XCTAssertEqual(state.expanded, ["a"])
        state.toggle("b")
        XCTAssertEqual(state.expanded, ["a", "b"], "opening one leaves the others as they are")
        state.toggle("a")
        XCTAssertEqual(state.expanded, ["b"])
    }

    func testSetExpandedSaysWhereItEnds() {
        let state = HistoryFaceState(expanded: ["a"])
        state.setExpanded("a", true)
        XCTAssertEqual(state.expanded, ["a"], "opening an open one keeps it open")
        state.setExpanded("a", false)
        state.setExpanded("a", false)
        XCTAssertEqual(state.expanded, [])
    }

    // MARK: "Reading the history…", only after a moment

    func testAReadIsMentionedOnlyOnceItHasTakenThreeTenthsOfASecond() async throws {
        let waits = HeldWaits()
        addTeardownBlock { waits.releaseAll() }
        let state = HistoryFaceState(wait: { await waits.wait($0) })
        state.readingChanged(true)
        try await waits.untilHolding(1)
        XCTAssertEqual(waits.asked, [.milliseconds(300)], "the face waits 300 ms, and only that")
        XCTAssertEqual(HistoryFaceState.readingDelay, .milliseconds(300))
        XCTAssertFalse(state.showsReading, "nothing is said while the moment lasts")

        waits.releaseAll()
        let said = await eventuallyOnMain(timeout: 2) { state.showsReading }
        XCTAssertTrue(said, "a read that outlasts the moment is mentioned")

        state.readingChanged(false)
        XCTAssertFalse(state.showsReading, "and the words go the moment the read is done")
    }

    func testAReadThatEndsWithinTheMomentIsNeverMentioned() async throws {
        let waits = HeldWaits()
        addTeardownBlock { waits.releaseAll() }
        let state = HistoryFaceState(wait: { await waits.wait($0) })
        state.readingChanged(true)
        try await waits.untilHolding(1)
        state.readingChanged(false)
        waits.releaseAll()  // the moment ends after the read did
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(state.showsReading)
    }

    func testOnlyTheReadThatIsOutCounts() async throws {
        let waits = HeldWaits()
        addTeardownBlock { waits.releaseAll() }
        let state = HistoryFaceState(wait: { await waits.wait($0) })
        state.readingChanged(true)
        try await waits.untilHolding(1)
        state.readingChanged(false)
        state.readingChanged(true)  // a second read began
        try await waits.untilHolding(2)
        waits.releaseFirst()  // the first read's moment ends: it is over, and says nothing
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(state.showsReading)
        waits.releaseAll()
        let said = await eventuallyOnMain(timeout: 2) { state.showsReading }
        XCTAssertTrue(said, "the second read's moment is the one that counts")
    }

    func testTheRealWaitIsTheClockAndAQuickReadSaysNothing() async throws {
        let state = HistoryFaceState()
        state.readingChanged(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.showsReading, "100 ms in, nothing is said")
        let said = await eventuallyOnMain(timeout: 2) { state.showsReading }
        XCTAssertTrue(said)
        state.readingChanged(false)
        XCTAssertFalse(state.showsReading)
    }
}

/// What the face says about reading the history, apart from the history itself.
final class HistoryReadStatusTests: XCTestCase {
    func testNothingIsSaidOfAReadThatWorkedOrHasNotBegun() {
        XCTAssertEqual(HistoryReadStatus(phase: .idle, showsReading: false), .quiet)
        XCTAssertEqual(HistoryReadStatus(phase: .loaded, showsReading: false), .quiet)
    }

    func testAFailureIsOneSentenceAndKeepsCmmsDetailApart() {
        let status = HistoryReadStatus(phase: .failed(title: "cmm could not read the history", detail: "Exit status 1.\n/Users/x"), showsReading: false)
        XCTAssertEqual(status, .failed(sentence: "cmm could not read the history.", detail: "Exit status 1.\n/Users/x"))
        XCTAssertEqual(
            HistoryReadStatus(phase: .failed(title: "Already a sentence.", detail: ""), showsReading: false),
            .failed(sentence: "Already a sentence.", detail: ""), "a full stop is not doubled"
        )
    }

    func testAReadThatIsOutIsSaidBeforeAnOldFailure() {
        XCTAssertEqual(HistoryReadStatus(phase: .failed(title: "cmm could not read the history", detail: ""), showsReading: true), .reading)
        XCTAssertEqual(HistoryReadStatus(phase: .loaded, showsReading: true), .reading)
    }

    func testTheWords() {
        XCTAssertEqual(HistoryReadStatus.readingText, "Reading the history\u{2026}")
        XCTAssertEqual(HistoryReadStatus.retryTitle, "Retry")
    }
}

/// Waits a test controls: each is held until the test lets it go, and what was asked for is written down.
final class HeldWaits: @unchecked Sendable {
    private struct Contents {
        var asked: [Duration] = []
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let box = Locked(Contents())

    func wait(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            box.withLock {
                $0.asked.append(duration)
                $0.held.append(continuation)
            }
        }
    }

    var asked: [Duration] { box.withLock { $0.asked } }
    var holding: Int { box.withLock { $0.held.count } }

    /// Lets every held wait go (they are let go when the test ends in any case).
    func releaseAll() {
        let held = box.withLock { contents -> [CheckedContinuation<Void, Never>] in
            defer { contents.held = [] }
            return contents.held
        }
        held.forEach { $0.resume() }
    }

    func releaseFirst() {
        let first = box.withLock { contents -> CheckedContinuation<Void, Never>? in
            contents.held.isEmpty ? nil : contents.held.removeFirst()
        }
        first?.resume()
    }

    /// Waits, at most two seconds, until this many waits are held.
    @MainActor
    func untilHolding(_ count: Int) async throws {
        let reached = await eventuallyOnMain(timeout: 2) { self.holding >= count }
        if !reached { throw SamplerStuck("only \(holding) of \(count) waits began") }
    }
}

/// What VoiceOver says for the History list: each week and each cleaning as one line of words, in the order the row is read.
final class HistorySpokenTests: XCTestCase {
    private func rows(_ runs: [String]) throws -> RunRows {
        var json = HistoryJSON()
        json.runs = runs
        return RunRows(
            report: try json.report(), now: TestTime.utc("2026-10-15T09:00:00Z"), calendar: TestCalendars.rome,
            locale: Locale(identifier: "en_GB"), home: "/Users/test"
        )
    }

    func testAWeekSaysWhatItGaveBack() throws {
        let week = try XCTUnwrap(try rows([HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4))]).weeks.first)
        XCTAssertEqual(week.spoken, "This week, 5.4 GB freed")
    }

    func testARowSaysWhenWhatCameBackAndTheGroups() throws {
        let row = try XCTUnwrap(try rows([HistoryJSON.run(
            finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4),
            items: [HistoryJSON.item(rule: "uv-cache", group: "uv cache", path: "/Users/test/.cache/uv", bytes: gigabytes(5.4))]
        )]).weeks.first?.rows.first)
        XCTAssertEqual(row.spoken, "Wed 14 Oct 14:06, 5.4 GB freed, uv cache")
    }

    func testARowSaysWhatStoppedItWhatFailedAndWhatWentInsideDockerInTheOrderTheRowShowsThem() throws {
        let row = try XCTUnwrap(try rows([HistoryJSON.run(
            finished: "2026-10-14T12:06:00Z", freed: gigabytes(1), inside: gigabytes(9), deleted: 2, failed: 1, stopped: true, planned: 9,
            items: [
                HistoryJSON.item(rule: "uv-cache", group: "uv cache", path: "/Users/test/.cache/uv", bytes: gigabytes(1)),
                HistoryJSON.item(rule: "docker", group: "Docker", path: "docker: unused images", bytes: gigabytes(9), inside: "Docker's disk image"),
                HistoryJSON.item(rule: "go-build", group: "Go build cache", path: "/Users/test/Library/Caches/go-build", status: "failed",
                                 bytes: gigabytes(2), reason: "permission denied"),
            ]
        )]).weeks.first?.rows.first)
        XCTAssertEqual(
            row.spoken,
            "Wed 14 Oct 14:06, 1.0 GB freed, Stopped after 3 of 9, Docker, uv cache, 1 failed, 9.0 GB inside Docker's disk image, not counted"
        )
        // and nothing is said by colour alone: the failure is a word, and so is the place Docker's space went
        XCTAssertTrue(row.spoken.contains("failed"))
        XCTAssertTrue(row.spoken.contains("not counted"))
    }

    func testAnItemSaysItsPathWhatBecameOfItAndItsSize() throws {
        let row = try XCTUnwrap(try rows([HistoryJSON.run(
            finished: "2026-10-14T12:06:00Z", freed: 0, deleted: 0, failed: 1,
            items: [HistoryJSON.item(rule: "go-build", group: "Go build cache", path: "/Users/test/Library/Caches/go-build", status: "failed",
                                     bytes: gigabytes(1.2), reason: "permission denied")]
        )]).weeks.first?.rows.first)
        XCTAssertEqual(row.items.map(\.spoken), ["~/Library/Caches/go-build, permission denied, 1.2 GB"])
    }
}
