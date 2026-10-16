import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// A window that stays where it is put, however far off the screen that is, so a test can have a real, key window with a real
/// first responder without showing anything to the person running it.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The keyboard and the pointer on the real views: the whole window is hosted in a window of its own and keys and clicks are
/// sent to it as the system sends them, so what is tested is what happens when a key is pressed, and not only what the logic
/// behind it would do. (Hovering is not here: SwiftUI's hover and tap gestures only answer the real pointer, which a test
/// cannot be; everything that is a button, which includes the band's slices and the map's tiles, answers a click.)
@MainActor
final class MapInteractionTests: XCTestCase {
    private enum Key {
        case up, down, left, right, home, end, space, `return`, escape

        var code: UInt16 {
            switch self {
            case .up: 126
            case .down: 125
            case .left: 123
            case .right: 124
            case .home: 115
            case .end: 119
            case .space: 49
            case .return: 36
            case .escape: 53
            }
        }

        var characters: String {
            switch self {
            case .up: "\u{F700}"
            case .down: "\u{F701}"
            case .left: "\u{F702}"
            case .right: "\u{F703}"
            case .home: "\u{F729}"
            case .end: "\u{F72B}"
            case .space: " "
            case .return: "\r"
            case .escape: "\u{1B}"
            }
        }
    }

    private struct Rig {
        let model: AppModel
        let state: WindowState
        let window: NSWindow
        let map: MapModel
        let client: FakeCmmClient
    }

    private let size = CGSize(width: 1100, height: 720)

