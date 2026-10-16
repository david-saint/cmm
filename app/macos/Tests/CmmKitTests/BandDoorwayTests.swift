import SwiftUI
import XCTest
@testable import CmmKit

/// Where the band and the map sit when the map is open, as numbers: the band rises 16 pt and the map is the boards' 416 x 520.
final class HeroLayoutMapTests: XCTestCase {
    private func layout(details: Bool, map: Bool, screen: HeroLayout.Screen = .rest, width: Double = 1100, height: Double = 720) -> HeroLayout {
        HeroLayout(screen: screen, detailsOpen: details, mapOpen: map, width: width, height: height)
    }

    // MARK: the band

    func testTheBandRisesSixteenPointsWhileTheMapIsOpen() {
        XCTAssertEqual(layout(details: true, map: false).bandTop, 612, "the list's board")
        XCTAssertEqual(layout(details: true, map: true).bandTop, 596, "the map's board")
        XCTAssertEqual(layout(details: true, map: true).bandLeading, 72)
        XCTAssertEqual(layout(details: true, map: true).bandWidth, 520)
    }

    func testTheMapOnlyRaisesTheBandWithThePaneOpenOnTheRestScreen() {
        XCTAssertEqual(layout(details: false, map: true).bandTop, 612, "no pane, no map")
        XCTAssertEqual(layout(details: true, map: true, screen: .done).bandTop, layout(details: true, map: false, screen: .done).bandTop)
        XCTAssertEqual(layout(details: true, map: true, screen: .empty).bandTop, layout(details: true, map: false, screen: .empty).bandTop)
    }

    func testTheRiseScalesWithTheWindowLikeEverythingElse() {
        let flat = layout(details: true, map: false, width: 880, height: 576)
        let raised = layout(details: true, map: true, width: 880, height: 576)
        XCTAssertEqual(flat.bandTop - raised.bandTop, 16 * flat.scale, accuracy: 1e-9)
    }

    func testTheBandLineSitsTwentyFivePointsUnderItsCaptionRow() {
        // a 15 pt row of small print, 10 pt of air, then the band: the map board's band starts at 621, the list's at 637
        XCTAssertEqual(layout(details: true, map: true).bandLineTop, 621)
        XCTAssertEqual(layout(details: true, map: false).bandLineTop, 637)
        let small = layout(details: true, map: false, width: 880, height: 576)
        XCTAssertEqual(small.bandLineTop - small.bandTop, 25 * small.scale, accuracy: 1e-9)
        XCTAssertEqual(small.bandLabelsHeight, 15 * small.scale, accuracy: 1e-9)
    }

    // MARK: the map

    func testTheBoardsMapIs416By520() {
        XCTAssertEqual(HeroLayout.mapArea(windowHeight: 720), CGSize(width: 416, height: 520))
        XCTAssertEqual(HeroLayout.mapArea(paneContentHeight: 626), CGSize(width: 416, height: 520), "720 - 2 x 8 - 78 is what the pane has under its header")
        XCTAssertEqual(HeroLayout.paneContentHeight(windowHeight: 720), 626)
    }

    func testTheMapShrinksWithTheWindowAndNeverBelow120() {
        XCTAssertEqual(HeroLayout.mapArea(windowHeight: 560).height, 360)
        XCTAssertEqual(HeroLayout.mapArea(windowHeight: 900).height, 700)
        XCTAssertEqual(HeroLayout.mapArea(windowHeight: 200).height, 120)
        XCTAssertEqual(HeroLayout.mapArea(windowHeight: 0).height, 120)
    }

    func testTheMapStartsWhereTheBoardPutsItsFirstTile() {
        // the pane is 8 from the right edge and 452 wide, the tiles start 18 inside it and 78 under its top
        XCTAssertEqual(HeroLayout.mapOrigin(windowWidth: 1100), CGPoint(x: 658, y: 86))
        XCTAssertEqual(HeroLayout.mapOrigin(windowWidth: 820), CGPoint(x: 378, y: 86))
    }
}

