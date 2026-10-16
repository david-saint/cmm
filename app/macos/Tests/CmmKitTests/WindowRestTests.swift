import Observation
import XCTest
@testable import CmmKit

/// The window at rest, however it is opened (spec R12): the pane closed without a flight, nothing focused or hovered, the
/// person's ticks and choice of face left alone.
@MainActor
final class WindowRestTests: XCTestCase {
    func testAWindowWithTheMapOpenAndEverythingFocusedComesToRest() {
        let window = WindowState(detailsOpen: true, expanded: ["group-a"], face: .map)
        window.focusedTile = "tile-1"
        window.focusedRow = "row-1"
        window.hoveredTile = "tile-2"
        window.mapKeyboard = true
        window.pointerIsOnBand(over: "tile-2")
        window.scrollTarget = .review

        window.comeToRest()

        XCTAssertFalse(window.detailsOpen)
        XCTAssertNil(window.flight, "the pane closes without the fold: nobody saw it open")
        XCTAssertNil(window.focusedTile)
        XCTAssertNil(window.focusedRow)
        XCTAssertNil(window.hoveredTile)
        XCTAssertFalse(window.mapKeyboard)
        XCTAssertFalse(window.bandHovered)
        XCTAssertNil(window.scrollTarget)
        XCTAssertEqual(window.face, .map, "the face the person chose is kept")
        XCTAssertEqual(window.expanded, ["group-a"], "and so are the open groups")
    }

    func testAWindowAlreadyAtRestStaysAsItIs() {
        let window = WindowState(face: .list)
        window.comeToRest()
        XCTAssertFalse(window.detailsOpen)
        XCTAssertNil(window.flight)
        XCTAssertEqual(window.face, .list)
    }

    func testTheLastCleanedRowOpensThePaneOnHistoryAndNothingElse() {
        let window = WindowState(detailsOpen: true, face: .map)
        window.focusedTile = "tile-1"
        window.comeToRestOnHistory()
        XCTAssertTrue(window.detailsOpen)
        XCTAssertEqual(window.face, .history)
        XCTAssertNil(window.flight)
        XCTAssertNil(window.focusedTile)
        XCTAssertFalse(window.mapKeyboard)
    }

    func testTheTicksAreThePersonsAndAreNotReset() async throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let model = AppModel(client: FakeCmmClient(plan: plan))
        await model.scan()
        let lane = try XCTUnwrap(model.selection?.groups.first { $0.rule == "lane-deps" })
        model.toggle(lane)
        let ticked = model.selection?.selectedCount
        WindowState(detailsOpen: true).comeToRest()
        XCTAssertEqual(model.selection?.selectedCount, ticked)
    }
}

/// Following the models without a view.
@MainActor
final class WatchTests: XCTestCase {
    @MainActor
    @Observable
    final class Thing {
        var number = 0
        var word = "a"
    }

    func testEveryChangeIsReportedOnceItHasLanded() async {
        let thing = Thing()
        var seen: [Int] = []
        let watch = Watch({ thing.number }, changed: { seen.append($0) })
        XCTAssertEqual(watch.value, 0)
        thing.number = 1
        XCTAssertEqual(seen, [], "not before the change has landed")
        await eventuallyOnMain { seen == [1] }
        thing.number = 2
        await eventuallyOnMain { seen == [1, 2] }
        XCTAssertEqual(watch.value, 2)
    }

    func testAChangeBackToTheLastValueAndAChangeToSomethingUnreadAreNotReported() async {
        let thing = Thing()
        var seen: [Int] = []
        let watch = Watch({ thing.number }, changed: { seen.append($0) })
        thing.word = "b"  // not read
        thing.number = 1
        thing.number = 0  // back before the report
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seen, [])
        thing.number = 3
        await eventuallyOnMain { seen == [3] }
        withExtendedLifetime(watch) {}
    }

    func testACancelledWatchSaysNothingMore() async {
        let thing = Thing()
        var seen: [Int] = []
        let watch = Watch({ thing.number }, changed: { seen.append($0) })
        watch.cancel()
        thing.number = 5
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seen, [])
    }

    func testAWatchThatIsLetGoSaysNothingMore() async {
        let thing = Thing()
        var seen: [Int] = []
        var watch: Watch<Int>? = Watch({ thing.number }, changed: { seen.append($0) })
        XCTAssertNotNil(watch)
        watch = nil
        thing.number = 5
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seen, [])
    }
}
