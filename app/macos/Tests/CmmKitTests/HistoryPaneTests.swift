import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// Where the History can be seen on its own (`HistoryPaneRule`) and when ⌘I works: pure, so every screen is checked.
final class HistoryPaneRuleTests: XCTestCase {
    private let phases: [AppModel.Phase] = [.idle, .scanning, .ready, .empty, .cleaning, .done, .failed]

    func testTheHistoryPaneIsOnEveryScreenButTheRestAndTheCleaningScreensWheneverThePaneIsOpen() {
        for phase in phases {
            let room = phase != .ready && phase != .cleaning
            XCTAssertEqual(HistoryPaneRule.hasRoom(in: phase), room, "\(phase)")
            XCTAssertEqual(HistoryPaneRule.shows(phase: phase, detailsOpen: true, face: .history), room, "\(phase), open on History")
            XCTAssertFalse(HistoryPaneRule.shows(phase: phase, detailsOpen: false, face: .history), "\(phase), closed")
        }
    }

    /// Decided at the merge: a pane left open on the List or the map is not the History, so only the nothing-to-clean screen
    /// (whose own button opens it) shows the History pane for those faces.
    func testAPaneLeftOpenOnTheListOrTheMapIsNotTheHistoryExceptOnTheNothingToCleanScreen() {
        for face in [DetailsFace.list, .map] {
            for phase in phases {
                let expected = phase == .empty
                XCTAssertEqual(HistoryPaneRule.shows(phase: phase, detailsOpen: true, face: face), expected, "\(phase) on \(face)")
            }
        }
    }