    private func rig(detailsOpen: Bool = false, face: DetailsFace = .map) async throws -> Rig {
        _ = NSApplication.shared
        let client = FakeCmmClient(plan: try TestPlans.fixture("plan-c.json"))
        let model = AppModel(client: client, now: { BoardClock.finished })
        await model.scan()
        let state = WindowState(detailsOpen: detailsOpen, face: face)
        let hosting = NSHostingView(
            rootView: RootView(model: model, window: state, env: AppViewsTests.env).frame(width: size.width, height: size.height)
        )
        let window = OffscreenWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }
        let map = MapModel(selection: try XCTUnwrap(model.selection), size: HeroLayout.mapArea(windowHeight: size.height), home: "/Users/test")
        await settle()
        return Rig(model: model, state: state, window: window, map: map, client: client)
    }

    // MARK: sending events

    /// Lets the window do what it was asked: SwiftUI updates, tasks run, the focus system catches up.
    private func settle(_ seconds: Double = 0.25) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func eventually(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await settle(0.02) }
        XCTAssertTrue(condition(), what)
    }

    private func press(_ key: Key, in rig: Rig) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rig.window.windowNumber, context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
            isARepeat: false, keyCode: key.code
        )!
        NSApp.sendEvent(event)
        await settle(0.15)
    }

    /// A click at a point of the window, measured from its top left corner.
    private func click(_ point: CGPoint, in rig: Rig) async {
        func event(_ type: NSEvent.EventType, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: point.x, y: size.height - point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!
        }
        NSApp.sendEvent(event(.leftMouseDown, 1))
        NSApp.sendEvent(event(.leftMouseUp, 2))
        await settle(0.2)
    }

    private func tile(_ title: String, _ subtitle: String? = nil, in rig: Rig) throws -> MapTile {
        try XCTUnwrap(rig.map.tiles.first { $0.title == title && $0.subtitle == subtitle }, title)
    }

    /// Where a tile is in the window.
    private func centre(of tile: MapTile) -> CGPoint {
        let origin = HeroLayout.mapOrigin(windowWidth: size.width)
        return CGPoint(x: origin.x + tile.rect.midX, y: origin.y + tile.rect.midY)
    }

    private func ticked(_ rig: Rig) -> Int { rig.model.selection?.selectedCount ?? -1 }

    // MARK: the review link

    func testTheReviewLinkOpensTheMapOnDockerAndTheKeyboardIsThereWithoutAClick() async throws {
        let rig = try await rig()
        XCTAssertFalse(rig.state.detailsOpen)
        await click(CGPoint(x: 330, y: 531), in: rig)  // "Review 9.0 GB more"
        let docker = try tile("Docker", in: rig)

        XCTAssertTrue(rig.state.mapOpen)
        XCTAssertEqual(rig.state.focusedTile, docker.id, "the tile that needs a look is the one under the keyboard")
        XCTAssertEqual(rig.state.flight?.kind, .unfold, "the band's slices lift into the map")
        await eventually("the flight lands") { rig.state.flight == nil }
        await eventually("the map has the keyboard") { rig.state.mapKeyboard }

        let before = ticked(rig)
        await press(.space, in: rig)
        XCTAssertEqual(ticked(rig), before + 3, "Space ticks Docker's three cleanups, with no click on the map first")
        await press(.space, in: rig)
        XCTAssertEqual(ticked(rig), before)
    }

    func testShowDetailsOpensTheRememberedFaceAndUnfoldsTheMapOnly() async throws {
        let rig = try await rig(face: .list)
        await click(CGPoint(x: 1100 - 20 - 15, y: 14 + 15), in: rig)  // Show details
        XCTAssertTrue(rig.state.detailsOpen)
        XCTAssertNil(rig.state.flight, "the list has no tiles to fly into")
        XCTAssertFalse(rig.state.mapOpen)
    }

    // MARK: the arrows, with or without a click

    func testAnArrowFocusesTheFirstTileAndGivesTheMapTheKeyboard() async throws {
        let rig = try await rig(detailsOpen: true)
        XCTAssertNil(rig.state.focusedTile)
        await press(.down, in: rig)
        XCTAssertEqual(rig.state.focusedTile, rig.map.tiles.first?.id, "no focus yet: any arrow starts at the first tile")
        await eventually("the map has the keyboard") { rig.state.mapKeyboard }
    }

    func testTheArrowsMoveToTheNeighbouringTilesAsTheLogicSaysTheyDo() async throws {
        let rig = try await rig(detailsOpen: true)
        let docker = try tile("Docker", in: rig)
        let uv = try tile("uv cache", "~/.cache/uv", in: rig)
        let laneA = try tile("lane-a", "node_modules", in: rig)

        await press(.home, in: rig)
        XCTAssertEqual(rig.state.focusedTile, docker.id)
        await press(.down, in: rig)
        XCTAssertEqual(rig.state.focusedTile, uv.id, "below Docker's middle is uv's tile")
        await press(.left, in: rig)
        XCTAssertEqual(rig.state.focusedTile, laneA.id)
        await press(.right, in: rig)
        XCTAssertEqual(rig.state.focusedTile, uv.id)
        await press(.up, in: rig)
        XCTAssertEqual(rig.state.focusedTile, docker.id)
        await press(.end, in: rig)
        XCTAssertEqual(rig.state.focusedTile, rig.map.tiles.last?.id)
        await press(.home, in: rig)
        XCTAssertEqual(rig.state.focusedTile, rig.map.tiles.first?.id)
    }

    func testAnArrowIsOneStepNotTwo() async throws {
        // a key equivalent and a key press both exist for the arrows; one press must be one step
        let rig = try await rig(detailsOpen: true)
        await press(.home, in: rig)
        await press(.down, in: rig)
        await press(.down, in: rig)
        let expected = MapNavigation.handle(.down, focused: try tile("uv cache", "~/.cache/uv", in: rig).id, in: rig.map)
        XCTAssertEqual(expected, .focus(try tile("Go build cache", "~/Library/Caches/go-build", in: rig).id))
        XCTAssertEqual(rig.state.focusedTile, try tile("Go build cache", "~/Library/Caches/go-build", in: rig).id)
    }

    func testSpaceAndReturnTickTheFocusedTileAndNothingIsTickedWithNoFocus() async throws {
        let rig = try await rig(detailsOpen: true)
        let before = ticked(rig)
        await press(.space, in: rig)
        XCTAssertEqual(ticked(rig), before, "no tile has the focus: nothing is ticked")

        await press(.down, in: rig)  // Docker
        await press(.down, in: rig)  // uv cache: ticked, so Space unticks it
        let uv = try tile("uv cache", "~/.cache/uv", in: rig)
        XCTAssertEqual(rig.state.focusedTile, uv.id)
        await press(.space, in: rig)
        XCTAssertEqual(ticked(rig), before - 1)
        await press(.return, in: rig)
        XCTAssertEqual(ticked(rig), before)
    }

    func testClickingATileFocusesItTicksItAndGivesTheMapTheKeyboard() async throws {
        let rig = try await rig(detailsOpen: true)
        let go = try tile("Go build cache", "~/Library/Caches/go-build", in: rig)
        let before = ticked(rig)
        await click(centre(of: go), in: rig)
        XCTAssertEqual(rig.state.focusedTile, go.id)
        XCTAssertEqual(ticked(rig), before - 1)
        await eventually("the map has the keyboard") { rig.state.mapKeyboard }
        await press(.right, in: rig)
        XCTAssertEqual(rig.state.focusedTile, try tile("Homebrew", in: rig).id, "the arrows go on from the tile that was clicked")
    }

    // MARK: Esc, the card, the list

    func testEscClosesThePaneAndTheSlicesFoldBackIntoTheBand() async throws {
        let rig = try await rig(detailsOpen: true)
        await press(.escape, in: rig)
        XCTAssertFalse(rig.state.detailsOpen)
        XCTAssertEqual(rig.state.flight?.kind, .fold)
        await eventually("the fold lands") { rig.state.flight == nil }
    }

    func testWhileTheCardIsUpTheMapsKeysDoNothingAndEscCancelsTheCardFirst() async throws {
        let rig = try await rig(detailsOpen: true)
        await press(.home, in: rig)
        let focused = rig.state.focusedTile
        let before = ticked(rig)

        rig.model.requestClean()
        XCTAssertNotNil(rig.model.confirmation)
        await settle()
        await press(.down, in: rig)
        await press(.space, in: rig)
        await press(.end, in: rig)
        XCTAssertEqual(rig.state.focusedTile, focused, "the screen behind the card is disabled: so are its keys")
        XCTAssertEqual(ticked(rig), before)
        XCTAssertNotNil(rig.model.confirmation)

        await press(.escape, in: rig)
        XCTAssertNil(rig.model.confirmation, "Esc cancels the card")
        XCTAssertTrue(rig.state.detailsOpen, "…and nothing else: the pane stays")
        XCTAssertEqual(rig.client.applyCalls.count, 0, "nothing was removed: a cancelled card runs nothing")
    }

    func testBehindTheCardNothingTakesTheArrowsEvenWithNoFocusYet() async throws {
        let rig = try await rig(detailsOpen: true)
        rig.model.requestClean()
        await settle()
        await press(.down, in: rig)
        await press(.home, in: rig)
        XCTAssertNil(rig.state.focusedTile, "the arrows are key equivalents of the map: the card's disabled screen has none")
    }

    func testTheListLeavesItsKeysAloneBehindTheCardToo() async throws {
        let rig = try await rig(detailsOpen: true, face: .list)
        await click(CGPoint(x: 800, y: 187), in: rig)  // the uv cache row: it takes the keyboard (and ticks)
        let focused = try XCTUnwrap(rig.state.focusedRow)
        let before = ticked(rig)
        rig.model.requestClean()
        await settle()
        await press(.down, in: rig)
        await press(.space, in: rig)
        XCTAssertEqual(rig.state.focusedRow, focused)
        XCTAssertEqual(ticked(rig), before)
    }

    func testTheListFaceKeepsTheMapsKeysOutOfIt() async throws {
        let rig = try await rig(detailsOpen: true, face: .list)
        await press(.down, in: rig)
        await press(.end, in: rig)
        XCTAssertNil(rig.state.focusedTile, "the map's keys exist only while the map is showing")
        XCTAssertFalse(rig.state.mapKeyboard)
    }

    // MARK: the band's slices

    private func slice(_ title: String, in rig: Rig, layout: HeroLayout) throws -> (tile: MapTile, spot: CGPoint) {
        let tile = try tile(title, title == "uv cache" ? "~/.cache/uv" : nil, in: rig)
        let host = try XCTUnwrap(rig.model.selection?.plan.host)
        let magnifier = try XCTUnwrap(BandMagnifier(capacity: host.capacityBytes, free: host.freeBytes, tiles: rig.map.tiles, width: layout.bandWidth))
        let slice = try XCTUnwrap(magnifier.slice(for: tile.id))
        return (tile, CGPoint(x: layout.bandLeading + slice.x + slice.width / 2, y: layout.bandLineTop + 5))
    }

    func testAClickOnASliceOfTheHoveredBandOpensTheMapOnThatTile() async throws {
        let rig = try await rig()
        rig.state.bandHovered = true  // the pointer is on the band: its end is enlarged and its slices are there to click
        await settle()
        let target = try slice("uv cache", in: rig, layout: HeroLayout(screen: .rest, detailsOpen: false, mapOpen: false, width: 1100, height: 720))
        await click(target.spot, in: rig)

        XCTAssertTrue(rig.state.mapOpen)
        XCTAssertEqual(rig.state.focusedTile, target.tile.id)
        let flight = try XCTUnwrap(rig.state.flight)
        XCTAssertEqual(flight.kind, .unfold)
        XCTAssertTrue(flight.bandWasMagnified, "the slice left an end that was already enlarged")
        await eventually("the flight lands") { rig.state.flight == nil }
        await eventually("the map has the keyboard") { rig.state.mapKeyboard }
        XCTAssertEqual(ticked(rig), 9, "a click on a slice only opens: it ticks nothing")
    }

    func testAClickOnASliceWhileTheMapIsOpenOnlyMovesTheFocus() async throws {
        let rig = try await rig(detailsOpen: true)
        let target = try slice("uv cache", in: rig, layout: HeroLayout(screen: .rest, detailsOpen: true, mapOpen: true, width: 1100, height: 720))
        await click(target.spot, in: rig)
        XCTAssertEqual(rig.state.focusedTile, target.tile.id)
        XCTAssertNil(rig.state.flight, "the map is open: nothing to unfold")
        XCTAssertEqual(ticked(rig), 9)
        await eventually("the map has the keyboard") { rig.state.mapKeyboard }
    }

    func testTheBandHasNoSlicesToClickUntilItIsMagnified() async throws {
        let rig = try await rig()
        let target = try slice("uv cache", in: rig, layout: HeroLayout(screen: .rest, detailsOpen: false, mapOpen: false, width: 1100, height: 720))
        await click(target.spot, in: rig)
        XCTAssertFalse(rig.state.detailsOpen, "a thin, ordinary band is not a button")
    }
}
