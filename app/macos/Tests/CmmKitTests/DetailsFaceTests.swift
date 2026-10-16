import XCTest
@testable import CmmKit

/// The two faces of the Details pane (List and Map): which one the first open shows, which one is remembered, and what
/// the window does when it is asked to open the map on a tile.
final class DetailsFaceTests: XCTestCase {
    func testTheFirstOpenShowsTheMap() {
        XCTAssertEqual(DetailsFace.restored(from: nil), .map)
    }

    func testTheLastFaceIsTheOneRemembered() {
        XCTAssertEqual(DetailsFace.restored(from: DetailsFace.list.rawValue), .list)
        XCTAssertEqual(DetailsFace.restored(from: DetailsFace.map.rawValue), .map)
    }

    func testAnythingElseThatWasStoredIsTheMap() {
        XCTAssertEqual(DetailsFace.restored(from: ""), .map)
        XCTAssertEqual(DetailsFace.restored(from: "grid"), .map)
        XCTAssertEqual(DetailsFace.restored(from: "LIST"), .map, "only the exact word counts")
    }

    func testTheStoredWordsAreTheFacesNames() {
        XCTAssertEqual(DetailsFace.allCases.map(\.rawValue), ["list", "map"])
        XCTAssertEqual(DetailsFace.list.title, "List")
        XCTAssertEqual(DetailsFace.map.title, "Map")
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

    func testEscapeStillClosesThePaneOnTheMap() {
        let state = WindowState(detailsOpen: true)
        state.openMap(focusing: "item:/a")
        XCTAssertTrue(state.escape(confirmationOpen: false, cancelConfirmation: {}))
        XCTAssertFalse(state.detailsOpen)
    }
}