/// What the band's magnified end needs on top of its slices: the same end at its true width (where the slices come from and
/// go back to), and the words and lights of the hover.
final class BandMagnifierDoorwayTests: XCTestCase {
    private func map() throws -> MapModel {
        MapModel(selection: SelectionModel(plan: try TestPlans.fixture("plan-c.json")), size: CGSize(width: 416, height: 520), home: "/Users/test")
    }

    private func magnifier(_ map: MapModel, enlargement: Double = BandMagnifier.targetFactor) throws -> BandMagnifier {
        try XCTUnwrap(BandMagnifier(capacity: 228_000_000_000, free: 19_800_000_000, tiles: map.tiles, width: 520, enlargement: enlargement))
    }

    func testTheCollapsedEndIsTheTrueWidthAndSaysNothingIsEnlarged() throws {
        let collapsed = try magnifier(try map(), enlargement: 1)
        XCTAssertEqual(collapsed.factor, 1, accuracy: 1e-9)
        XCTAssertFalse(collapsed.isEnlarged)
        XCTAssertEqual(collapsed.reclaimable.width, 17.4 / 228 * 520, accuracy: 1e-9)
        XCTAssertEqual(collapsed.caption, "17.4 GB reclaimable")
        XCTAssertEqual(collapsed.usedWidth + 2 + collapsed.reclaimable.width + 2 + collapsed.free.width, 520, accuracy: 1e-9)
    }

    func testTheCollapsedEndKeepsTheSameFreeSpaceAndTheSameSlices() throws {
        let map = try map()
        let (collapsed, enlarged) = (try magnifier(map, enlargement: 1), try magnifier(map))
        XCTAssertEqual(collapsed.free.x, enlarged.free.x, accuracy: 1e-9, "the free space is never enlarged")
        XCTAssertEqual(collapsed.free.width, enlarged.free.width, accuracy: 1e-9)
        XCTAssertEqual(collapsed.slices.map(\.id), enlarged.slices.map(\.id))
        XCTAssertEqual(collapsed.slices.map(\.look), enlarged.slices.map(\.look))
        XCTAssertGreaterThan(enlarged.slices[0].width, collapsed.slices[0].width * 4, "Docker's slice is five times as wide")
    }

    func testAskingForLessThanOneIsNotAShrink() throws {
        XCTAssertEqual(try magnifier(try map(), enlargement: 0.2).factor, 1, accuracy: 1e-9)
    }

    func testWhileHoveredTheCaptionSaysSo() throws {
        let m = try magnifier(try map())
        XCTAssertEqual(m.caption(whileHovered: true), "enlarged ×5 while hovered")
        XCTAssertEqual(m.caption(whileHovered: false), "17.4 GB reclaimable, enlarged ×5")
        let collapsed = try magnifier(try map(), enlargement: 1)
        XCTAssertEqual(collapsed.caption(whileHovered: true), "17.4 GB reclaimable", "nothing enlarged, nothing to say about hover")
    }

