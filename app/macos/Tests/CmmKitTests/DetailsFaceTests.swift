import XCTest
@testable import CmmKit

/// The three faces of the Details pane (List, Map and History): which one the first open shows, which one is remembered, and
/// what the window does when it is asked to open the map on a tile or the History.
final class DetailsFaceTests: XCTestCase {
    func testTheFirstOpenShowsTheMap() {
        XCTAssertEqual(DetailsFace.restored(from: nil), .map)
    }

    func testTheLastFaceIsTheOneRemembered() {
        XCTAssertEqual(DetailsFace.restored(from: DetailsFace.list.rawValue), .list)
        XCTAssertEqual(DetailsFace.restored(from: DetailsFace.map.rawValue), .map)
        XCTAssertEqual(DetailsFace.restored(from: DetailsFace.history.rawValue), .history)
    }

    func testAnythingElseThatWasStoredIsTheMap() {
        XCTAssertEqual(DetailsFace.restored(from: ""), .map)
        XCTAssertEqual(DetailsFace.restored(from: "grid"), .map)
        XCTAssertEqual(DetailsFace.restored(from: "LIST"), .map, "only the exact word counts")
        XCTAssertEqual(DetailsFace.restored(from: "History"), .map, "only the exact word counts")
    }

    func testTheStoredWordsAreTheFacesNames() {
        XCTAssertEqual(DetailsFace.allCases.map(\.rawValue), ["list", "map", "history"], "the order of the switch")
        XCTAssertEqual(DetailsFace.allCases.map(\.title), ["List", "Map", "History"])
    }

    func testEveryWordOfTheSwitchSaysWhatItDoesToVoiceOver() {
        XCTAssertEqual(DetailsFace.list.hint, "Shows the list of what cmm found")
        XCTAssertEqual(DetailsFace.map.hint, "Shows the map of what cmm found")
        XCTAssertEqual(DetailsFace.history.hint, "Shows what past cleanings freed and how the free space has moved")
    }
}

@MainActor
final class MapWindowStateTests: XCTestCase {
    func testAWindowStartsOnTheMapWithNothingFocusedOrHovered() {
        let state = WindowState()
        XCTAssertEqual(state.face, .map)
        XCTAssertNil(state.focusedTile)
        XCTAssertNil(state.hoveredTile)
    }

    func testOpeningTheDetailsKeepsTheFaceThePersonLeftIt() {
        let state = WindowState(face: .list)
        state.openDetails()
        XCTAssertTrue(state.detailsOpen)
        XCTAssertEqual(state.face, .list)
    }

    func testOpenMapShowsTheMapWithThatTileFocusedWhateverTheFaceWas() {
        let state = WindowState(face: .list)
        state.openMap(focusing: "group:review/Docker")
        XCTAssertTrue(state.detailsOpen)
        XCTAssertEqual(state.face, .map, "the review link and a band slice open the map")
        XCTAssertEqual(state.focusedTile, "group:review/Docker")
    }

    func testOpenMapAsksTheMapForTheKeyboardEveryTime() {
        let state = WindowState()
        let before = state.mapFocusRequest
        state.openMap(focusing: "item:/a")
        let first = state.mapFocusRequest
        state.openMap(focusing: "item:/a")
        XCTAssertNotEqual(first, before)
        XCTAssertNotEqual(state.mapFocusRequest, first, "the same tile twice still moves the keyboard to the map again")
    }

    func testOpenMapWithoutATileOpensTheMapAndFocusesNothing() {
        let state = WindowState()
        state.focusedTile = "item:/old"
        state.openMap(focusing: nil)
        XCTAssertEqual(state.face, .map)
        XCTAssertNil(state.focusedTile)
    }

    func testClosingThePaneForgetsTheTileFocusAndTheHover() {
        let state = WindowState(detailsOpen: true)
        state.focusedTile = "item:/a"
        state.hoveredTile = "item:/b"
        state.closeDetails()
        XCTAssertNil(state.focusedTile)
        XCTAssertNil(state.hoveredTile)
        XCTAssertEqual(state.face, .map, "but the face is remembered")
    }

    func testSwitchingFaceDropsAHoverFromTheFaceThatWasLeft() {
        let state = WindowState(detailsOpen: true)
        state.hoveredTile = "item:/a"
        state.setFace(.list)
        XCTAssertEqual(state.face, .list)
        XCTAssertNil(state.hoveredTile)
    }

    func testSettingTheSameFaceChangesNothing() {
        let state = WindowState(detailsOpen: true)
        state.focusedTile = "item:/a"
        state.setFace(.map)
        XCTAssertEqual(state.focusedTile, "item:/a")
    }

    func testOpenHistoryOpensThePaneOnTheHistoryWhateverTheFaceWas() {
        for before in DetailsFace.allCases {
            for open in [false, true] {
                let state = WindowState(detailsOpen: open, face: before)
                state.scrollTarget = .review
                state.openHistory()
                XCTAssertTrue(state.detailsOpen, "from \(before), pane open: \(open)")
                XCTAssertEqual(state.face, .history)
                XCTAssertNil(state.scrollTarget, "history has nothing to scroll to")
            }
        }
    }

    func testLeavingTheMapForTheHistoryTakesTheHoverAndTheKeyboardBack() {
        let state = WindowState(detailsOpen: true)
        state.hoveredTile = "item:/a"
        state.mapKeyboard = true
        state.setFace(.history)
        XCTAssertNil(state.hoveredTile)
        XCTAssertFalse(state.mapKeyboard, "a map that is no longer showing has no keyboard")
        XCTAssertFalse(state.mapOpen)
        XCTAssertFalse(state.isBandMagnified, "only the map keeps the band magnified")
    }

    func testOpeningTheHistoryNeverFlies() {
        let fromClosed = WindowState(face: .map)
        fromClosed.openHistory()
        XCTAssertNil(fromClosed.flight, "the map is not what opens")
        let fromMap = WindowState(face: .map)
        fromMap.openDetails()
        fromMap.landFlight()
        fromMap.openHistory()
        XCTAssertNil(fromMap.flight, "switching faces never flies")
    }

    func testEscapeStillClosesThePaneOnTheHistory() {
        let state = WindowState()
        state.openHistory()
        XCTAssertTrue(state.escape(confirmationOpen: false, cancelConfirmation: {}))
        XCTAssertFalse(state.detailsOpen)
        XCTAssertEqual(state.face, .history, "but the face is remembered")
    }

    func testEscapeStillClosesThePaneOnTheMap() {
        let state = WindowState(detailsOpen: true)
        state.openMap(focusing: "item:/a")
        XCTAssertTrue(state.escape(confirmationOpen: false, cancelConfirmation: {}))
        XCTAssertFalse(state.detailsOpen)
    }
}
