import XCTest
@testable import CmmKit

/// Keyboard use of the Details list, what Esc closes, and when motion becomes a crossfade.
final class DetailsNavigationTests: XCTestCase {
    private let home = "/Users/test"

    private func details(expanded: [String] = []) throws -> (DetailsModel, SelectionModel) {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let ids = Set(selection.groups.filter { group in expanded.contains(group.rule) }.map(\.id))
        return (DetailsModel(selection: selection, expanded: ids, home: home), selection)
    }

    private func groupID(_ rule: String, in selection: SelectionModel) throws -> String {
        "group:" + (try XCTUnwrap(selection.groups.first { $0.rule == rule }).id)
    }

    // MARK: moving

    func testDownAndUpStepThroughTheRows() throws {
        let (model, _) = try details()
        let ids = model.focusableIDs
        XCTAssertEqual(DetailsNavigation.handle(.down, focused: ids[0], in: model), .focus(ids[1]))
        XCTAssertEqual(DetailsNavigation.handle(.up, focused: ids[1], in: model), .focus(ids[0]))
    }

    func testTheEndsDoNotWrap() throws {
        let (model, _) = try details()
        let ids = model.focusableIDs
        XCTAssertEqual(DetailsNavigation.handle(.up, focused: ids.first, in: model), .none)
        XCTAssertEqual(DetailsNavigation.handle(.down, focused: ids.last, in: model), .none)
    }

    func testWithNothingFocusedDownEntersAtTheTopAndUpAtTheBottom() throws {
        let (model, _) = try details()
        XCTAssertEqual(DetailsNavigation.handle(.down, focused: nil, in: model), .focus(model.focusableIDs.first!))
        XCTAssertEqual(DetailsNavigation.handle(.up, focused: nil, in: model), .focus(model.focusableIDs.last!))
        XCTAssertEqual(DetailsNavigation.handle(.down, focused: "group:gone", in: model), .focus(model.focusableIDs.first!),
                       "a row that is no longer there counts as nothing focused")
    }

    func testHomeAndEnd() throws {
        let (model, _) = try details()
        XCTAssertEqual(DetailsNavigation.handle(.home, focused: model.focusableIDs[2], in: model), .focus(model.focusableIDs.first!))
        XCTAssertEqual(DetailsNavigation.handle(.end, focused: model.focusableIDs[2], in: model), .focus(model.focusableIDs.last!))
    }

    func testOpenGroupsLetTheArrowsIntoTheirItems() throws {
        let (model, selection) = try details(expanded: ["lane-deps"])
        let lanes = try groupID("lane-deps", in: selection)
        let ids = model.focusableIDs
        XCTAssertEqual(ids[0], lanes)
        XCTAssertTrue(ids[1].hasPrefix("item:"))
        XCTAssertEqual(DetailsNavigation.handle(.down, focused: lanes, in: model), .focus(ids[1]))
    }

    // MARK: opening and closing groups

    func testRightOpensAClosedGroupThenEntersIt() throws {
        let (closed, selection) = try details()
        let lanes = try groupID("lane-deps", in: selection)
        XCTAssertEqual(DetailsNavigation.handle(.right, focused: lanes, in: closed), .expand(lanes))

        let (open, _) = try details(expanded: ["lane-deps"])
        XCTAssertEqual(DetailsNavigation.handle(.right, focused: lanes, in: open), .focus(open.focusableIDs[1]))
    }

    func testRightOnAnItemDoesNothing() throws {
        let (model, _) = try details(expanded: ["lane-deps"])
        XCTAssertEqual(DetailsNavigation.handle(.right, focused: model.focusableIDs[1], in: model), .none)
    }

    func testLeftClosesAnOpenGroupOrGoesBackUpToTheGroupFromAnItem() throws {
        let (model, selection) = try details(expanded: ["lane-deps"])
        let lanes = try groupID("lane-deps", in: selection)
        XCTAssertEqual(DetailsNavigation.handle(.left, focused: lanes, in: model), .collapse(lanes))
        XCTAssertEqual(DetailsNavigation.handle(.left, focused: model.focusableIDs[2], in: model), .focus(lanes))

        let (closed, _) = try details()
        XCTAssertEqual(DetailsNavigation.handle(.left, focused: lanes, in: closed), .none)
    }

    // MARK: ticking

    func testSpaceTicksTheFocusedGroupOrItem() throws {
        let (model, selection) = try details(expanded: ["lane-deps"])
        let lanes = try groupID("lane-deps", in: selection)
        XCTAssertEqual(DetailsNavigation.handle(.space, focused: lanes, in: model), .toggleTick(lanes))
        let item = model.focusableIDs[1]
        XCTAssertEqual(DetailsNavigation.handle(.space, focused: item, in: model), .toggleTick(item))
        XCTAssertEqual(DetailsNavigation.handle(.space, focused: nil, in: model), .none)
    }

