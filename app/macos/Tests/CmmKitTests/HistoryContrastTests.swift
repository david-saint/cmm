import XCTest
@testable import Cmm

/// The History face's colours hold their contrast in all four looks (light and dark, each with Increase Contrast off and on),
/// with the floors of the rest of design C (`ThemeContrastTests`): words at 4.5:1 against what they sit on, the quiet words over
/// a gap at the map's 3.5:1, the chart's line and its rises at 3:1 in every look (they are what the chart says), and with
/// Increase Contrast every hairline, edge and dotted outline at 3:1. Read as numbers (`Tone.rgba`), so no window is needed.
final class HistoryContrastTests: XCTestCase {
    private struct Look {
        let label: String
        let dark: Bool
        let increased: Bool
    }

    private static let looks = [
        Look(label: "light", dark: false, increased: false),
        Look(label: "dark", dark: true, increased: false),
        Look(label: "light + Increase Contrast", dark: false, increased: true),
        Look(label: "dark + Increase Contrast", dark: true, increased: true),
    ]

    /// `layers` are drawn over the window, first to last, and `ink` over all of them.
    private func check(
        _ ink: Tone, on layers: [Tone], atLeast minimum: Double, increasedAtLeast: Double? = nil, _ what: String,
        onlyIncreased: Bool = false
    ) {
        for look in Self.looks where !onlyIncreased || look.increased {
            let minimum = look.increased ? (increasedAtLeast ?? minimum) : minimum
            var surface = Theme.background.rgba(dark: look.dark, increasedContrast: look.increased)
            for layer in layers { surface = layer.rgba(dark: look.dark, increasedContrast: look.increased).over(surface) }
            let mark = ink.rgba(dark: look.dark, increasedContrast: look.increased).over(surface)
            let ratio = mark.contrast(with: surface)
            XCTAssertGreaterThanOrEqual(ratio, minimum, "\(what) in \(look.label): \(String(format: "%.2f", ratio)):1")
        }
    }

    private let pane = [Theme.paneTint]
    private let openRow = [Theme.paneTint, Theme.historyOpenRow]
    private let readout = [Theme.paneTint, Theme.historyTip]

    // MARK: words

    func testTheListsWordsOnThePaneAndOnAnOpenCleaning() {
        for (ground, layers) in [("the pane", pane), ("an open cleaning", openRow)] {
            check(Theme.ink, on: layers, atLeast: 7, "a cleaning's date and what it freed on \(ground)")
            check(Theme.ink2, on: layers, atLeast: 4.5, "the time, the groups and an item's size on \(ground)")
            check(Theme.fail, on: layers, atLeast: 4.5, "\"1 failed\" and \"permission denied\" on \(ground)")
            check(Theme.reviewText, on: layers, atLeast: 4.5, "Docker's figure, in its outline and as an item's size, on \(ground)")
        }
    }

    func testTheReadoutsWords() {
        check(Theme.ink, on: readout, atLeast: 7, "the read-out's free space")
        check(Theme.ink2, on: readout, atLeast: 4.5, "the read-out's day and time")
    }

    func testTheChartsWords() {
        check(Theme.ink2, on: pane, atLeast: 4.5, "the axes' words")
        check(Theme.ink, on: pane, atLeast: 7, "the value now")
        check(Theme.historyQuiet, on: pane, atLeast: 3.5, increasedAtLeast: 4.5, "\"No samples\" over a gap (the map's floor for quiet words)")
    }

    // MARK: marks

    func testTheLineAndTheRisesAreSeenInEveryLook() {
        check(Theme.historyLine, on: pane, atLeast: 3, "the line of what was free")
        check(Theme.accent, on: pane, atLeast: 3, "a cleaning's rise and its dot")
        check(Theme.accent, on: openRow, atLeast: 3, "an item's tick in an open cleaning")
        check(Theme.historyLine, on: [], atLeast: 3, "the ring of the reading under the pointer, on its disc of the window's colour")
    }

    func testWithIncreaseContrastTheHairlinesEdgesAndDotsReach3To1() {
        check(Theme.historyCursor, on: pane, atLeast: 3, "the read-out's line", onlyIncreased: true)
        check(Theme.historyTipLine, on: readout, atLeast: 3, "the read-out's edge", onlyIncreased: true)
        check(Theme.review, on: pane, atLeast: 3, "the dotted outline of Docker's figure", onlyIncreased: true)
        check(Theme.review, on: openRow, atLeast: 3, "the dotted outline in an open cleaning", onlyIncreased: true)
        check(Theme.hair, on: pane, atLeast: 3, "the rule between weeks and the zero line", onlyIncreased: true)
        check(Theme.accent, on: openRow, atLeast: 3, "the focus ring on an open cleaning", onlyIncreased: true)
    }

    func testTheHistorysOwnTokensHaveStrongerVariants() {
        for (name, tone) in [("line", Theme.historyLine), ("cursor", Theme.historyCursor), ("quiet", Theme.historyQuiet),
                             ("open row", Theme.historyOpenRow), ("read-out edge", Theme.historyTipLine)] {
            XCTAssertNotEqual(tone.light, tone.lightStrong, "\(name) in light")
            XCTAssertNotEqual(tone.dark, tone.darkStrong, "\(name) in dark")
        }
    }
}
