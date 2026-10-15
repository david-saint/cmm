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
