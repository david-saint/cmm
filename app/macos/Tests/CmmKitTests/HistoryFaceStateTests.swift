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