    func testThePointerOnASliceRingsItAsWellAsLightingIt() {
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: "a", focused: nil, pointerOnBand: true), [.lit, .ringed])
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: "a", focused: nil, pointerOnBand: false), [.lit], "a tile's hover only lights its slice")
        XCTAssertEqual(BandMagnifier.emphasis(of: "b", hovered: "a", focused: nil, pointerOnBand: true), [])
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: nil, focused: "a", pointerOnBand: true), [.ringed])
    }

    func testTheBubbleNamesTheTileAndSaysHowBig() throws {
        let map = try map()
        let uv = try XCTUnwrap(map.tiles.first { $0.title == "uv cache" })
        let lane = try XCTUnwrap(map.tiles.first { $0.title == "lane-a" && $0.subtitle == "ios/Pods" })
        XCTAssertEqual(BandBubble(tile: uv).name, "uv cache")
        XCTAssertEqual(BandBubble(tile: uv).size, "2.5 GB")
        XCTAssertEqual(BandBubble(tile: lane).name, "lane-a ios/Pods", "two tiles of one group are told apart")
        XCTAssertEqual(BandBubble(tile: uv).spoken, "uv cache, 2.5 GB")
    }

    func testTheBubbleSitsOverTheSliceAndNeverLeavesTheBand() {
        // centred on the slice, clamped to the band's own width
        XCTAssertEqual(BandBubble.originX(sliceMidX: 200, bubbleWidth: 90, bandWidth: 520), 155)
        XCTAssertEqual(BandBubble.originX(sliceMidX: 10, bubbleWidth: 90, bandWidth: 520), 0, "at the left end it starts at the band's edge")
        XCTAssertEqual(BandBubble.originX(sliceMidX: 515, bubbleWidth: 90, bandWidth: 520), 430, "at the right end it stops at the band's edge")
        XCTAssertEqual(BandBubble.originX(sliceMidX: 50, bubbleWidth: 600, bandWidth: 520), 0, "wider than the band: starts at the edge")
    }
}

/// The window's memory of the band and of the unfold between the band and the map: which state starts a flight, which does
/// not, and when a flight is over.
@MainActor
final class BandWindowStateTests: XCTestCase {
    // MARK: the pointer on the band

    func testHoveringTheBandMagnifiesItAndLeavingUndoesIt() {
        let state = WindowState()
        XCTAssertFalse(state.isBandMagnified)
        state.bandHovered = true
        XCTAssertTrue(state.isBandMagnified)
        state.bandHovered = false
        XCTAssertFalse(state.isBandMagnified)
    }

    func testTheOpenMapKeepsTheBandMagnifiedAndTheOpenListDoesNot() {
        let state = WindowState(face: .map)
        state.openDetails()
        XCTAssertTrue(state.mapOpen)
        XCTAssertTrue(state.isBandMagnified, "the band stays thick and magnified while the map is open")
        state.setFace(.list)
        XCTAssertFalse(state.mapOpen)
        XCTAssertFalse(state.isBandMagnified)
        state.closeDetails()
        state.setFace(.map)
        XCTAssertFalse(state.mapOpen, "the map is a face of an open pane")
        XCTAssertFalse(state.isBandMagnified)
    }

    func testTheMapHasTheKeyboardOnlyWhileItIsOpenAndStartsWithout() {
        let state = WindowState()
        XCTAssertFalse(state.mapKeyboard)
        state.mapKeyboard = true
        state.closeDetails()
        XCTAssertFalse(state.mapKeyboard, "a closed pane has no keyboard")
        state.mapKeyboard = true
        state.setFace(.list)
        XCTAssertFalse(state.mapKeyboard, "nor does a map that is no longer showing")
    }

    // MARK: what starts a flight

    func testOpeningThePaneOnTheMapUnfoldsTheBandIntoIt() throws {
        let state = WindowState(face: .map)
        state.bandHovered = true
        state.openDetails()
        let flight = try XCTUnwrap(state.flight)
        XCTAssertEqual(flight.kind, .unfold)
        XCTAssertFalse(flight.paneWasOpen)
        XCTAssertTrue(flight.bandWasMagnified, "the pointer was on the band: its end was already enlarged")
    }

    func testOpeningThePaneOnTheListDoesNotFly() {
        let state = WindowState(face: .list)
        state.openDetails()
        XCTAssertNil(state.flight)
    }

    func testTheReviewLinkAndASliceUnfoldTheBandWhateverTheFaceWas() throws {
        let fromClosed = WindowState(face: .list)
        fromClosed.openMap(focusing: "item:/a")
        XCTAssertEqual(fromClosed.flight?.kind, .unfold)
        XCTAssertEqual(fromClosed.flight?.paneWasOpen, false)

        let fromList = WindowState(face: .list)
        fromList.openDetails()
        fromList.openMap(focusing: "item:/a")
        let flight = try XCTUnwrap(fromList.flight)
        XCTAssertEqual(flight.kind, .unfold, "the slice lifts into the map of a pane that is already open")
        XCTAssertTrue(flight.paneWasOpen)
        XCTAssertFalse(flight.bandWasMagnified)
    }

