import XCTest
@testable import Cmm

/// The colours of the menu bar item, the popover, the one-time card and Settings hold the same floors as the window's (see
/// `ThemeContrastTests`): text at 4.5:1 or better on what it sits on, in light and dark, with Increase Contrast off and on; marks
/// and lines at 3:1 where they carry meaning (the amber dot) or with Increase Contrast (the hairlines, the card's edge).
///
/// The popover's ground here is the boards' (`Theme.popoverGround`): in the app the system draws the panel, with its own material,
/// which the boards' ground stands for.
final class SystemContrastTests: XCTestCase {
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

    /// `layers` are laid over the window background, first to last, and `ink` over all of them.
    private func check(
        _ ink: Tone, on layers: [Tone], atLeast minimum: Double, increasedAtLeast: Double? = nil, _ what: String, onlyIncreased: Bool = false
    ) {
        for look in Self.looks where !onlyIncreased || look.increased {
            let floor = look.increased ? (increasedAtLeast ?? minimum) : minimum
            var surface = Theme.background.rgba(dark: look.dark, increasedContrast: look.increased)
            for layer in layers { surface = layer.rgba(dark: look.dark, increasedContrast: look.increased).over(surface) }
            let mark = ink.rgba(dark: look.dark, increasedContrast: look.increased).over(surface)
            let ratio = mark.contrast(with: surface)
            XCTAssertGreaterThanOrEqual(ratio, floor, "\(what) in \(look.label): \(String(format: "%.2f", ratio)):1")
        }
    }

    // MARK: the popover

    func testThePopoversWords() {
        check(Theme.ink, on: [Theme.popoverGround], atLeast: 7, "the number, the sentence, the groups' names")
        check(Theme.ink2, on: [Theme.popoverGround], atLeast: 4.5, "the header, the sizes, Last cleaned, the note")
        // an icon, not words (its name is VoiceOver's "More"): the non-text floor
        check(Theme.ink2, on: [Theme.popoverGround, Theme.soft], atLeast: 3, increasedAtLeast: 4.5, "the ... on its soft circle")
        check(Theme.buttonText, on: [Theme.popoverGround, Theme.button], atLeast: 7, "Open cmm on its pill")
    }

    func testTheAmberDotIsAMarkThatStandsOut() {
        // a mark that carries meaning: 3:1 in every look, on the popover and on the window
        check(Theme.low, on: [Theme.popoverGround], atLeast: 3, "the Low on space dot in the popover")
        check(Theme.low, on: [], atLeast: 3, "the dot on a light or dark ground")
    }

    func testWithIncreaseContrastTheBandsTrackAndEdgesReachTheirFloors() {
        // the used stretch is the band's quiet ground (the words and the green and dotted stretches carry the meaning): it only has
        // to be there, and with Increase Contrast it reaches the window's own progress track's floor
        check(Theme.popoverTrack, on: [Theme.popoverGround], atLeast: 1.1, increasedAtLeast: 1.4, "the band's used stretch")
        check(Theme.hair, on: [Theme.popoverGround], atLeast: 3, "the free stretch's outline and the dividers", onlyIncreased: true)
        check(Theme.accent, on: [Theme.popoverGround], atLeast: 3, "what can go, and what was freed", onlyIncreased: true)
        check(Theme.review, on: [Theme.popoverGround], atLeast: 3, "Docker's dotted stretch", onlyIncreased: true)
    }

    // MARK: the one-time card

    func testTheCardsWords() {
        check(Theme.ink, on: [Theme.cardGround], atLeast: 7, "the question and its line")
        check(Theme.ink2, on: [Theme.cardGround], atLeast: 4.5, "the small print and Not now")
        check(Theme.ink, on: [Theme.cardGround, Theme.cardButton], atLeast: 7, "Turn on on its soft ground")
    }

    func testWithIncreaseContrastTheCardHasAnEdge() {
        check(Theme.cardEdge, on: [], atLeast: 3, "the card's edge", onlyIncreased: true)
        for dark in [false, true] {
            XCTAssertEqual(Theme.cardEdge.rgba(dark: dark, increasedContrast: false).a, 0, "no edge without Increase Contrast, as on the board")
        }
    }

    // MARK: every new token has its four looks

    func testTheNewTokensHaveStrongerVariantsWhereTheyMatter() {
        for (name, tone) in [("low", Theme.low), ("popoverTrack", Theme.popoverTrack), ("cardGround", Theme.cardGround), ("cardButton", Theme.cardButton)] {
            XCTAssertNotEqual(tone.light, tone.lightStrong, "\(name) in light")
            XCTAssertNotEqual(tone.dark, tone.darkStrong, "\(name) in dark")
        }
    }
}
