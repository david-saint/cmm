import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The one-time card (the board `C-Optin`, spec R8): when it is there, where it goes, that it covers nothing and moves nothing on
/// the screen, what its two answers do, and how it looks in light and dark.
@MainActor
final class OptInTests: XCTestCase {
    private let boardPill = CGRect(x: 112, y: 507, width: 154, height: 44)

    // MARK: where it goes

    func testOnTheBoardItSitsBesideTheHeadlineOnTheBandsRightEndAndThePillsBottom() {
        let placement = OptInPlacement(windowWidth: 1100, windowHeight: 720, pillFrame: boardPill)
        XCTAssertEqual(placement.scale, 1)
        XCTAssertEqual(placement.width, 320)
        XCTAssertEqual(placement.right, 988, "1100 less the headline's 112: the band's right end")
        XCTAssertEqual(placement.bottom, 551, "the pill's bottom")
        XCTAssertEqual(placement.frame(height: 193), CGRect(x: 668, y: 358, width: 320, height: 193), "the board's card: 668, 357, 320 wide")
    }

    func testWithoutAPillItStandsWhereThePillsBottomIsOnTheBoard() {
        let placement = OptInPlacement(windowWidth: 1100, windowHeight: 720, pillFrame: nil)
        XCTAssertEqual(placement.bottom, 551)
        XCTAssertEqual(OptInPlacement(windowWidth: 1100, windowHeight: 720, pillFrame: .zero).bottom, 551, "an empty frame is no pill")
    }

    func testItKeepsTheHeadlinesScaleInEveryWindow() {
        for (width, height) in [(820.0, 560.0), (1100.0, 720.0), (1400.0, 560.0), (900.0, 1000.0), (2400.0, 1600.0)] {
            let layout = HeroLayout(screen: .rest, width: width, height: height)
            let placement = OptInPlacement(windowWidth: width, windowHeight: height, pillFrame: nil)
            XCTAssertEqual(placement.scale, layout.scale, accuracy: 1e-9)
            XCTAssertEqual(placement.width, 320 * layout.scale, accuracy: 1e-9)
            XCTAssertEqual(placement.right, width - layout.leading, accuracy: 1e-9)
            XCTAssertEqual(placement.bottom, layout.top + 379 * layout.scale, accuracy: 1e-9)
            // the card's left edge stays right of the headline's text column, as on the board
            XCTAssertGreaterThan(placement.right - placement.width, layout.leading + layout.bodyMaxWidth, "\(width) x \(height)")
        }
    }

    // MARK: when it is there

    func testItIsThereOnlyUnansweredAndAtRest() {
        for answered in [false, true] {
            for phase in [AppModel.Phase.idle, .scanning, .ready, .empty, .cleaning, .done, .failed] {
                for card in [false, true] {
                    for details in [false, true] {
                        let shown = OptInPlacement.isShown(optInAnswered: answered, phase: phase, confirmationOpen: card, detailsOpen: details)
                        let expected = !answered && !card && (phase == .empty || phase == .ready) && !details
                        XCTAssertEqual(shown, expected, "answered \(answered), \(phase), card \(card), details \(details)")
                    }
                }
            }
        }
    }

    // MARK: the window with the card

    private func settings(answered: Bool = false) -> (SettingsModel, MemorySettingsStore, FakeLoginItem, FakeNotificationPermission) {
        let store = MemorySettingsStore(answered ? [.optInAnswered: true] : [:])
        let login = FakeLoginItem()
        let permission = FakeNotificationPermission()
        return (SettingsModel(settings: Settings(store: store), loginItem: login, notifications: permission), store, login, permission)
    }

    private func readyModel(_ plan: Plan) async -> AppModel {
        let model = AppModel(client: FakeCmmClient(plan: plan), now: { BoardClock.finished })
        await model.scan()
        return model
    }

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    private func safeOnlyBoardPlan() throws -> Plan {
        let board = try TestPlans.fixture("plan-c.json")
        return TestPlans.plan(board.items.filter { $0.tier == .safe }, skipped: board.skipped, freeBytes: board.host.freeBytes, capacityBytes: board.host.capacityBytes)
    }

