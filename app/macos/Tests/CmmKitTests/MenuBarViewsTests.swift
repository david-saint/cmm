import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The menu bar item and its popover drawn offscreen in each of their seven states (the five of the board `C-MenuBar-States`,
/// "cleaning" and "unknown"), in light and dark, so they can be laid next to `C-MenuBar-States` and `C-MenuBar-Dark`. The
/// popover sits on the boards' own ground here; in the app the system draws the panel it is in.
@MainActor
final class MenuBarViewsTests: XCTestCase {
    enum Shown: String, CaseIterable {
        case ready, nothingToClean, low, scanning, cleaning, justCleaned, unknown
    }

    /// Thursday 15 October 2026, 15:30 in Berlin (the window's boards' afternoon).
    private let now = BoardClock.now
    private let calendar = BoardClock.calendar
    private let british = Locale(identifier: "en_GB")

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    /// A history with one cleaning: Tuesday's 5.4 GB, or one more than a week ago.
    private func history(lastCleaned: String = "2026-10-13T12:06:00Z") throws -> HistoryReport {
        var json = HistoryJSON()
        json.generatedAt = "2026-10-15T13:00:00Z"
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":19800000000,"capacity_bytes":228000000000}"#
        json.runs = [HistoryJSON.run(finished: lastCleaned, freed: gb(5.4), before: gb(14.4))]
        return try json.report()
    }

    private func lowPlan() -> Plan {
        TestPlans.plan(
            [
                TestPlans.item("/Users/test/lane-builds/lane-a/node_modules", group: "Idle lane dependencies", rule: "lane-deps", bytes: gb(4.0)),
                TestPlans.item("/Users/test/lane-builds/lane-b/node_modules", group: "Idle lane dependencies", rule: "lane-deps", bytes: gb(2.1)),
                TestPlans.item("/Users/test/.cache/uv", group: "uv cache", rule: "uv-cache", bytes: gb(3.4)),
                TestPlans.item("/Users/test/Library/Caches/go-build", group: "Go build cache", rule: "go-build", bytes: gb(1.6)),
                TestPlans.item("/Users/test/.npm/_cacache", group: "npm cache", rule: "npm-cache", bytes: gb(1.2)),
                TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gb(9.0), tier: .review, action: .command, freesInside: "Docker's disk image"),
            ],
            freeBytes: gb(8.1), capacityBytes: gb(228)
        )
    }

    private func cleaned() -> CleanSummary {
        CleanSummary(
            done: DoneEvent(
                deleted: 7, skipped: 1, failed: 1, freedBytes: gb(5.4), freedInsideBytes: 0, freeBefore: gb(19.8), freeAfter: gb(25.2),
                stopped: false, warnings: [], log: nil
            ),
            items: [], unreadableLines: 0, reviewHeld: 0, finishedAt: now.addingTimeInterval(-600)
        )
    }

    /// The menu bar model told what the state needs, and the window's phase at that moment.
    func scene(_ shown: Shown) throws -> (MenuBarPresentation, scanEnabled: Bool) {
        let clock = now
        let scanned = now.addingTimeInterval(-1_800)
        let scannedAt = Locked(scanned)
        let model = MenuBarModel(now: { scannedAt.withLock { $0 } }, calendar: calendar, sleep: { _ in })
        let phase: AppModel.Phase
        switch shown {
        case .ready:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            phase = .ready
        case .nothingToClean:
            model.recordHistory(try history())
            model.recordScan(TestPlans.plan([], freeBytes: gb(28.4), capacityBytes: gb(228)))
            phase = .empty
        case .low:
            model.recordHistory(try history(lastCleaned: "2026-10-07T08:41:00Z"))
            model.recordScan(lowPlan())
            phase = .ready
        case .scanning:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            phase = .scanning
        case .cleaning:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            phase = .cleaning
        case .justCleaned:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            scannedAt.withLock { $0 = clock }
            model.recordCleaning(cleaned())
            phase = .done
        case .unknown:
            model.recordSample(SampleResult(recorded: true, t: nil, freeBytes: gb(19.8), capacityBytes: gb(228)), receivedAt: scanned)
            phase = .idle
        }
        scannedAt.withLock { $0 = clock }
        let presentation = model.presentation(
            phase: phase, confirmationOpen: false, volumeName: { _ in "Macintosh HD" }, calendar: calendar, locale: british
        )
        let enabled = MenuBarModel.scanEnabled(presentation.popover, phase: phase, confirmationOpen: false, mainWindowOpen: false)
        return (presentation, enabled)
    }

    /// The popover on the boards' own ground (the system draws the real panel), on the boards' desk.
    func boardPanel(_ presentation: MenuBarPresentation, scanEnabled: Bool, appearance: NSAppearance.Name) -> some View {
        let desk = appearance == .darkAqua ? Color(.sRGB, red: 0x14 / 255, green: 0x16 / 255, blue: 0x1A / 255) : .white
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return MenuBarPopoverView(presentation: presentation, scanEnabled: scanEnabled, perform: { _ in })
            .background(shape.fill(Theme.popoverGround))
            .overlay(shape.strokeBorder(Theme.hair, lineWidth: 0.5))
            .padding(24)
            .frame(width: 368, height: 470, alignment: .topLeading)
            .background(desk)
    }

    static let canvas = CGSize(width: 368, height: 470)

    // MARK: tests

    func testEveryStateOfThePopoverDrawsInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var pictures: [NSBitmapImageRep] = []
            for shown in Shown.allCases {
                let (presentation, enabled) = try scene(shown)
                let bitmap = try SystemRendering.render(
                    boardPanel(presentation, scanEnabled: enabled, appearance: appearance), size: Self.canvas, appearance: appearance,
                    name: "menubar-\(shown.rawValue)"
                )
                XCTAssertGreaterThan(SystemRendering.distinctColors(bitmap), 8, "\(shown) looks blank")
                if appearance == .aqua {
                    XCTAssertGreaterThan(SystemRendering.brightness(bitmap), 0.75, "\(shown) is not light")
                } else {
                    XCTAssertLessThan(SystemRendering.brightness(bitmap), 0.3, "\(shown) is not dark")
                }
                pictures.append(bitmap)
            }
            try SystemRendering.save(try SystemRendering.strip(pictures), as: "menubar-states-\(SystemRendering.label(appearance))")
        }
    }

    func testIncreaseContrastDrawsTheStrongerColours() throws {
        let (presentation, enabled) = try scene(.low)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try SystemRendering.render(
                boardPanel(presentation, scanEnabled: enabled, appearance: appearance), size: Self.canvas, appearance: appearance,
                increasedContrast: true, name: "menubar-low"
            )
            XCTAssertGreaterThan(SystemRendering.distinctColors(bitmap), 8)
        }
    }

    func testThePopoverIsTheBoardsWidthAndHoldsTheStatesTallestContent() throws {
        for shown in Shown.allCases {
            let (presentation, enabled) = try scene(shown)
            let hosting = NSHostingView(rootView: MenuBarPopoverView(presentation: presentation, scanEnabled: enabled, perform: { _ in }))
            let size = hosting.fittingSize
            XCTAssertEqual(size.width, 320, accuracy: 0.5, "\(shown)")
            XCTAssertLessThan(size.height, Self.canvas.height - 48, "\(shown) fits its canvas")
            XCTAssertGreaterThan(size.height, 150, "\(shown)")
        }
    }

    func testTheLowStateHasTheAmberDotAndTheWordsWithIt() throws {
        let (presentation, enabled) = try scene(.low)
        XCTAssertEqual(presentation.popover.header.lead, "Low on space", "the dot never stands alone")
        let bitmap = try SystemRendering.render(
            boardPanel(presentation, scanEnabled: enabled, appearance: .aqua), size: Self.canvas, appearance: .aqua
        )
        let header = CGRect(x: 24 + 18, y: 24 + 16, width: 40, height: 26)
        XCTAssertTrue(SystemRendering.contains(bitmap, color: Theme.low.light, in: header), "the amber dot leads the header")
        let (ready, readyEnabled) = try scene(.ready)
        let plain = try SystemRendering.render(
            boardPanel(ready, scanEnabled: readyEnabled, appearance: .aqua), size: Self.canvas, appearance: .aqua
        )
        XCTAssertFalse(SystemRendering.contains(plain, color: Theme.low.light, in: header), "and is only there when space is low")
    }

    // MARK: the item in the menu bar

    func testTheItemIsTheGlyphAndTheNumberWithTheDotUnderTenGigabytes() throws {
        let items: [(String, MenuBarItem)] = [
            ("item", MenuBarItem(title: "19.8 GB", isLow: false, accessibilityLabel: "19.8 GB free")),
            ("item-low", MenuBarItem(title: "8.1 GB", isLow: true, accessibilityLabel: "8.1 GB free, low on space")),
            ("item-unknown", MenuBarItem(title: nil, isLow: false, accessibilityLabel: "cmm")),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var pictures: [NSBitmapImageRep] = []
            for (name, item) in items {
                // as the board draws it: at 1.4 times, on a menu bar's strip
                let strip = appearance == .darkAqua ? Color(.sRGB, red: 0.11, green: 0.11, blue: 0.125) : Color(.sRGB, red: 0.925, green: 0.93, blue: 0.94)
                let view = MenuBarLabel(item: item)
                    .font(.system(size: 13, weight: .medium))
                    .scaleEffect(1.4)
                    .frame(width: 240, height: 44)
                    .background(RoundedRectangle(cornerRadius: 9).fill(strip))
                    .padding(8)
                let bitmap = try SystemRendering.render(view, size: CGSize(width: 256, height: 60), appearance: appearance, name: "menubar-\(name)")
                let amber = SystemRendering.contains(bitmap, color: Theme.low.rgba(dark: appearance == .darkAqua, increasedContrast: false), in: CGRect(x: 8, y: 8, width: 240, height: 44))
                XCTAssertEqual(amber, item.isLow, "\(name) in \(appearance.rawValue): the amber dot only under 10 GB")
                pictures.append(bitmap)
            }
            try SystemRendering.save(try SystemRendering.strip(pictures), as: "menubar-items-\(SystemRendering.label(appearance))")
        }
    }

    func testTheItemsTwoPicturesAreATemplateAndOneThatKeepsTheAmber() {
        XCTAssertTrue(MenuBarGlyph.image(low: false).isTemplate, "the menu bar tints the plain glyph itself")
        XCTAssertFalse(MenuBarGlyph.image(low: true).isTemplate, "the amber must survive the menu bar")
        XCTAssertGreaterThan(MenuBarGlyph.image(low: true).size.width, MenuBarGlyph.image(low: false).size.width)
    }
}
