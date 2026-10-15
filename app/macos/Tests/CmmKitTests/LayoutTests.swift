import XCTest
@testable import CmmKit

/// Where the design puts things, as numbers: at the board's 1100 x 720 they are exactly the board's, and in a smaller
/// or larger window they scale together instead of overlapping.
final class HeroLayoutTests: XCTestCase {
    private let board = (width: 1100.0, height: 720.0)

    private func layout(_ screen: HeroLayout.Screen, details: Bool = false, width: Double = 1100, height: Double = 720) -> HeroLayout {
        HeroLayout(screen: screen, detailsOpen: details, width: width, height: height)
    }

    // MARK: the boards

    func testTheRestBoard() {
        let l = layout(.rest)
        XCTAssertEqual(l.scale, 1)
        XCTAssertEqual(l.leading, 112)
        XCTAssertEqual(l.top, 172)
        XCTAssertEqual(l.numberSize, 184)
        XCTAssertEqual(l.unitSize, 56)
        XCTAssertEqual(l.numberGap, 14)
        XCTAssertEqual(l.phraseSize, 36)
        XCTAssertEqual(l.bodySize, 15)
        XCTAssertEqual(l.bodyLineHeight, 22)
        XCTAssertEqual(l.bodyMaxWidth, 470)
        XCTAssertEqual(l.pillHeight, 44)
        XCTAssertEqual(l.pillPadding, 24)
        XCTAssertEqual(l.pillFontSize, 15)
        XCTAssertEqual(l.bandLeading, 112)
        XCTAssertEqual(l.bandWidth, 876)
        XCTAssertEqual(l.bandTop, 612, "the caption row of the band starts 108 pt above the bottom edge")
        XCTAssertEqual(l.eyebrowSize, 13)
        XCTAssertEqual([l.numberTopGap, l.phraseTopGap, l.bodyTopGap, l.actionsTopGap, l.actionsGap], [14, 12, 12, 30, 22])
    }

    func testTheDetailsOpenBoard() {
        let l = layout(.rest, details: true)
        XCTAssertEqual(l.leading, 72)
        XCTAssertEqual(l.top, 150)
        XCTAssertEqual(l.numberSize, 136)
        XCTAssertEqual(l.unitSize, 42)
        XCTAssertEqual(l.numberGap, 10)
        XCTAssertEqual(l.phraseSize, 30)
        XCTAssertEqual(l.bodySize, 14)
        XCTAssertEqual(l.bodyLineHeight, 21)
        XCTAssertEqual(l.bodyMaxWidth, 420)
        XCTAssertEqual(l.pillHeight, 40)
        XCTAssertEqual(l.pillPadding, 22)
        XCTAssertEqual(l.pillFontSize, 14)
        XCTAssertEqual([l.numberTopGap, l.phraseTopGap, l.bodyTopGap, l.actionsTopGap, l.actionsGap], [12, 10, 10, 26, 18])
        XCTAssertEqual(l.bandLeading, 72)
        XCTAssertEqual(l.bandWidth, 520)
        XCTAssertEqual(l.bandTop, 612)
        XCTAssertEqual(HeroLayout.paneWidth, 452)
        XCTAssertEqual(HeroLayout.paneInset, 8)
    }

    func testTheCleaningAndDoneBoards() {
        for screen in [HeroLayout.Screen.cleaning, .done] {
            let l = layout(screen)
            XCTAssertEqual(l.leading, 112)
            XCTAssertEqual(l.top, 120)
            XCTAssertEqual(l.numberSize, 184)
            XCTAssertEqual([l.numberTopGap, l.phraseTopGap], [14, 12])
            XCTAssertEqual(l.bandWidth, 876)
            XCTAssertEqual(l.bandTop, 640, "no held-back line under the band, so it sits lower")
        }
    }

    func testTheEmptyBoard() {
        let l = layout(.empty)
        XCTAssertEqual(l.top, 172)
        XCTAssertEqual(l.leading, 112)
        XCTAssertEqual(l.bandTop, 612)
    }

    // MARK: other windows

    func testEverythingScalesTogether() {
        let big = layout(.rest, width: 2200, height: 1440)
        XCTAssertEqual(big.scale, 1.25, "capped, so a huge window does not get a huge number")
        let small = layout(.rest, width: 820, height: 560)
        XCTAssertEqual(small.scale, min(820.0 / 1100, 560.0 / 720), accuracy: 1e-9)
        XCTAssertEqual(small.numberSize, 184 * small.scale, accuracy: 1e-9)
        XCTAssertEqual(small.leading, 112 * small.scale, accuracy: 1e-9)
    }

    func testTheScaleNeverDropsBelowTheFloor() {
        XCTAssertEqual(layout(.rest, width: 300, height: 200).scale, 0.66)
    }

    func testTheBandIsAsWideAsTheTextColumnAndNeverNegative() {
        for width in [200.0, 600, 820, 1100, 1800] {
            let open = layout(.rest, details: true, width: width, height: 720)
            XCTAssertGreaterThanOrEqual(open.bandWidth, 0, "details open, width \(width)")
            let closed = layout(.rest, details: false, width: width, height: 720)
            XCTAssertGreaterThanOrEqual(closed.bandWidth, 0, "details closed, width \(width)")
            XCTAssertLessThanOrEqual(closed.bandLeading + closed.bandWidth, width + 1e-9)
        }
    }