    func testASliceClickedWhileTheMapIsOpenOnlyMovesTheFocus() {
        let state = WindowState(face: .map)
        state.openDetails()
        state.landFlight()
        let request = state.mapFocusRequest
        state.openMap(focusing: "item:/b")
        XCTAssertNil(state.flight)
        XCTAssertEqual(state.focusedTile, "item:/b")
        XCTAssertNotEqual(state.mapFocusRequest, request)
    }

    func testSwitchingFacesNeverFlies() {
        let state = WindowState(face: .list)
        state.openDetails()
        state.setFace(.map)
        XCTAssertNil(state.flight, "the pane is already there: only a click on a slice lifts the band into it")
        state.setFace(.list)
        XCTAssertNil(state.flight)
    }

    // MARK: the way back

    func testClosingThePaneOnTheMapFoldsItBackIntoTheBand() throws {
        let state = WindowState(face: .map)
        state.openDetails()
        state.landFlight()
        state.closeDetails()
        XCTAssertEqual(state.flight?.kind, .fold)
    }

    func testClosingTheListOrAClosedPaneDoesNotFold() {
        let list = WindowState(face: .list)
        list.openDetails()
        list.closeDetails()
        XCTAssertNil(list.flight)

        let closed = WindowState(face: .map)
        closed.closeDetails()
        XCTAssertNil(closed.flight, "nothing was open")
    }

    func testEscapeOnTheMapFoldsLikeTheHideButton() {
        let state = WindowState(face: .map)
        state.openDetails()
        state.landFlight()
        XCTAssertTrue(state.escape(confirmationOpen: false, cancelConfirmation: {}))
        XCTAssertEqual(state.flight?.kind, .fold)
    }

    // MARK: landing

    func testLandingEndsTheFlightOnce() throws {
        let state = WindowState(face: .map)
        state.openDetails()
        let generation = try XCTUnwrap(state.flight?.generation)
        state.landFlight(generation)
        XCTAssertNil(state.flight)
    }

    func testALateLandingNeverEndsALaterFlight() throws {
        let state = WindowState(face: .map)
        state.openDetails()
        let first = try XCTUnwrap(state.flight?.generation)
        state.landFlight(first)
        state.closeDetails()
        let second = try XCTUnwrap(state.flight?.generation)
        XCTAssertNotEqual(first, second)
        state.landFlight(first)  // the first one's timer, firing late
        XCTAssertEqual(state.flight?.generation, second)
        state.landFlight(second)
        XCTAssertNil(state.flight)
    }

    func testLandingWithoutAGenerationEndsWhateverIsFlying() {
        let state = WindowState(face: .map)
        state.openDetails()
        state.landFlight()
        XCTAssertNil(state.flight)
        state.landFlight()  // and nothing flying is nothing to end
        XCTAssertNil(state.flight)
    }

    func testNothingFliesWhenFlightsAreOff() {
        let state = WindowState(face: .map)
        state.flightsEnabled = false
        state.openDetails()
        XCTAssertNil(state.flight, "Reduce Motion: the pane fades in, the band is simply magnified")
        state.openMap(focusing: "item:/a")
        XCTAssertNil(state.flight)
        state.closeDetails()
        XCTAssertNil(state.flight)
    }

    func testTheFlightKnowsWhenItBegan() throws {
        let state = WindowState(face: .map)
        let before = Date()
        state.openDetails()
        let started = try XCTUnwrap(state.flight?.startedAt)
        XCTAssertGreaterThanOrEqual(started, before)
        XCTAssertLessThanOrEqual(started.timeIntervalSince(before), 5)
    }

    // MARK: the pane closing takes the pointer's tile with it

