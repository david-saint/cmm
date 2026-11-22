import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The menu bar item and its popover drawn offscreen in each of their seven states (the five of the board `C-MenuBar-States`,
/// "cleaning" and "unknown"), in light and dark, so they can be laid next to `C-MenuBar-States` and `C-MenuBar-Dark`. The
/// popover sits on the boards' own ground here; in the app the system draws the panel it is in.
@MainActor
final class MenuBarViewsTests: XCTestCase {
    typealias Shown = MenuBarScenes.Shown

    private func scene(_ shown: Shown) throws -> (MenuBarPresentation, scanEnabled: Bool) {
        try MenuBarScenes.scene(shown)
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

    func testResizedFrameKeepsThePanelsTopEdgeFixed() {
        let tall = NSRect(x: 57, y: 600, width: 320, height: 343)
        let short = PopoverPanel.resizedFrame(current: tall, targetHeight: 221)
        XCTAssertEqual(short, NSRect(x: 57, y: 722, width: 320, height: 221))
        XCTAssertEqual(short.maxY, tall.maxY, accuracy: 0.001, "shrinking holds the top edge under the menu bar")

        let grown = PopoverPanel.resizedFrame(current: short, targetHeight: 343)
        XCTAssertEqual(grown, tall)
        XCTAssertEqual(grown.maxY, short.maxY, accuracy: 0.001, "growing holds the top edge under the menu bar")
    }

    @MainActor
    @Observable
    final class PopoverHolder {
        var presentation: MenuBarPresentation
        var scanEnabled: Bool

        init(presentation: MenuBarPresentation, scanEnabled: Bool) {
            self.presentation = presentation
            self.scanEnabled = scanEnabled
        }
    }

    struct HostedPopover: View {
        let holder: PopoverHolder

        var body: some View {
            MenuBarPopoverView(
                presentation: holder.presentation, scanEnabled: holder.scanEnabled, perform: { _ in }, fitsPanel: true
            )
        }
    }

    func testThePopoverPanelShrinksAndGrowsFromItsTopWhenAScanStartsAndEnds() async throws {
        _ = NSApplication.shared
        let (ready, readyEnabled) = try scene(.ready)
        let (scanning, scanningEnabled) = try scene(.scanning)
        let readyHeight = ceil(
            NSHostingView(rootView: MenuBarPopoverView(presentation: ready, scanEnabled: readyEnabled, perform: { _ in })).fittingSize.height
        )
        let scanningHeight = ceil(
            NSHostingView(rootView: MenuBarPopoverView(presentation: scanning, scanEnabled: scanningEnabled, perform: { _ in })).fittingSize.height
        )
        XCTAssertGreaterThan(readyHeight, scanningHeight + 40, "ready is taller than scanning")

        let holder = PopoverHolder(presentation: ready, scanEnabled: readyEnabled)
        let hosting = NSHostingView(rootView: HostedPopover(holder: holder))
        // Mirror MenuBarExtra's panel: grows with minSize, does not shrink on its own.
        hosting.sizingOptions = [.minSize]
        let window = OffscreenWindow(size: CGSize(width: MenuBarPopoverView.width, height: readyHeight))
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }

        let settled = await eventuallyOnMain(timeout: 3) {
            window.isVisible && abs(window.frame.height - readyHeight) <= 2.0
        }
        XCTAssertTrue(settled, "panel opened at ready height \(readyHeight), got \(window.frame.height)")
        let topY = window.frame.maxY

        // Hold minSize at the previous tall height, as the system panel can before constraints settle.
        window.contentMinSize = NSSize(width: MenuBarPopoverView.width, height: readyHeight)
        window.minSize = NSSize(width: MenuBarPopoverView.width, height: readyHeight)
        holder.presentation = scanning
        holder.scanEnabled = scanningEnabled

        let shrank = await eventuallyOnMain(timeout: 3) {
            abs(window.frame.height - scanningHeight) <= 2.0
        }
        XCTAssertTrue(shrank, "panel shrank from \(readyHeight) to \(scanningHeight), got \(window.frame.height)")
        XCTAssertEqual(window.frame.maxY, topY, accuracy: 1.0, "shrinking keeps the panel's top edge pinned")

        // Hold maxSize at the previous short height without conflicting Auto Layout minSize constraints.
        hosting.sizingOptions = []
        window.contentMaxSize = NSSize(width: MenuBarPopoverView.width, height: scanningHeight)
        window.maxSize = NSSize(width: MenuBarPopoverView.width, height: scanningHeight)
        holder.presentation = ready
        holder.scanEnabled = readyEnabled

        let grew = await eventuallyOnMain(timeout: 3) {
            abs(window.frame.height - readyHeight) <= 2.0
        }
        XCTAssertTrue(grew, "panel grew back to \(readyHeight), got \(window.frame.height)")
        XCTAssertEqual(window.frame.maxY, topY, accuracy: 1.0, "growing keeps the panel's top edge pinned")
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
                // as the board draws it: at 1.4 times, on a menu bar's strip, in the menu bar's regular 13-point type
                let strip = appearance == .darkAqua ? Color(.sRGB, red: 0.11, green: 0.11, blue: 0.125) : Color(.sRGB, red: 0.925, green: 0.93, blue: 0.94)
                let view = MenuBarLabel(item: item)
                    .font(.system(size: 13))
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