    private func screen(_ model: AppModel, settings: SettingsModel?) -> some View {
        Group {
            if let settings {
                RootView(model: model, window: WindowState(), env: AppViewsTests.env).environment(settings)
            } else {
                RootView(model: model, window: WindowState(), env: AppViewsTests.env)
            }
        }
    }

    /// The card's frame in a window of this size, measured from the render with the card against the one without: wherever the two
    /// differ is the card.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGRect? {
        var box: CGRect?
        for x in stride(from: 0, to: a.pixelsWide, by: 2) {
            for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.02 {
                    let point = CGRect(x: x, y: y, width: 2, height: 2)
                    box = box.map { $0.union(point) } ?? point
                }
            }
        }
        return box
    }

    /// The darkest pixel of a region, in a render of the window without the card: where the card goes, the screen has nothing.
    private func inkIn(_ bitmap: NSBitmapImageRep, _ rect: CGRect) -> Double {
        var darkest = 1.0
        for x in Int(rect.minX)..<min(Int(rect.maxX), bitmap.pixelsWide) {
            for y in Int(rect.minY)..<min(Int(rect.maxY), bitmap.pixelsHigh) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                darkest = min(darkest, 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
            }
        }
        return darkest
    }

    func testTheCardCoversNothingAndMovesNothingInEveryWindowAndWithTheWidestHeadline() async throws {
        let widest = TestPlans.plan(
            [TestPlans.item("/Users/test/huge", group: "Huge", rule: "go-build", bytes: 999_900_000_000)],
            freeBytes: gb(120), capacityBytes: gb(2_000)
        )
        let empty = TestPlans.plan([], freeBytes: gb(28.4), capacityBytes: gb(228))
        let cases: [(String, Plan, CGSize)] = [
            ("board", try safeOnlyBoardPlan(), CGSize(width: 1100, height: 720)),
            ("smallest", try safeOnlyBoardPlan(), CGSize(width: HeroLayout.minimumWidth, height: HeroLayout.minimumHeight)),
            ("widest-headline", widest, CGSize(width: 1100, height: 720)),
            ("widest-headline-smallest", widest, CGSize(width: HeroLayout.minimumWidth, height: HeroLayout.minimumHeight)),
            ("wide-and-low", try safeOnlyBoardPlan(), CGSize(width: 1500, height: 600)),
            ("empty", empty, CGSize(width: 1100, height: 720)),
            ("empty-smallest", empty, CGSize(width: HeroLayout.minimumWidth, height: HeroLayout.minimumHeight)),
        ]
        for (name, plan, size) in cases {
            let model = await readyModel(plan)
            let (prefs, _, _, _) = settings()
            let with = try SystemRendering.render(screen(model, settings: prefs), size: size, appearance: .aqua, name: "optin-\(name)")
            let without = try SystemRendering.render(screen(model, settings: nil), size: size, appearance: .aqua)
            let card = try XCTUnwrap(difference(with, without), "\(name): the card is drawn")
            XCTAssertGreaterThan(card.width, 200, name)
            XCTAssertGreaterThan(inkIn(without, card.insetBy(dx: -4, dy: -4)), 0.9, "\(name): the card covers something of the screen")
            XCTAssertLessThan(card.maxX, size.width - 60, name)
        }
    }

    func testTheCardOnTheBoardInLightAndDark() async throws {
        let model = await readyModel(try TestPlans.fixture("plan-c.json"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (prefs, _, _, _) = settings()
            let bitmap = try SystemRendering.render(
                screen(model, settings: prefs), size: CGSize(width: 1100, height: 720), appearance: appearance, name: "optin"
            )
            if appearance == .aqua {
                XCTAssertGreaterThan(SystemRendering.brightness(bitmap), 0.6)
            } else {
                XCTAssertLessThan(SystemRendering.brightness(bitmap), 0.4)
            }
            let (strong, _, _, _) = settings()
            _ = try SystemRendering.render(
                screen(model, settings: strong), size: CGSize(width: 1100, height: 720), appearance: appearance, increasedContrast: true,
                name: "optin"
            )
        }
    }

    func testNoCardOnceItIsAnsweredNorWithoutTheSettings() async throws {
        let model = await readyModel(try TestPlans.fixture("plan-c.json"))
        let size = CGSize(width: 1100, height: 720)
        let bare = try SystemRendering.render(screen(model, settings: nil), size: size, appearance: .aqua)
        let (answered, _, _, _) = settings(answered: true)
        let after = try SystemRendering.render(screen(model, settings: answered), size: size, appearance: .aqua)
        XCTAssertNil(difference(bare, after), "an answered card is never drawn again")
    }

    // MARK: the answers, pressed in a real window

    private func hostedRoot(_ model: AppModel, settings: SettingsModel) async -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let size = CGSize(width: 1100, height: 720)
        let hosting = NSHostingView(rootView: screen(model, settings: settings).frame(width: size.width, height: size.height))
        let window = OffscreenWindow(size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }
        try? await Task.sleep(for: .seconds(0.4))
        return (window, hosting)
    }

    /// A click at a point of the window, measured from its top left corner.
    private func click(_ point: CGPoint, in window: NSWindow) async {
        func event(_ type: NSEvent.EventType, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: point.x, y: window.frame.height - point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!
        }
        NSApp.sendEvent(event(.leftMouseDown, 1))
        NSApp.sendEvent(event(.leftMouseUp, 2))
        try? await Task.sleep(for: .seconds(0.2))
    }

    /// The card's buttons on the board: Turn on at 686..762 and Not now at 776..830, both 507..535 high.
    private let turnOnPoint = CGPoint(x: 722, y: 521)
    private let notNowPoint = CGPoint(x: 802, y: 521)

    func testTurnOnSwitchesOnAllFourAndIsTheOneMomentMacOSIsAsked() async throws {
        let model = await readyModel(try TestPlans.fixture("plan-c.json"))
        let (prefs, store, login, permission) = settings()
        let (window, _) = await hostedRoot(model, settings: prefs)
        await click(turnOnPoint, in: window)
        await eventuallyOnMain(timeout: 3) { prefs.weeklyReminderEnabled }
        XCTAssertTrue(prefs.optInAnswered)
        XCTAssertTrue(prefs.menuBarEnabled)
        XCTAssertTrue(prefs.historyEnabled)
        XCTAssertTrue(prefs.weeklyReminderEnabled)
        XCTAssertEqual(login.calls, [true], "Open at login, through the system's login item")
        XCTAssertEqual(permission.requestCalls, 1, "macOS asked once about notifications")
        XCTAssertEqual(Set(store.keys), ["optInAnswered", "menuBarEnabled", "historyEnabled", "weeklyReminderEnabled"])
        XCTAssertEqual(model.phase, .ready, "the screen behind the card is as it was")
    }

    func testNotNowChangesNothingButPutsTheCardAwayForGood() async throws {
        let model = await readyModel(try TestPlans.fixture("plan-c.json"))
        let (prefs, store, login, permission) = settings()
        let (window, _) = await hostedRoot(model, settings: prefs)
        await click(notNowPoint, in: window)
        await eventuallyOnMain(timeout: 3) { prefs.optInAnswered }
        XCTAssertTrue(prefs.optInAnswered)
        XCTAssertFalse(prefs.menuBarEnabled)
        XCTAssertFalse(prefs.historyEnabled)
        XCTAssertFalse(prefs.weeklyReminderEnabled)
        XCTAssertEqual(login.calls, [])
        XCTAssertEqual(permission.requestCalls, 0)
        XCTAssertEqual(store.keys, ["optInAnswered"], "the one thing written is that it was answered")
    }
}