    func testClosingThePaneForgetsTheTilesButNotTheBandsHover() {
        let state = WindowState(face: .map)
        state.openDetails()
        state.hoveredTile = "item:/a"
        state.focusedTile = "item:/b"
        state.bandHovered = true
        state.closeDetails()
        XCTAssertNil(state.hoveredTile)
        XCTAssertNil(state.focusedTile)
        XCTAssertTrue(state.bandHovered, "the pointer is still on the band")
    }
}

/// The time of the flights: a spring for the way out, an ease for the way back, and the rest of the curve the views need.
final class FlightClockTests: XCTestCase {
    func testTheSpringStartsAtRestAndSettlesOnItsTarget() {
        XCTAssertEqual(FlightClock.spring(at: -1), 0)
        XCTAssertEqual(FlightClock.spring(at: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(FlightClock.spring(at: 0.5), 1, accuracy: 0.01, "the perceptual duration is when it has settled")
        XCTAssertEqual(FlightClock.spring(at: 2), 1, accuracy: 1e-6)
    }

    func testTheSpringOvershootsABitAndNoMoreThanTheBounceAllows() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.005).map { FlightClock.spring(at: $0) }
        let peak = samples.max() ?? 0
        XCTAssertGreaterThan(peak, 1.0, "bounce 0.15 is a little more than the target")
        XCTAssertLessThan(peak, 1.02, "…and only a little")
    }

    func testTheSpringIsTheOneSwiftUIRuns() {
        let spring = Spring(duration: 0.5, bounce: 0.15)
        for time in stride(from: 0.0, through: 0.8, by: 0.04) {
            XCTAssertEqual(FlightClock.spring(at: time), spring.value(target: 1.0, initialVelocity: 0.0, time: time), accuracy: 1e-4, "t = \(time)")
        }
    }

    func testTheFlightIsTheSpringUntilItIsEasedOntoItsTargetAndThenExactlyThere() {
        for time in [0.0, 0.1, 0.25, 0.4, 0.5] {
            XCTAssertEqual(FlightClock.flight(at: time), FlightClock.spring(at: time), accuracy: 1e-12, "t = \(time)")
        }
        XCTAssertEqual(FlightClock.flight(at: -1), 0)
        XCTAssertEqual(FlightClock.flight(at: FlightClock.settle), 1, "exactly on its target: the tile can take over without a jump")
        XCTAssertEqual(FlightClock.flight(at: 5), 1)
        // the tail is eased out, never cut: no two moments a millisecond apart are further than a hair from each other
        var previous = FlightClock.flight(at: 0)
        for step in 1...800 {
            let value = FlightClock.flight(at: Double(step) / 1000)
            XCTAssertLessThan(abs(value - previous), 0.02, "t = \(step) ms")
            previous = value
        }
    }