    func testOnlyACleaningThatStartsTakesThePaneAway() throws {
        for phase in phases { XCTAssertEqual(HistoryPaneRule.closesPane(whenPhaseBecomes: phase), phase == .cleaning, "\(phase)") }
        let root = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Cmm/RootView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("HistoryPaneRule.closesPane(whenPhaseBecomes: phase)"), "the window asks the rule")
    }

    func testShowDetailsWorksOnTheRestAndNothingToCleanScreensAndNeverBehindTheCard() {
        for phase in phases {
            for card in [false, true] {
                let works = (phase == .ready || phase == .empty) && !card
                XCTAssertEqual(HistoryPaneRule.detailsCommandWorks(phase: phase, confirmationOpen: card), works, "\(phase), card \(card)")
            }
        }
    }

    // MARK: the sources that use it (a Commands body and a view's switch cannot be looked into from a test)

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/Cmm")

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheMenusShowDetailsAsksTheRule() throws {
        let app = try source("CmmApp.swift")
        XCTAssertTrue(app.contains(
            ".disabled(!HistoryPaneRule.detailsCommandWorks(phase: model.phase, confirmationOpen: model.confirmation != nil))"
        ))
        XCTAssertTrue(app.contains(#"Button(window.detailsOpen ? "Hide Details" : "Show Details") { window.toggleDetails() }"#))
    }

    func testTheWindowPutsThePaneOverItsScreensOnceAndGivesTheEmptyScreenTheWindowState() throws {
        let root = try source("RootView.swift")
        XCTAssertEqual(root.components(separatedBy: "PaneOverlay(").count - 1, 1)
        XCTAssertTrue(root.contains(".overlay { PaneOverlay(model: model, window: window) }"))
        XCTAssertTrue(root.contains("case .empty: EmptyScreen(model: model, window: window)"))
        let overlay = try source("PaneOverlay.swift")
        XCTAssertTrue(overlay.contains("HistoryPaneRule.hasRoom(in: model.phase)"))
        XCTAssertTrue(overlay.contains("if HistoryPaneRule.shows(phase: model.phase, detailsOpen: window.detailsOpen, face: window.face) {"))
    }
}

/// The nothing-to-clean screen with the pane open is laid out as the rest screen is with the pane open (the board `C-History`:
/// the headline at 72 and 150, the number 136, the band 520 wide and stopping before the pane); the other screens do not move.
final class EmptyScreenLayoutTests: XCTestCase {
    func testWithThePaneOpenTheEmptyScreenIsLaidOutAsTheRestScreen() {
        for (width, height) in [(1100.0, 720.0), (820, 560), (1400, 900), (1600, 1000)] {
            let empty = HeroLayout(screen: .empty, detailsOpen: true, width: width, height: height)
            XCTAssertEqual(empty, HeroLayout(screen: .rest, detailsOpen: true, width: width, height: height), "\(width) x \(height)")
            // the window may remember the map, but this pane has none: the band does not rise for it
            XCTAssertEqual(HeroLayout(screen: .empty, detailsOpen: true, mapOpen: true, width: width, height: height), empty)
        }
        let board = HeroLayout(screen: .empty, detailsOpen: true, width: 1100, height: 720)
        XCTAssertEqual(board.leading, 72)
        XCTAssertEqual(board.top, 150)
        XCTAssertEqual(board.numberSize, 136)
        XCTAssertEqual(board.bandWidth, 520)
        XCTAssertEqual(board.bandTop, 720 - 108)
    }

    func testWithThePaneClosedTheEmptyScreenIsWhereItWas() {
        let empty = HeroLayout(screen: .empty, width: 1100, height: 720)
        XCTAssertEqual(empty.leading, 112)
        XCTAssertEqual(empty.top, 172)
        XCTAssertEqual(empty.numberSize, 184)
        XCTAssertEqual(empty.bandWidth, 876)
        XCTAssertEqual(empty, HeroLayout(screen: .empty, detailsOpen: false, mapOpen: true, width: 1100, height: 720))
    }

    func testTheOtherScreensKeepTheirPlacesUnderThePane() {
        for screen in [HeroLayout.Screen.cleaning, .done, .message] {
            XCTAssertEqual(
                HeroLayout(screen: screen, detailsOpen: true, mapOpen: true, width: 1100, height: 720),
                HeroLayout(screen: screen, width: 1100, height: 720), "\(screen)"
            )
        }
    }
}

/// The History-only pane in the real window (kept off every screen), read from its accessibility tree as VoiceOver finds it:
/// on each screen it has room on, opened as the menu bar opens it and closed by Esc; never on the cleaning screen; the rest
/// screen's own pane unchanged on its three faces; the nothing-to-clean screen's buttons, the face it leaves for the next rest
/// screen, the opt-in card that steps aside, and clicks that still reach the screen where the pane is not.
@MainActor
final class HistoryPaneWindowTests: XCTestCase {
    private struct Node {
        let object: NSObject

        var role: String { (object.value(forKey: "accessibilityRole") as? String) ?? "" }
        var label: String { (object.value(forKey: "accessibilityLabel") as? String) ?? "" }
        var value: String { object.value(forKey: "accessibilityValue").map { String(describing: $0) } ?? "" }
        var help: String { (object.value(forKey: "accessibilityHelp") as? String) ?? "" }
        var identifier: String { (object.value(forKey: "accessibilityIdentifier") as? String) ?? "" }
        var frame: CGRect { (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var children: [Node] { ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(Node.init) } }

        func all(where test: (Node) -> Bool) -> [Node] {
            (test(self) ? [self] : []) + children.flatMap { $0.all(where: test) }
        }

        func says(_ words: String) -> Bool { !all { $0.label == words || $0.value == words }.isEmpty }

        @discardableResult
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        }
    }

    enum Screen: String, CaseIterable {
        case idle, scanning, empty, done, failed, cleaning, ready
    }

    private struct Rig {
        let model: AppModel
        let window: WindowState
        let history: HistoryModel
        let client: FakeCmmClient
        let hosting: NSView
        let host: NSWindow
        var root: Node { Node(object: hosting) }

        var historyPane: Node? { root.all { $0.identifier == "history-pane" }.first }
        var detailsPane: Node? { root.all { $0.role == "AXGroup" && $0.label == "Details" }.first }
    }

    private let size = CGSize(width: 1100, height: 720)
    /// What the board's history says first: the chart says it to VoiceOver.
    private let summary = "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago."

    /// Nothing to clean, on the board `C-History`'s disk: 19.8 GB free of 228 GB, scanned at 14:21.
    static func emptyPlan() throws -> Plan {
        let json = #"""
        {"schema_version":1,"generated_at":"2025-10-14T14:21:00+02:00",
         "host":{"volume":"/System/Volumes/Data","free_bytes":19800000000,"capacity_bytes":228000000000},
         "items":[],"skipped":[],"total_bytes":0}
        """#
        return try Plan.parse(Data(json.utf8))
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    private func eventually(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await settle(0.02) }
        XCTAssertTrue(condition(), what)
        return condition()
    }

    /// The window on one screen, reached through the real view model, with one fake cmm for the window and the History (whose
    /// report is the board's). Whatever holds a screen open (a scan, a cleaning) is let go when the test ends.
    private func rig(
        _ screen: Screen, window state: WindowState = WindowState(), settings: SettingsModel? = nil, faceState: HistoryFaceState? = nil,
        laterPlans: [Result<Plan, CmmError>] = [], accessibility: Bool = true
    ) async throws -> Rig {
        _ = NSApplication.shared
        if accessibility {
            // an assistive app asking for the tree is what makes SwiftUI build it
            func ask(_ on: Bool) {
                let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
                for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                    _ = NSApp.perform(selector, with: NSNumber(value: on), with: attribute as NSString)
                }
            }
            ask(true)
            addTeardownBlock { @MainActor in ask(false) }
        }
        let first: Result<Plan, CmmError> = switch screen {
        case .empty: .success(try Self.emptyPlan())
        case .failed: .failure(.planFailed(status: 2, stderr: "cmm: cannot read the free space of /System/Volumes/Data"))
        default: .success(try TestPlans.fixture("plan-c.json"))
        }
        let client = FakeCmmClient(plans: [first] + laterPlans, histories: [.success(try HistoryBoard.report())])
        let model = AppModel(client: client, now: { HistoryBoard.now })
        switch screen {
        case .idle:
            break
        case .scanning:
            let gate = client.holdPlans()
            let scan = Task { await model.scan() }
            addTeardownBlock { @MainActor in
                gate.open()
                await scan.value
            }
            await eventually("the scan is out") { model.phase == .scanning }
        case .empty, .failed, .ready:
            await model.scan()
        case .done:
            client.script(.replay([Events.start(selected: 9, free: gigabytes(19.8)), Events.done(deleted: 9, freed: gigabytes(8.4))], error: nil))
            await model.scan()
            model.requestClean()
            await model.confirmClean(try XCTUnwrap(model.confirmation))
        case .cleaning:
            client.script(.live)
            await model.scan()
            model.requestClean()
            let confirmation = try XCTUnwrap(model.confirmation)
            let cleaning = Task { await model.confirmClean(confirmation) }
            addTeardownBlock { @MainActor in
                client.send(Events.done())
                client.finish()
                await cleaning.value
            }
            let started = await client.waitForApply(timeout: 3)
            XCTAssertTrue(started)
            await eventually("the cleaning screen is up") { model.phase == .cleaning }
        }
        let expected: AppModel.Phase = switch screen {
        case .idle: .idle
        case .scanning: .scanning
        case .empty: .empty
        case .done: .done
        case .failed: .failed
        case .cleaning: .cleaning
        case .ready: .ready
        }
        XCTAssertEqual(model.phase, expected, "the model is on the \(screen) screen")

        let history = HistoryModel(client: client)
        let hosting = NSHostingView(
            rootView: RootView(model: model, window: state, env: HistoryViewsTests.env)
                .environment(history)
                .environment(settings)
                .environment(faceState)
                .frame(width: size.width, height: size.height)
        )
        let host = OffscreenWindow(size: size)
        host.contentView = hosting
        host.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            host.contentView = nil
            host.orderOut(nil)
        }
        await settle(0.5)
        return Rig(model: model, window: state, history: history, client: client, hosting: hosting, host: host)
    }

    private func pressEscape(in rig: Rig) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rig.host.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        )!
        NSApp.sendEvent(event)
        await settle(0.6)
    }

    /// A click in the middle of an element, as the system sends it to the window.
    private func click(_ node: Node, in rig: Rig) async {
        let point = rig.host.convertPoint(fromScreen: CGPoint(x: node.frame.midX, y: node.frame.midY))
        func event(_ type: NSEvent.EventType, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.host.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!
        }
        NSApp.sendEvent(event(.leftMouseDown, 1))
        NSApp.sendEvent(event(.leftMouseUp, 2))
        await settle(0.3)
    }

    // MARK: on each screen

    private func checkTheHistoryOpensAndEscClosesIt(on screen: Screen) async throws {
        let rig = try await rig(screen)
        XCTAssertNil(rig.historyPane, "\(screen): the pane is closed")
        rig.window.openHistory()  // what the menu bar's "Last cleaned" and "See it in History" do
        await eventually("\(screen): the History is there") { rig.historyPane != nil }
        await eventually("\(screen): and shows the history it read") { rig.historyPane?.says(summary) ?? false }
        XCTAssertGreaterThanOrEqual(rig.client.historyCalls, 1)
        XCTAssertEqual(rig.historyPane?.all { $0.role == "AXButton" && $0.label == "Hide History" }.count, 1)
        XCTAssertTrue(rig.historyPane?.all { $0.label == "List" || $0.label == "Map" }.isEmpty ?? false, "no List or Map without a plan")

        await pressEscape(in: rig)
        XCTAssertFalse(rig.window.detailsOpen, "\(screen): Esc closes it")
        await eventually("\(screen): and it is gone") { rig.historyPane == nil }
        XCTAssertTrue(rig.client.applyCalls.isEmpty || screen == .done, "nothing is asked of cmm but to read")
    }

    func testBeforeTheFirstScanTheHistoryOpensAndEscClosesIt() async throws {
        try await checkTheHistoryOpensAndEscClosesIt(on: .idle)
    }

    func testWhileScanningTheHistoryOpensAndEscClosesIt() async throws {
        try await checkTheHistoryOpensAndEscClosesIt(on: .scanning)
    }

    func testWithNothingToCleanTheHistoryOpensAndEscClosesIt() async throws {
        try await checkTheHistoryOpensAndEscClosesIt(on: .empty)
    }

    func testAfterACleaningTheHistoryOpensAndEscClosesIt() async throws {
        try await checkTheHistoryOpensAndEscClosesIt(on: .done)
    }

    func testAfterAnErrorTheHistoryOpensAndEscClosesIt() async throws {
        try await checkTheHistoryOpensAndEscClosesIt(on: .failed)
    }

    func testTheCleaningScreenShowsNoPane() async throws {
        let rig = try await rig(.cleaning)
        rig.window.openHistory()
        await settle(0.6)
        XCTAssertNil(rig.historyPane, "the person is watching the cleaning")
        XCTAssertNil(rig.detailsPane)
        XCTAssertEqual(rig.client.historyCalls, 0, "and nothing is read while it runs")
    }

    func testTheRestScreenKeepsItsOwnPaneOnEachOfItsThreeFaces() async throws {
        for face in [DetailsFace.list, .map, .history] {
            let rig = try await rig(.ready, window: WindowState(detailsOpen: true, face: face))
            await eventually("\(face): the rest screen's pane") { rig.detailsPane != nil }
            XCTAssertNil(rig.historyPane, "\(face): not the History-only pane")
            let pane = try XCTUnwrap(rig.detailsPane)
            XCTAssertFalse(pane.all { $0.label == "List" }.isEmpty, "\(face): with its switch")
            if face == .history {
                await eventually("the History face in it") { rig.detailsPane?.says(summary) ?? false }
            } else {
                XCTAssertFalse(pane.says(summary), "\(face): the List and the map are not the History")
            }
        }
    }

    // MARK: the nothing-to-clean screen

    func testTheEmptyScreensButtonsOpenAndCloseTheHistoryAndTheFaceIsKeptForTheNextRestScreen() async throws {
        for face in [DetailsFace.list, .map] {
            let rig = try await rig(.empty, window: WindowState(face: face), laterPlans: [.success(try TestPlans.fixture("plan-c.json"))])
            let show = try XCTUnwrap(rig.root.all { $0.role == "AXButton" && $0.label == "Show details" }.first, "\(face): Show details")
            XCTAssertEqual(show.help, "Show details (⌘I)")
            XCTAssertTrue(show.press())
            await eventually("\(face): the History opens") { rig.historyPane != nil }
            XCTAssertEqual(rig.window.face, face, "the face is kept for the rest screen")
            XCTAssertTrue(rig.root.all { $0.label == "Show details" }.isEmpty, "the screen's buttons give way to the pane's")

            let hide = try XCTUnwrap(rig.historyPane?.all { $0.role == "AXButton" && $0.label == "Hide History" }.first)
            XCTAssertTrue(hide.press())
            await eventually("\(face): and closes") { rig.historyPane == nil }
            XCTAssertFalse(rig.window.detailsOpen)

            // open again, and scan: this time there is something to clean
            XCTAssertTrue(try XCTUnwrap(rig.root.all { $0.role == "AXButton" && $0.label == "Show details" }.first).press())
            await eventually("\(face): open again") { rig.historyPane != nil }
            await rig.model.scan()
            XCTAssertEqual(rig.model.phase, .ready)
            await eventually("\(face): the rest screen's own pane") { rig.detailsPane != nil }
            XCTAssertNil(rig.historyPane)
            XCTAssertEqual(rig.window.face, face, "on the face the window remembered")
            // a face of .map opened and closed the pane outside the rest screen: the flight it set lands once the rest screen is up
            await eventually("\(face): no flight is left in the air") { rig.window.flight == nil }
        }
    }

    func testAClickStillReachesTheScreenWhereThePaneIsNot() async throws {
        let rig = try await rig(.empty)
        XCTAssertEqual(rig.client.planCalls, 1)
        // the screen's Rescan at the top right, where the pane would be: the empty pane's place takes no click
        let corner = try XCTUnwrap(rig.root.all { $0.role == "AXButton" && $0.label == "Rescan" && $0.help == "Rescan (⌘R)" }.first)
        await click(corner, in: rig)
        await eventually("the click reached Rescan") { rig.client.planCalls == 2 }
        await eventually("and the scan found nothing again") { rig.model.phase == .empty }

        rig.window.openHistory()
        await eventually("the History is open") { rig.historyPane != nil }
        await settle(0.8)  // the headline has moved to its place beside the pane
        let pill = try XCTUnwrap(rig.root.all { $0.role == "AXButton" && $0.help == "Scans again" }.first, "the screen's Rescan pill")
        XCTAssertLessThan(pill.frame.maxX - rig.host.frame.minX, size.width - HeroLayout.paneWidth, "the pill is beside the pane")
        await click(pill, in: rig)
        await eventually("beside the open pane, the screen still takes its clicks") { rig.client.planCalls == 3 }
    }

    // MARK: pictures

    /// The window as it is drawn, in an appearance; kept as `pane-<name>-<light|dark>.png` when CMM_SNAPSHOT_DIR is set, to be
    /// set beside the boards.
    private func picture(_ rig: Rig, name: String, appearance: NSAppearance.Name) async throws -> NSBitmapImageRep {
        rig.host.appearance = NSAppearance(named: appearance)
        await settle(0.4)
        let bitmap = try XCTUnwrap(rig.hosting.bitmapImageRepForCachingDisplay(in: rig.hosting.bounds))
        rig.hosting.cacheDisplay(in: rig.hosting.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["CMM_SNAPSHOT_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("pane-\(name)-\(appearance == .darkAqua ? "dark" : "light").png")
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url) }
        }
        return bitmap
    }

    /// Mean brightness (0 black ... 1 white) of a region of the window (top-left origin, in points).
    private func brightness(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Double {
        let scale = Double(bitmap.pixelsWide) / size.width
        var total = 0.0
        var count = 0.0
        for x in stride(from: rect.minX, to: rect.maxX, by: 7) {
            for y in stride(from: rect.minY, to: rect.maxY, by: 7) {
                guard let c = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB) else { continue }
                total += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
    }

    /// The board `C-History` (and `C-History-Dark`): nothing to clean, the History open over it, the cleaning with the failed
    /// item open and the pointer on Tuesday 7 October at 15:00. And the done screen with the History over it, which no board
    /// draws.
    func testTheEmptyAndDoneScreensWithTheHistoryDrawInLightAndDark() async throws {
        let ninthOctober = HistoryBoard.runID(HistoryBoard.at(10, 9, 9, 41))
        for screen in [Screen.empty, .done] {
            let rig = try await rig(
                screen, window: WindowState(detailsOpen: true, face: screen == .empty ? .list : .history),  // done: only the History asked for shows
                faceState: HistoryFaceState(expanded: [ninthOctober], pointerTime: HistoryBoard.at(10, 7, 15, 0)), accessibility: false
            )
            let pane = CGRect(x: size.width - HeroLayout.paneWidth, y: 100, width: HeroLayout.paneWidth - 16, height: 560)
            let light = try await picture(rig, name: screen.rawValue, appearance: .aqua)
            let dark = try await picture(rig, name: screen.rawValue, appearance: .darkAqua)
            XCTAssertGreaterThan(brightness(light, in: pane), 0.6, "\(screen): the pane is light in light mode")
            XCTAssertLessThan(brightness(dark, in: pane), 0.4, "\(screen): and dark in dark mode")
            XCTAssertGreaterThanOrEqual(rig.client.historyCalls, 1, "\(screen): the face read the history")
        }
    }

    func testTheOptInCardStepsAsideWhileThePaneIsOpenOnTheEmptyScreen() async throws {
        let settings = SettingsModel(
            settings: Settings(store: MemorySettingsStore([:])), loginItem: FakeLoginItem(), notifications: FakeNotificationPermission()
        )
        let rig = try await rig(.empty, settings: settings)
        await eventually("the card asks, the pane closed") { rig.root.says(OptInCopy.title) }
        rig.window.openHistory()
        await eventually("the History is open") { rig.historyPane != nil }
        await eventually("and the card is not on it") { !rig.root.says(OptInCopy.title) }
        await pressEscape(in: rig)
        await eventually("the card is back when the pane goes") { rig.root.says(OptInCopy.title) }
        XCTAssertFalse(settings.optInAnswered, "opening the pane answered nothing")
    }
}