    func testWithTheDetailsOpenTheBandStopsBeforeThePane() {
        for width in [820.0, 900, 1100, 1400] {
            let l = layout(.rest, details: true, width: width)
            let paneLeft = width - HeroLayout.paneWidth - HeroLayout.paneInset
            XCTAssertLessThanOrEqual(l.bandLeading + l.bandWidth, paneLeft, "width \(width)")
        }
    }

    func testTheMinimumWindowFitsTheDesign() {
        XCTAssertEqual(HeroLayout.minimumWidth, 820)
        XCTAssertEqual(HeroLayout.minimumHeight, 560)
        // With the pane open at the smallest width there is still a text column left of it.
        let l = layout(.rest, details: true, width: HeroLayout.minimumWidth, height: HeroLayout.minimumHeight)
        XCTAssertGreaterThan(l.bandWidth, 200)
    }
}

final class VolumeNameTests: XCTestCase {
    func testTheDataVolumeIsKnownByTheNameOfTheStartupVolume() {
        var asked: [String] = []
        let name = VolumeName.display(forVolume: "/System/Volumes/Data") { path in
            asked.append(path)
            return "Macintosh HD"
        }
        XCTAssertEqual(name, "Macintosh HD")
        XCTAssertEqual(asked, ["/"], "the Data volume is the writable half of the startup volume the person knows")
    }

    func testAnotherVolumeIsAskedByItsOwnPath() {
        var asked: [String] = []
        let name = VolumeName.display(forVolume: "/Volumes/Work") { path in
            asked.append(path)
            return "Work"
        }
        XCTAssertEqual(name, "Work")
        XCTAssertEqual(asked, ["/Volumes/Work"])
    }

    func testAnUnknownNameIsLeftOutNotInvented() {
        XCTAssertEqual(VolumeName.display(forVolume: "/Volumes/Odd") { _ in nil }, "")
        XCTAssertEqual(VolumeName.display(forVolume: "/Volumes/Odd") { _ in "" }, "")
    }

    func testTheRealLookupNamesTheStartupVolume() {
        let name = VolumeName.display(forVolume: "/System/Volumes/Data")
        XCTAssertFalse(name.isEmpty, "every Mac names its startup volume")
    }
}


final class CardPlacementTests: XCTestCase {
    private let window = CGSize(width: 1100, height: 720)
    private let card = CGSize(width: CardPlacement.width, height: CardPlacement.height)

    func testTheCardIsTheBoardsSize() {
        XCTAssertEqual(card, CGSize(width: 492, height: 176))
    }

    func testTheCardOfTheBoardSitsJustAboveAndLeftOfThePill() {
        // The board's pill is at (112, 507), 44 high; its card starts at (100, 452).
        let placement = CardPlacement(pill: CGRect(x: 112, y: 507, width: 154.3, height: 44), card: card, window: window)
        XCTAssertEqual(placement.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(placement.origin.y, 452, accuracy: 0.001)
    }

    func testTheCardGrowsFromTheMiddleOfThePill() {
        let pill = CGRect(x: 112, y: 506.5, width: 140, height: 44)
        let placement = CardPlacement(pill: pill, card: card, window: window)
        XCTAssertEqual(placement.anchor.x, (pill.midX - placement.origin.x) / card.width, accuracy: 1e-9)
        XCTAssertEqual(placement.anchor.y, (pill.midY - placement.origin.y) / card.height, accuracy: 1e-9)
        XCTAssertTrue((0...1).contains(placement.anchor.x) && (0...1).contains(placement.anchor.y))
    }

    func testTheCardStaysInsideTheWindow() {
        let nearTheEdge = CardPlacement(pill: CGRect(x: 900, y: 650, width: 140, height: 44), card: card, window: window)
        XCTAssertLessThanOrEqual(nearTheEdge.origin.x + card.width, window.width - 16 + 1e-9)
        XCTAssertLessThanOrEqual(nearTheEdge.origin.y + card.height, window.height - 16 + 1e-9)

        let nearTheCorner = CardPlacement(pill: CGRect(x: 2, y: 2, width: 140, height: 44), card: card, window: window)
        XCTAssertGreaterThanOrEqual(nearTheCorner.origin.x, 16)
        XCTAssertGreaterThanOrEqual(nearTheCorner.origin.y, 16)
    }

    func testAnUnknownPillCentresTheCard() {
        let placement = CardPlacement(pill: .zero, card: card, window: window)
        XCTAssertEqual(placement.origin.x, (window.width - card.width) / 2, accuracy: 0.001)
        XCTAssertEqual(placement.origin.y, (window.height - card.height) / 2, accuracy: 0.001)
        XCTAssertEqual(placement.anchor.x, 0.5)
        XCTAssertEqual(placement.anchor.y, 0.5)
    }

    func testACardWiderThanTheWindowStillHasAnOrigin() {
        let placement = CardPlacement(pill: CGRect(x: 100, y: 100, width: 100, height: 40), card: card, window: CGSize(width: 300, height: 200))
        XCTAssertEqual(placement.origin.x, 16)
        XCTAssertEqual(placement.origin.y, 16)
    }
}