    func testTheOvershootIsKeptUpToTheMomentTheTailIsEasedOut() {
        // the spring peaks a little before half a second; the tail after it is what is eased out
        let peak = stride(from: 0.0, through: FlightClock.settle, by: 0.005).map { FlightClock.flight(at: $0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.004)
        XCTAssertLessThan(FlightClock.unfoldDuration, FlightClock.settle)
        XCTAssertLessThanOrEqual(FlightClock.settle, 0.65, "a tile is not held back for long after it has stopped")
    }

    func testTheEaseOfTheWayBackTakesThreeHundredFiftyMilliseconds() {
        XCTAssertEqual(FlightClock.foldDuration, 0.35)
        XCTAssertEqual(FlightClock.ease(at: -1), 0)
        XCTAssertEqual(FlightClock.ease(at: 0), 0)
        XCTAssertEqual(FlightClock.ease(at: 0.175), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FlightClock.ease(at: 0.35), 1)
        XCTAssertEqual(FlightClock.ease(at: 9), 1)
        let samples = stride(from: 0.0, through: 0.35, by: 0.01).map { FlightClock.ease(at: $0) }
        XCTAssertEqual(samples, samples.sorted(), "it only ever goes forward")
    }

    func testTheTimesAreTheBoards() {
        XCTAssertEqual(FlightClock.unfoldDuration, 0.5)
        XCTAssertEqual(FlightClock.unfoldBounce, 0.15)
        XCTAssertEqual(FlightClock.stagger, 0.02)
        XCTAssertEqual(FlightClock.hoverDuration, 0.22)
    }

    func testSmoothstepIsZeroBeforeOneAfterAndHalfwayInTheMiddle() {
        XCTAssertEqual(FlightClock.smoothstep(0.2, 0.8, 0.1), 0)
        XCTAssertEqual(FlightClock.smoothstep(0.2, 0.8, 0.9), 1)
        XCTAssertEqual(FlightClock.smoothstep(0.2, 0.8, 0.5), 0.5, accuracy: 1e-12)
    }
}

final class MotionStyleFlightTests: XCTestCase {
    func testOnlyTheSpringFliesTheSlicesAndAnimatesTheMagnifier() {
        XCTAssertTrue(MotionStyle.spring.flies)
        XCTAssertTrue(MotionStyle.spring.animatesMagnifier)
        XCTAssertFalse(MotionStyle.crossfade.flies, "Reduce Motion: the pane fades, nothing flies")
        XCTAssertFalse(MotionStyle.crossfade.animatesMagnifier, "…and the band is magnified without animation")
    }

    func testTheCrossfadeIsTwoTenths() {
        XCTAssertEqual(MotionStyle.crossfade.duration, 0.2)
    }
}

/// The flights between the band's slices and the map's tiles, on the boards' layout: which leaves first, where from and to,
/// and how the flight looks at any moment.
final class UnfoldPlanTests: XCTestCase {
    private func map() throws -> MapModel {
        MapModel(selection: SelectionModel(plan: try TestPlans.fixture("plan-c.json")), size: CGSize(width: 416, height: 520), home: "/Users/test")
    }

    private func plan(
        _ direction: UnfoldPlan.Direction, enlarged: Bool = true, details: Bool = true, width: Double = 1100, height: Double = 720
    ) throws -> UnfoldPlan {
        let band = HeroLayout(screen: .rest, detailsOpen: details, mapOpen: false, width: width, height: height)
        return try XCTUnwrap(UnfoldPlan(
            direction: direction, map: try map(), capacity: 228_000_000_000, free: 19_800_000_000, band: band, enlarged: enlarged,
            windowWidth: width
        ))
    }

    // MARK: who goes first

    func testOneFlightPerTileAndTheLargestLeavesFirst() throws {
        let plan = try plan(.unfold)
        XCTAssertEqual(plan.flights.count, 10)
        let sizes = plan.flights.map(\.tile.bytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "largest first")
        XCTAssertEqual(plan.flights.first?.tile.title, "Docker")
    }

    func testTheyLeaveTwentyMillisecondsApart() throws {
        let plan = try plan(.unfold)
        XCTAssertEqual(plan.flights.map(\.delay).first, 0)
        for (index, flight) in plan.flights.enumerated() {
            XCTAssertEqual(flight.delay, Double(index) * 0.02, accuracy: 1e-12)
        }
    }

