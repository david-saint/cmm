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
