import XCTest
@testable import CmmKit

/// The History list's keys (the List's own): up and down between the cleanings, right and left to open and close one, Space and
/// Return to open or close it, Home and End to the first and last.
final class HistoryNavigationTests: XCTestCase {
    /// The board's four cleanings, newest first: Docker's (which has an item), 14 Oct's, 9 Oct's and 29 Sep's.
    private func boardRows() throws -> [RunRows.Row] {
        let rows = RunRows(
            report: try HistoryBoard.report(), now: HistoryBoard.now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale,
            home: "/Users/test"
        )
        // the tests below take rows by position: a list of another length is a failure, not an index out of range
        guard rows.listed.count == 4 else { throw SamplerStuck("the board has four cleanings, not \(rows.listed.count)") }
        return rows.listed
    }

    private func ids(_ rows: [RunRows.Row]) -> [String] { rows.map(\.id) }

    func testTheListIsTheWeeksRowsOneAfterAnother() throws {
        let rows = try boardRows()
        XCTAssertEqual(rows.map(\.dateText), ["Tue 14 Oct", "Tue 14 Oct", "Thu 9 Oct", "Mon 29 Sep"])
    }

    func testUpAndDownMoveBetweenTheCleaningsAndStopAtTheEnds() throws {
        let rows = try boardRows()
        let id = ids(rows)
        XCTAssertEqual(HistoryNavigation.handle(.down, focused: nil, rows: rows, expanded: []), .focus(id[0]), "no focus yet: the first")
        XCTAssertEqual(HistoryNavigation.handle(.up, focused: nil, rows: rows, expanded: []), .focus(id[3]), "or the last")
        XCTAssertEqual(HistoryNavigation.handle(.down, focused: id[0], rows: rows, expanded: []), .focus(id[1]))
        XCTAssertEqual(HistoryNavigation.handle(.down, focused: id[2], rows: rows, expanded: [id[2]]), .focus(id[3]),
                       "an open cleaning's items are read, not stepped through")
        XCTAssertEqual(HistoryNavigation.handle(.down, focused: id[3], rows: rows, expanded: []), .none, "the last stays the last")
        XCTAssertEqual(HistoryNavigation.handle(.up, focused: id[1], rows: rows, expanded: []), .focus(id[0]))
        XCTAssertEqual(HistoryNavigation.handle(.up, focused: id[0], rows: rows, expanded: []), .none)
        XCTAssertEqual(HistoryNavigation.handle(.home, focused: id[2], rows: rows, expanded: []), .focus(id[0]))
        XCTAssertEqual(HistoryNavigation.handle(.end, focused: id[0], rows: rows, expanded: []), .focus(id[3]))
    }

    func testRightOpensLeftClosesAndSpaceAndReturnDoEither() throws {
        let rows = try boardRows()
        let row = ids(rows)[2]
        XCTAssertEqual(HistoryNavigation.handle(.right, focused: row, rows: rows, expanded: []), .expand(row))
        XCTAssertEqual(HistoryNavigation.handle(.right, focused: row, rows: rows, expanded: [row]), .none, "open is open")
        XCTAssertEqual(HistoryNavigation.handle(.left, focused: row, rows: rows, expanded: [row]), .collapse(row))
        XCTAssertEqual(HistoryNavigation.handle(.left, focused: row, rows: rows, expanded: []), .none, "closed is closed")
        for key in [DetailsNavigation.Key.space, .return] {
            XCTAssertEqual(HistoryNavigation.handle(key, focused: row, rows: rows, expanded: []), .expand(row), "\(key)")
            XCTAssertEqual(HistoryNavigation.handle(key, focused: row, rows: rows, expanded: [row]), .collapse(row), "\(key)")
        }
    }

    func testWithNoCleaningUnderTheKeyboardOnlyTheMovesDoAnything() throws {
        let rows = try boardRows()
        for key in [DetailsNavigation.Key.left, .right, .space, .return] {
            XCTAssertEqual(HistoryNavigation.handle(key, focused: nil, rows: rows, expanded: []), .none, "\(key)")
            XCTAssertEqual(HistoryNavigation.handle(key, focused: "a run that is gone", rows: rows, expanded: []), .none, "\(key)")
        }
        XCTAssertEqual(HistoryNavigation.handle(.down, focused: "a run that is gone", rows: rows, expanded: []), .focus(rows[0].id),
                       "a focus that is no longer listed counts as none")
        XCTAssertNil(HistoryNavigation.validFocus("a run that is gone", in: rows))
    }

    func testACleaningWithNothingToShowDoesNotOpen() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:06:00Z", items: [])]
        let rows = RunRows(report: try json.report(), now: TestTime.utc("2026-10-15T09:00:00Z"), calendar: TestCalendars.rome,
                           locale: Locale(identifier: "en_GB"), home: "/Users/test").listed
        let row = try XCTUnwrap(rows.first)
        XCTAssertFalse(row.hasDetails)
        for key in [DetailsNavigation.Key.right, .space, .return] {
            XCTAssertEqual(HistoryNavigation.handle(key, focused: row.id, rows: rows, expanded: []), .none, "\(key)")
        }
    }

    func testAnEmptyListHasNothingToMoveTo() {
        for key in [DetailsNavigation.Key.up, .down, .home, .end, .space] {
            XCTAssertEqual(HistoryNavigation.handle(key, focused: nil, rows: [], expanded: []), .none)
        }
    }
}

/// The face does what the keys say.
@MainActor
final class HistoryFaceStateFollowsTheKeysTests: XCTestCase {
    func testEachActionChangesWhatItSays() {
        let state = HistoryFaceState()
        state.follow(.focus("a"))
        XCTAssertEqual(state.focusedRun, "a")
        state.follow(.expand("a"))
        XCTAssertEqual(state.expanded, ["a"])
        state.follow(.expand("a"))
        XCTAssertEqual(state.expanded, ["a"], "opening an open one keeps it open")
        state.follow(.collapse("a"))
        XCTAssertEqual(state.expanded, [])
        state.follow(.none)
        XCTAssertEqual(state.focusedRun, "a")
        XCTAssertEqual(state.expanded, [])
    }
}

/// When the History reads again of its own accord: when a cleaning ends, and at no other change of the window.
final class HistoryRefreshRuleTests: XCTestCase {
    private let phases: [AppModel.Phase] = [.idle, .scanning, .ready, .empty, .cleaning, .done, .failed]

    func testACleaningThatEndsIsReadAgainAndNothingElseIs() {
        for old in phases {
            for new in phases where new != old {
                let expected = new == .done || (old == .cleaning && new == .failed)
                XCTAssertEqual(HistoryRefreshRule.readsAgain(from: old, to: new), expected, "\(old) to \(new)")
            }
        }
    }

    func testTheDoneScreenIsACleaningEndingEvenWhenTheCleaningWasNeverDrawn() {
        // a cleaning so quick that the window went from at rest to done without drawing the cleaning screen in between
        XCTAssertTrue(HistoryRefreshRule.readsAgain(from: .ready, to: .done))
        XCTAssertFalse(HistoryRefreshRule.readsAgain(from: .done, to: .done))
    }

    func testAScanEndingIsNotACleaningEnding() {
        XCTAssertFalse(HistoryRefreshRule.readsAgain(from: .scanning, to: .failed), "a failed scan cleaned nothing")
        XCTAssertFalse(HistoryRefreshRule.readsAgain(from: .scanning, to: .ready))
        XCTAssertFalse(HistoryRefreshRule.readsAgain(from: .done, to: .scanning), "Done scans again; the cleaning was read already")
    }
}