    func testReturnOpensOrClosesAGroupAndTicksAnItem() throws {
        let (closed, selection) = try details()
        let lanes = try groupID("lane-deps", in: selection)
        XCTAssertEqual(DetailsNavigation.handle(.return, focused: lanes, in: closed), .expand(lanes))

        let (open, _) = try details(expanded: ["lane-deps"])
        XCTAssertEqual(DetailsNavigation.handle(.return, focused: lanes, in: open), .collapse(lanes))
        XCTAssertEqual(DetailsNavigation.handle(.return, focused: open.focusableIDs[1], in: open), .toggleTick(open.focusableIDs[1]))
    }

    func testAFocusThatDisappearedIsDropped() throws {
        let (model, _) = try details()
        XCTAssertNil(DetailsNavigation.validFocus("item:/gone", in: model))
        XCTAssertEqual(DetailsNavigation.validFocus(model.focusableIDs[0], in: model), model.focusableIDs[0])
        XCTAssertNil(DetailsNavigation.validFocus(nil, in: model))
    }
}

@MainActor
final class WindowStateTests: XCTestCase {
    func testTheDetailsStartClosedAndToggle() {
        let state = WindowState()
        XCTAssertFalse(state.detailsOpen)
        state.toggleDetails()
        XCTAssertTrue(state.detailsOpen)
        state.toggleDetails()
        XCTAssertFalse(state.detailsOpen)
    }

    func testTheReviewLinkOpensTheDetailsAtTheReviewSection() {
        let state = WindowState()
        state.openDetails(showing: .review)
        XCTAssertTrue(state.detailsOpen)
        XCTAssertEqual(state.scrollTarget, .review)
        state.scrollTarget = nil
        state.openDetails()
        XCTAssertNil(state.scrollTarget)
    }

    func testClosingTheDetailsForgetsTheKeyboardFocus() {
        let state = WindowState(detailsOpen: true)
        state.focusedRow = "group:safe/uv"
        state.closeDetails()
        XCTAssertFalse(state.detailsOpen)
        XCTAssertNil(state.focusedRow)
    }

    func testGroupsOpenAndClose() {
        let state = WindowState()
        state.toggleExpanded("safe/uv")
        XCTAssertTrue(state.expanded.contains("safe/uv"))
        state.toggleExpanded("safe/uv")
        XCTAssertFalse(state.expanded.contains("safe/uv"))
        state.setExpanded("safe/uv", true)
        state.setExpanded("safe/uv", true)
        XCTAssertEqual(state.expanded, ["safe/uv"])
    }

    func testEscapeClosesTheCardFirstAndThenThePane() {
        let state = WindowState(detailsOpen: true)
        var cancelled = 0

        XCTAssertTrue(state.escape(confirmationOpen: true, cancelConfirmation: { cancelled += 1 }))
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(state.detailsOpen, "the card goes first; the pane is still there")

        XCTAssertTrue(state.escape(confirmationOpen: false, cancelConfirmation: { cancelled += 1 }))
        XCTAssertEqual(cancelled, 1, "no card, so nothing is cancelled")
        XCTAssertFalse(state.detailsOpen)
    }

    func testEscapeWithNothingOpenDoesNothing() {
        let state = WindowState()
        var cancelled = 0
        XCTAssertFalse(state.escape(confirmationOpen: false, cancelConfirmation: { cancelled += 1 }))
        XCTAssertEqual(cancelled, 0)
    }
}

final class MotionStyleTests: XCTestCase {
    func testReduceMotionTurnsSpringsIntoCrossfades() {
        XCTAssertEqual(MotionStyle.resolve(reduceMotion: false), .spring)
        XCTAssertEqual(MotionStyle.resolve(reduceMotion: true), .crossfade)
    }

    func testOnlyTheSpringSlidesAndGrows() {
        XCTAssertTrue(MotionStyle.spring.slidesPane)
        XCTAssertTrue(MotionStyle.spring.growsCard)
        XCTAssertFalse(MotionStyle.crossfade.slidesPane, "the pane fades in place")
        XCTAssertFalse(MotionStyle.crossfade.growsCard, "the card fades in place")
    }

    func testBothStylesFinishQuickly() {
        XCTAssertLessThanOrEqual(MotionStyle.crossfade.duration, 0.25)
        XCTAssertLessThanOrEqual(MotionStyle.spring.duration, 0.6)
    }
}
