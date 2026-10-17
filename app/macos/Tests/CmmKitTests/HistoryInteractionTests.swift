import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The History face's keys, clicks and reads on the real views: the whole window is hosted in a window of its own, kept off every
/// screen, and keys and clicks are sent to it as the system sends them (as `MapInteractionTests` does for the map). One fake cmm
/// serves the window and the History, as in the app, so what is asked of cmm can be counted. (Hovering is not here: SwiftUI's
/// hover answers only the real pointer; the read-out is drawn from a pointer time a test sets, see `HistoryViewsTests`.)
@MainActor
final class HistoryInteractionTests: XCTestCase {
    private enum Key {
        case up, down, left, right, home, end, space, `return`, escape, tab

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
            case .tab: 48
            }
        }

        var flags: NSEvent.ModifierFlags {
            switch self {
            case .up, .down, .left, .right: [.numericPad, .function]
            case .home, .end: [.function]
            case .space, .return, .escape, .tab: []
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
            case .tab: "\t"
            }
        }
    }

    private struct Rig {
        let model: AppModel
        let state: WindowState
        let face: HistoryFaceState
        let history: HistoryModel
        let client: FakeCmmClient
        let window: NSWindow
        /// The board's cleanings, newest first.
        let rows: [RunRows.Row]
    }

    private let size = CGSize(width: 1100, height: 720)

    /// The window at rest on the board's plan, the History model and the window sharing one fake cmm. `report` is what the
    /// History reads (the board's four cleanings unless given); `env` draws the ring only where the keyboard is when its
    /// `showsFocusWithoutKeyboard` is off, as in the app.
    private func rig(
        detailsOpen: Bool = true, face: DetailsFace = .history, report given: HistoryReport? = nil,
        histories: [Result<HistoryReport, CmmError>]? = nil, laterScans: [Result<Plan, CmmError>] = [],
        env: ViewEnvironment = HistoryViewsTests.env
    ) async throws -> Rig {
        _ = NSApplication.shared
        let report = try given ?? HistoryBoard.report()
        let client = FakeCmmClient(
            plans: [.success(try TestPlans.fixture("plan-c.json"))] + laterScans, histories: histories ?? [.success(report)]
        )
        let model = AppModel(client: client, now: { HistoryBoard.now })
        await model.scan()
        let history = HistoryModel(client: client)
        let state = WindowState(detailsOpen: detailsOpen, face: face)
        let faceState = HistoryFaceState()
        let hosting = NSHostingView(
            rootView: RootView(model: model, window: state, env: env)
                .environment(history)
                .environment(faceState)
                .frame(width: size.width, height: size.height)
        )
        let window = OffscreenWindow(size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }
        await settle(0.4)
        let rows = RunRows(report: report, now: HistoryBoard.now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale, home: "/Users/test").listed
        guard given != nil || rows.count == 4 else { throw SamplerStuck("the board has four cleanings") }
        return Rig(model: model, state: state, face: faceState, history: history, client: client, window: window, rows: rows)
    }

    // MARK: sending events

    private func settle(_ seconds: Double = 0.25) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    private func eventually(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await settle(0.02) }
        XCTAssertTrue(condition(), what)
        return condition()
    }

    private func press(_ key: Key, plus extra: NSEvent.ModifierFlags = [], in rig: Rig) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.flags.union(extra), timestamp: ProcessInfo.processInfo.systemUptime,
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

    /// The first line of the first cleaning (Docker's, "Tue 14 Oct 14:20"), as the board's data draws it in this window.
    private let firstRow = CGPoint(x: 800, y: 346)

    // MARK: clicks and keys

    func testAClickOnACleaningOpensItAndGivesTheListTheKeyboard() async throws {
        let rig = try await rig()
        await click(firstRow, in: rig)
        let docker = rig.rows[0].id
        XCTAssertEqual(rig.face.focusedRun, docker, "the clicked cleaning has the keyboard")
        XCTAssertEqual(rig.face.expanded, [docker], "and is open")
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows[1].id, "the list has the keyboard: Down goes on from the clicked row")
    }

    func testTheListsKeysAreTheListsKeys() async throws {
        let rig = try await rig()
        await click(firstRow, in: rig)  // Docker's cleaning, now open
        let ids = rig.rows.map(\.id)

        await press(.left, in: rig)
        XCTAssertEqual(rig.face.expanded, [], "Left closes the open cleaning")
        await press(.right, in: rig)
        XCTAssertEqual(rig.face.expanded, [ids[0]], "Right opens it")
        await press(.space, in: rig)
        XCTAssertEqual(rig.face.expanded, [], "Space closes it")
        await press(.return, in: rig)
        XCTAssertEqual(rig.face.expanded, [ids[0]], "Return opens it")

        await press(.down, in: rig)
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, ids[2], "Down, Down: the third cleaning")
        await press(.right, in: rig)
        XCTAssertEqual(rig.face.expanded, [ids[0], ids[2]])
        await press(.up, in: rig)
        XCTAssertEqual(rig.face.focusedRun, ids[1])
        await press(.end, in: rig)
        XCTAssertEqual(rig.face.focusedRun, ids[3])
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, ids[3], "the last stays the last")
        await press(.home, in: rig)
        XCTAssertEqual(rig.face.focusedRun, ids[0])
    }

    func testAShortcutThatUsesAnArrowIsNotTheListsArrow() async throws {
        let rig = try await rig()
        await click(firstRow, in: rig)
        let focused = rig.face.focusedRun
        let open = rig.face.expanded
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control] {
            await press(.down, plus: modifier, in: rig)
            await press(.left, plus: modifier, in: rig)
            await press(.end, plus: modifier, in: rig)
            XCTAssertEqual(rig.face.focusedRun, focused, "\(modifier) with an arrow, Home or End is not a move")
            XCTAssertEqual(rig.face.expanded, open, "\(modifier) with Left closes nothing")
        }
        await press(.down, plus: .shift, in: rig)
        XCTAssertNotEqual(rig.face.focusedRun, focused, "Shift does not make an arrow something else")
    }

    func testBehindTheCardTheListsKeysDoNothingAndEscCancelsTheCardFirst() async throws {
        let rig = try await rig()
        await click(firstRow, in: rig)
        let focused = rig.face.focusedRun
        let open = rig.face.expanded

        rig.model.requestClean()
        XCTAssertNotNil(rig.model.confirmation)
        await settle()
        // (Return is left out: behind the card it belongs to the card, whose default button is Cancel)
        for key in [Key.down, .space, .left, .end, .up, .right] { await press(key, in: rig) }
        XCTAssertEqual(rig.face.focusedRun, focused, "the screen behind the card is disabled: so are the list's keys")
        XCTAssertEqual(rig.face.expanded, open)
        XCTAssertNotNil(rig.model.confirmation, "the list's keys did not answer the card")

        await press(.escape, in: rig)
        XCTAssertNil(rig.model.confirmation, "Esc cancels the card")
        XCTAssertTrue(rig.state.detailsOpen, "and nothing else: the pane stays")
        XCTAssertEqual(rig.client.applyCalls.count, 0, "nothing was removed")
    }


    func testTabReachesTheListAsItReachesTheList() async throws {
        // The pane opened after the window took the keyboard: nothing in it has the keyboard yet. Tab is the window's
        // `selectNextKeyView` (sent here directly: a synthetic Tab key event is not routed in this offscreen window while
        // nothing in it is focused), and it gives the list the keyboard, as it gives it to the List.
        let rig = try await rig(detailsOpen: false)
        rig.state.openHistory()
        await eventually("the face is there and has read the history") { rig.history.report != nil }
        await settle()
        await press(.down, in: rig)
        XCTAssertNil(rig.face.focusedRun, "before Tab, the list does not have the keyboard")
        rig.window.selectNextKeyView(nil)
        await settle(0.1)
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows[0].id, "after Tab, Down goes to the first cleaning")
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows[1].id)
    }

    func testWhenThePaneOpensOnHistoryTheListHasTheKeyboardAsTheListDoes() async throws {
        // The List's own behaviour, found by pressing keys through this window: the pane's list is the window's first stop, so
        // it has the keyboard as soon as the pane is open, and Down goes to the first row with no click first.
        let rig = try await rig()
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows[0].id)
        await press(.space, in: rig)
        XCTAssertEqual(rig.face.expanded, [rig.rows[0].id])
    }

    func testAClickGivesTheListTheKeyboardWhenItDidNotHaveIt() async throws {
        // the pane opened after the window took the keyboard, so the list does not have it (as in the Tab test)
        let rig = try await rig(detailsOpen: false)
        rig.state.openHistory()
        await eventually("the face is there and has read the history") { rig.history.report != nil }
        await settle()
        await press(.down, in: rig)
        XCTAssertNil(rig.face.focusedRun, "before the click, the list does not have the keyboard")
        await click(firstRow, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows[0].id)
        await press(.down, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows[1].id, "after it, Down goes on from the clicked cleaning")
    }

    // MARK: where the keyboard is

    /// How many pixels of the first cleaning's band (y 336 to 372 of this window, across the pane) are the accent's green. The
    /// first cleaning is Docker's and closed: its figure's outline is amber and it has no ticks, so green there is the ring.
    private func ringPixels(in rig: Rig) throws -> Int {
        let view = try XCTUnwrap(rig.window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / size.width
        var count = 0
        for y in Int(336 * scale)..<Int(372 * scale) {
            for x in Int(636 * scale)..<Int(1096 * scale) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.greenComponent - max(c.redComponent, c.blueComponent) > 0.12 { count += 1 }
            }
        }
        return count
    }

    func testTheRingIsOnlyWhereTheKeyboardIs() async throws {
        var env = HistoryViewsTests.env
        env.showsFocusWithoutKeyboard = false  // as in the app
        let rig = try await rig(detailsOpen: false, env: env)
        rig.state.openHistory()
        await eventually("the face is there and has read the history") { rig.history.report != nil }
        await settle()
        rig.face.focusedRun = rig.rows[0].id
        await settle()
        XCTAssertEqual(try ringPixels(in: rig), 0, "the list does not have the keyboard: its cleaning has no ring")

        rig.window.selectNextKeyView(nil)  // Tab
        await settle()
        XCTAssertGreaterThan(try ringPixels(in: rig), 20, "the list has the keyboard: the ring is on its cleaning")
        XCTAssertEqual(rig.face.focusedRun, rig.rows[0].id)

        rig.window.makeFirstResponder(nil)  // the keyboard goes elsewhere
        await settle()
        XCTAssertEqual(try ringPixels(in: rig), 0, "and the ring goes with it")
    }

    /// Thirty cleanings two hours apart, each with an item to open: a list longer than the window.
    private func longReport() throws -> HistoryReport {
        let runs = (0..<30).map { index in
            HistoryJSON.run(
                finished: HistoryBoard.iso(HistoryBoard.now.addingTimeInterval(-Double(index) * 7_200 - 600)), freed: gigabytes(0.5),
                items: [HistoryJSON.item(rule: "uv-cache", group: "uv cache", path: "/Users/test/.cache/uv", bytes: gigabytes(0.5))]
            )
        }
        return try HistoryBoard.report(runs: runs, samples: [])
    }

    /// The face's scroll view: the pane's, right of the rest screen.
    private func faceScrollView(in rig: Rig) throws -> NSScrollView {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let inPane = scrollViews(in: try XCTUnwrap(rig.window.contentView)).filter { $0.convert($0.bounds, to: nil).minX > 600 }
        return try XCTUnwrap(inPane.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    func testTheListFollowsTheKeyboardToACleaningOutOfSight() async throws {
        let rig = try await rig(report: try longReport())
        guard rig.rows.count == 30 else { return XCTFail("thirty cleanings, not \(rig.rows.count)") }
        let scroll = try faceScrollView(in: rig)
        let top = scroll.contentView.bounds.origin.y
        func offset() -> Double { abs(scroll.contentView.bounds.origin.y - top) }
        func reach() -> Double { (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height }
        XCTAssertGreaterThan(reach(), 300, "thirty cleanings are longer than the pane")

        await press(.end, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows.last?.id)
        await eventually("End scrolls the list down to the last cleaning") { offset() > 300 }
        await settle()
        XCTAssertLessThan(reach() - offset(), 40, "as far as the last cleaning: it is in sight at the foot of the pane")

        await press(.home, in: rig)
        XCTAssertEqual(rig.face.focusedRun, rig.rows.first?.id)
        await eventually("and Home back up to the first") { offset() < 1 }

        // one at a time: the fifteenth cleaning is past the pane's foot, and Down brings it up
        for _ in 0..<14 { await press(.down, in: rig) }
        XCTAssertEqual(rig.face.focusedRun, rig.rows[14].id)
        await eventually("Down past the foot of the pane scrolls the list") { offset() > 0 }
    }

    // MARK: reading

    func testTheFaceReadsTheHistoryEachTimeItAppearsAndOnlyThen() async throws {
        let rig = try await rig(detailsOpen: false, face: .history)
        await settle()
        XCTAssertEqual(rig.client.historyCalls, 0, "the pane is closed: nothing is read")
        rig.state.openHistory()
        await eventually("the face read the history when it appeared") { rig.client.historyCalls == 1 }
        await eventually("and shows it") { rig.history.report != nil }
        rig.state.setFace(.list)
        await settle()
        XCTAssertEqual(rig.client.historyCalls, 1, "the List does not read the history")
        rig.state.setFace(.history)
        await eventually("back on History, it reads again") { rig.client.historyCalls == 2 }
        XCTAssertEqual(rig.client.planCalls, 1, "and asks cmm for nothing else")
        XCTAssertTrue(rig.client.applyCalls.isEmpty)
    }

    func testACleaningThatEndsIsReadEvenWithThePaneClosed() async throws {
        let rig = try await rig(detailsOpen: false)
        rig.client.script(.replay([Events.start(selected: 9, free: gigabytes(19.8)), Events.done(deleted: 9, freed: gigabytes(8.4))], error: nil))
        await settle()
        XCTAssertEqual(rig.client.historyCalls, 0)

        rig.model.requestClean()
        await rig.model.confirmClean(try XCTUnwrap(rig.model.confirmation))
        XCTAssertEqual(rig.model.phase, .done)
        await eventually("the cleaning that ended was read") { rig.client.historyCalls == 1 }
        await eventually("so the History holds it before the pane is opened again") { rig.history.phase == .loaded }

        // Done scans again: that is not a cleaning ending, and nothing more is read
        await rig.model.scan()
        await settle()
        XCTAssertEqual(rig.client.historyCalls, 1)
    }

    func testACleaningThatFailsPartwayIsReadToo() async throws {
        // as with the real cmm, the cleaning screen is up while cmm works, and then the run fails
        let rig = try await rig(detailsOpen: false)
        rig.client.script(.live)
        rig.model.requestClean()
        let confirmation = try XCTUnwrap(rig.model.confirmation)
        let cleaning = Task { await rig.model.confirmClean(confirmation) }
        let started = await rig.client.waitForApply(timeout: 3)
        XCTAssertTrue(started)
        await eventually("the cleaning screen is up") { rig.model.phase == .cleaning }
        await settle()
        rig.client.send(Events.start(selected: 9))
        rig.client.send(Events.item("/Users/test/.cache/uv"))
        rig.client.finish(throwing: .applyFailed(status: 1, stderr: "cmm: the volume went away"))
        await cleaning.value
        XCTAssertEqual(rig.model.phase, .failed)
        await eventually("cmm may have written down what it did before it failed") { rig.client.historyCalls == 1 }
    }

    func testAScanThatFailsReadsNothing() async throws {
        let rig = try await rig(detailsOpen: false, laterScans: [.failure(.planFailed(status: 2, stderr: "cmm: no disk"))])
        await rig.model.scan()
        XCTAssertEqual(rig.model.phase, .failed, "the second scan failed")
        await settle()
        XCTAssertEqual(rig.client.historyCalls, 0, "a scan cleaned nothing, so there is nothing new to read")
    }

    func testAScanAloneReadsNothing() async throws {
        let rig = try await rig(detailsOpen: false)
        await rig.model.scan()
        await rig.model.scan()
        await settle()
        XCTAssertEqual(rig.client.historyCalls, 0)
    }
}