    func testTiesLeaveInTheMapsOrder() throws {
        // two tiles of one size: the one earlier in the layout goes first, so the order never shuffles between renders
        let plan = try plan(.unfold)
        let order = try map().tiles.map(\.id)
        for (a, b) in zip(plan.flights, plan.flights.dropFirst()) where a.tile.bytes == b.tile.bytes {
            XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: a.tile.id)), try XCTUnwrap(order.firstIndex(of: b.tile.id)))
        }
    }

    // MARK: where from and where to

    func testTheDockerTileLandsWhereTheBoardPutsIt() throws {
        let docker = try XCTUnwrap(try plan(.unfold).flights.first)
        // the map starts at (658, 86); Docker's tile is (3, 3, 410, 263) in it
        XCTAssertEqual(docker.tileRect.minX, 661, accuracy: 0.6)
        XCTAssertEqual(docker.tileRect.minY, 89, accuracy: 0.6)
        XCTAssertEqual(docker.tileRect.width, 410, accuracy: 0.6)
        XCTAssertEqual(docker.tileRect.height, 263, accuracy: 0.6)
    }

    func testTheEnlargedSlicesAreTheBandsOwnAtTheListsBandPosition() throws {
        let plan = try plan(.unfold, enlarged: true)
        let docker = try XCTUnwrap(plan.flights.first)
        // the band of the list's board: 72 in, 637 down; the end starts at 274.4 and is 10 pt thick
        XCTAssertEqual(docker.bandRect.minX, 72 + 274.4, accuracy: 0.6)
        XCTAssertEqual(docker.bandRect.minY, 637)
        XCTAssertEqual(docker.bandRect.height, 10)
        // 9 of 17.4 GB of the 189 pt between the points, less the 0.9 pt the thinnest slices are raised by
        XCTAssertEqual(docker.bandRect.width, 9.0 / 17.4 * (198.4 - 9), accuracy: 1.0)
    }

    func testABandThatWasNotHoveredLetsGoOfItsTrueWidthSlicesSixPointsThick() throws {
        let plan = try plan(.unfold, enlarged: false)
        let docker = try XCTUnwrap(plan.flights.first)
        XCTAssertEqual(docker.bandRect.height, 6)
        XCTAssertEqual(docker.bandRect.minY, 637)
        XCTAssertLessThan(docker.bandRect.width, 25, "the true width of 9 GB on a 520 pt band of 228 GB")
        let total = try plan.flights.map(\.bandRect.width).reduce(0, +)
        XCTAssertEqual(total, 17.4 / 228 * 520 - 9, accuracy: 0.6, "the slices together are the end's true width, less the points between them")
    }

    func testWithThePaneClosedTheBandIsTheWideOne() throws {
        let plan = try plan(.unfold, enlarged: false, details: false)
        let docker = try XCTUnwrap(plan.flights.first)
        XCTAssertEqual(docker.bandRect.minY, 637)
        XCTAssertGreaterThan(docker.bandRect.minX, 112, "the wide band starts 112 in and its end is far to the right")
        XCTAssertEqual(docker.tileRect.minX, 661, accuracy: 0.6, "the map is where it is, whichever band the slices left")
    }

    func testTheWayBackLeavesTheTilesAndLandsOnTheTrueWidthEndOfTheBand() throws {
        let plan = try plan(.fold, details: false)
        XCTAssertEqual(plan.direction, .fold)
        let docker = try XCTUnwrap(plan.flights.first)
        XCTAssertEqual(docker.bandRect.height, 6, "the band is its ordinary six points again")
        XCTAssertEqual(docker.tileRect.minX, 661, accuracy: 0.6)
        for flight in plan.flights { XCTAssertEqual(flight.delay, 0, "they all come back together") }
    }

    func testEveryFlightsLookIsItsSlicesLook() throws {
        let plan = try plan(.unfold)
        let magnifier = try XCTUnwrap(BandMagnifier(capacity: 228_000_000_000, free: 19_800_000_000, tiles: try map().tiles, width: 520))
        for flight in plan.flights {
            XCTAssertEqual(flight.look, magnifier.slice(for: flight.tile.id)?.look)
        }
    }

    // MARK: nothing to fly

    func testWithoutACapacityOrTilesThereIsNothingToFly() throws {
        let band = HeroLayout(screen: .rest, detailsOpen: true, mapOpen: false, width: 1100, height: 720)
        XCTAssertNil(UnfoldPlan(direction: .unfold, map: try map(), capacity: nil, free: 0, band: band, enlarged: true, windowWidth: 1100))
        let empty = MapModel(selection: SelectionModel(plan: try TestPlans.fixture("plan-empty.json")), size: CGSize(width: 416, height: 520), home: "/Users/test")
        XCTAssertNil(UnfoldPlan(direction: .unfold, map: empty, capacity: 228_000_000_000, free: 1, band: band, enlarged: true, windowWidth: 1100))
    }

    // MARK: how it looks at a moment

    func testBeforeItsTurnAFlightIsStillOnItsSliceAndWhenTheLastLandsEveryOneIsExactlyOnItsTile() throws {
        let plan = try plan(.unfold)
        let last = try XCTUnwrap(plan.flights.last)
        XCTAssertGreaterThan(last.delay, 0)
        XCTAssertEqual(plan.pose(of: last, at: 0).rect, last.bandRect)
        XCTAssertEqual(plan.pose(of: last, at: last.delay / 2).rect, last.bandRect, "it has not left yet")
        for flight in plan.flights {
            let landed = plan.pose(of: flight, at: plan.duration).rect
            XCTAssertEqual(landed.minX, flight.tileRect.minX, accuracy: 1e-9)
            XCTAssertEqual(landed.minY, flight.tileRect.minY, accuracy: 1e-9)
            XCTAssertEqual(landed.width, flight.tileRect.width, accuracy: 1e-9)
            XCTAssertEqual(landed.height, flight.tileRect.height, accuracy: 1e-9)
        }
    }

    func testAnUnfoldStartsAsTheSliceAndEndsAsTheTileWithoutEverFading() throws {
        let plan = try plan(.unfold)
        let docker = try XCTUnwrap(plan.flights.first)
        let start = plan.pose(of: docker, at: 0)
        XCTAssertEqual(start.tileWeight, 0, "the slice's own look")
        XCTAssertEqual(start.opacity, 1)
        let end = plan.pose(of: docker, at: plan.duration)
        XCTAssertEqual(end.tileWeight, 1, accuracy: 1e-9, "the tile's own look, as it will be when it lands")
        for time in stride(from: 0.0, through: plan.duration, by: 0.02) {
            XCTAssertEqual(plan.pose(of: docker, at: time).opacity, 1, "an unfold never fades: it is the tile arriving")
        }
    }

    func testAFoldStartsAsTheTileAndEndsAsNothingOnTheBand() throws {
        let plan = try plan(.fold, details: false)
        let docker = try XCTUnwrap(plan.flights.first)
        let start = plan.pose(of: docker, at: 0)
        XCTAssertEqual(start.rect, docker.tileRect)
        XCTAssertEqual(start.tileWeight, 1)
        XCTAssertEqual(start.opacity, 1)
        let end = plan.pose(of: docker, at: plan.duration)
        XCTAssertEqual(end.rect.minX, docker.bandRect.minX, accuracy: 1e-9)
        XCTAssertEqual(end.rect.height, docker.bandRect.height, accuracy: 1e-9)
        XCTAssertEqual(end.tileWeight, 0, accuracy: 1e-9)
        XCTAssertEqual(end.opacity, 0, accuracy: 1e-9, "arrived: it is the band's again")
    }

    func testTheDurationsAreTheLastToLeavePlusTheSpringAndThreeFiftyBack() throws {
        let unfold = try plan(.unfold)
        XCTAssertEqual(unfold.duration, 9 * 0.02 + FlightClock.settle + FlightClock.landingMargin, accuracy: 1e-9)
        XCTAssertEqual(try plan(.fold).duration, 0.35 + FlightClock.landingMargin, accuracy: 1e-9)
    }

    func testFlightsAreInTheSameCoordinatesWhateverTheWindow() throws {
        // the pane hugs the right edge: a wider window moves the tiles right by exactly as much
        let narrow = try XCTUnwrap(try plan(.unfold, width: 1100).flights.first).tileRect
        let wide = try XCTUnwrap(try plan(.unfold, width: 1300, height: 720).flights.first).tileRect
        XCTAssertEqual(wide.minX - narrow.minX, 200, accuracy: 1e-9)
        XCTAssertEqual(wide.minY, narrow.minY)
    }
}
