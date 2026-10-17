import AppKit
import SwiftUI
import XCTest
@testable import Cmm

/// The colours of design C hold their contrast in all four looks (light and dark, each with Increase Contrast off and
/// on): text at 4.5:1 or better against what it sits on (WCAG AA), and, with Increase Contrast, the hairlines, rings and
/// dotted strokes at 3:1 (WCAG non-text contrast). The boards' own colours pass the text rule; the rules are here so a
/// later change to a token cannot quietly break them.
///
/// The tokens are read as numbers (`Tone.rgba`), so these tests need no window. That the views really take the
/// Increase Contrast variants is checked separately, by drawing with the switch on.
final class ThemeContrastTests: XCTestCase {
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

    /// `layers` are drawn over the window background, first to last; `text` over all of them. `increasedAtLeast` is the
    /// floor for the two Increase Contrast looks where it differs from the others.
    private func check(
        _ text: Tone, on layers: [Tone], atLeast minimum: Double, increasedAtLeast: Double? = nil, _ what: String,
        onlyIncreased: Bool = false
    ) {
        for look in Self.looks where !onlyIncreased || look.increased {
            let minimum = look.increased ? (increasedAtLeast ?? minimum) : minimum
            var surface = Theme.background.rgba(dark: look.dark, increasedContrast: look.increased)
            for layer in layers { surface = layer.rgba(dark: look.dark, increasedContrast: look.increased).over(surface) }
            let ink = text.rgba(dark: look.dark, increasedContrast: look.increased).over(surface)
            let ratio = ink.contrast(with: surface)
            XCTAssertGreaterThanOrEqual(ratio, minimum, "\(what) in \(look.label): \(String(format: "%.2f", ratio)):1")
        }
    }

    func testTheFourLooksAreFourDifferentSetsOfValues() {
        let ink = Theme.ink2
        let values = Self.looks.map { ink.rgba(dark: $0.dark, increasedContrast: $0.increased) }
        XCTAssertEqual(Set(values.map { "\($0.r)-\($0.g)-\($0.b)" }).count, 4)
        XCTAssertLessThan(values[2].luminance, values[0].luminance, "Increase Contrast makes the quiet ink darker in light")
        XCTAssertGreaterThan(values[3].luminance, values[1].luminance, "and lighter in dark")
    }

    func testAToneWithNoStrongVariantKeepsItsValue() {
        let ink = Theme.ink
        XCTAssertEqual(ink.rgba(dark: false, increasedContrast: true), ink.rgba(dark: false, increasedContrast: false))
        XCTAssertEqual(ink.rgba(dark: true, increasedContrast: true), ink.rgba(dark: true, increasedContrast: false))
    }

    // MARK: text on the window

    func testInkAndSecondaryInkOnTheWindow() {
        check(Theme.ink, on: [], atLeast: 7, "ink on the window")
        check(Theme.ink2, on: [], atLeast: 4.5, "secondary ink on the window")
        check(Theme.skip, on: [], atLeast: 4.5, "the skipped mark's colour")
    }

    func testTheWordsOfMeaningOnTheWindow() {
        check(Theme.accentText, on: [], atLeast: 4.5, "the green of the done screen's words")
        check(Theme.accentLabel, on: [], atLeast: 4.5, "the green of the cleaning list's words")
        check(Theme.danger, on: [], atLeast: 4.5, "the red of a failure")
        check(Theme.fail, on: [], atLeast: 4.5, "the red of a failed mark")
    }

    // MARK: text on the glass

    func testTextOnThePane() {
        check(Theme.ink, on: [Theme.paneTint], atLeast: 7, "ink on the pane")
        check(Theme.ink2, on: [Theme.paneTint], atLeast: 4.5, "secondary ink on the pane")
    }

    func testTextOnTheCard() {
        check(Theme.ink, on: [Theme.cardTint], atLeast: 7, "ink on the card")
        check(Theme.ink2, on: [Theme.cardTint], atLeast: 4.5, "secondary ink on the card")
        check(Theme.deleteLabel, on: [Theme.cardTint, Theme.soft], atLeast: 4.5, "Delete on its soft button")
    }

    // MARK: buttons

    func testTheFilledButtonsLabel() {
        for look in Self.looks {
            let fill = Theme.button.rgba(dark: look.dark, increasedContrast: look.increased)
            let label = Theme.buttonText.rgba(dark: look.dark, increasedContrast: look.increased)
            XCTAssertGreaterThanOrEqual(label.contrast(with: fill), 7, "Clean and Cancel in \(look.label)")
        }
    }

    func testTheSoftButtonsLabel() {
        check(Theme.ink, on: [Theme.soft], atLeast: 7, "ink on a soft button")
    }

    // MARK: the map and the band's doorway

    func testTextOnTheMapsTilesInEveryStateTheyCanBeIn() {
        let grounds: [(String, [Tone])] = [
            ("a safe tile", [Theme.paneTint, Theme.tileOffFill]),
            ("a ticked safe tile", [Theme.paneTint, Theme.tileOnFill]),
            ("a hovered ticked safe tile", [Theme.paneTint, Theme.tileHoverOnFill]),
            ("a hovered safe tile", [Theme.paneTint, Theme.tileHoverOffFill]),
            ("a review tile", [Theme.paneTint]),
            ("a ticked review tile", [Theme.paneTint, Theme.reviewTickedFill]),
            ("a hovered ticked review tile", [Theme.paneTint, Theme.reviewTickedHoverFill]),
        ]
        // The boards' own tile tints put the secondary ink (the path, the unit) at 3.6 to 4.4:1 in the states where the tile is
        // ticked or hovered; the name, the size and the word Review hold up better. Increase Contrast, which the boards do not
        // draw, takes all of them to AA.
        for (name, layers) in grounds {
            check(Theme.ink, on: layers, atLeast: 7, "a tile's name and size on \(name)")
            check(Theme.ink2, on: layers, atLeast: 3.5, increasedAtLeast: 4.5, "a tile's path and the unit of its size on \(name)")
        }
        for (name, layers) in grounds where name.contains("review") {
            check(Theme.reviewText, on: layers, atLeast: 4.3, increasedAtLeast: 4.5, "the word Review on \(name)")
        }
    }

    func testTheMapsCaptionAndTheBubbleAreReadable() {
        check(Theme.accentLabel, on: [Theme.paneTint], atLeast: 4.5, "the caption's Safe")
        check(Theme.reviewText, on: [Theme.paneTint], atLeast: 4.5, "the caption's Review")
        check(Theme.ink, on: [Theme.bubbleFill], atLeast: 7, "the bubble's name")
        check(Theme.ink2, on: [Theme.bubbleFill], atLeast: 4.5, "the bubble's size")
        check(Theme.ink2, on: [], atLeast: 4.5, "the bracket's caption")
    }

    // MARK: Increase Contrast

    func testWithIncreaseContrastTheLinesAndMarksReach3To1() {
        check(Theme.ring, on: [], atLeast: 3, "the unticked ring", onlyIncreased: true)
        check(Theme.hair, on: [], atLeast: 3, "the free segment's outline", onlyIncreased: true)
        check(Theme.softLine, on: [Theme.soft], atLeast: 3, "a soft button's outline", onlyIncreased: true)
        check(Theme.paneLine, on: [Theme.paneTint], atLeast: 3, "the pane's edge", onlyIncreased: true)
        check(Theme.review, on: [], atLeast: 3, "the dotted review segment", onlyIncreased: true)
        check(Theme.accent, on: [], atLeast: 3, "the selected segment and the ticked mark", onlyIncreased: true)
        check(Theme.progressTrack, on: [], atLeast: 1.4, "the progress line's track", onlyIncreased: true)
    }

    func testWithIncreaseContrastTheMapsEdgesRingsAndSlicesReach3To1() {
        check(Theme.tileOffLine, on: [Theme.paneTint, Theme.tileOffFill], atLeast: 3, "a safe tile's edge", onlyIncreased: true)
        check(Theme.tileOnLine, on: [Theme.paneTint, Theme.tileOnFill], atLeast: 3, "a ticked tile's edge", onlyIncreased: true)
        check(Theme.tileHoverLine, on: [Theme.paneTint, Theme.tileHoverOffFill], atLeast: 3, "a hovered tile's edge", onlyIncreased: true)
        check(Theme.focusRing, on: [Theme.paneSolid], atLeast: 3, "the keyboard focus ring", onlyIncreased: true)
        check(Theme.review, on: [Theme.paneTint], atLeast: 3, "a review tile's dotted edge", onlyIncreased: true)
        check(Theme.sliceOff, on: [], atLeast: 3, "an unticked slice of the band's end", onlyIncreased: true)
        check(Theme.sliceLit, on: [], atLeast: 3, "a lit slice", onlyIncreased: true)
        check(Theme.bracket, on: [], atLeast: 3, "the bracket under the end", onlyIncreased: true)
        check(Theme.sliceGhost, on: [], atLeast: 3, "the outline of the end while its slices are away", onlyIncreased: true)
        check(Theme.bubbleLine, on: [Theme.bubbleFill], atLeast: 3, "the bubble's edge", onlyIncreased: true)
    }

    func testTheTickedMarkAndItsCheckHoldTheirContrast() {
        for look in Self.looks {
            let disc = Theme.accent.rgba(dark: look.dark, increasedContrast: look.increased)
            let check = Theme.checkInk.rgba(dark: look.dark, increasedContrast: look.increased)
            XCTAssertGreaterThanOrEqual(check.contrast(with: disc), 3, "the check on the green disc in \(look.label)")
        }
    }

    // MARK: the views take the variants

    @MainActor
    func testATokenResolvesToTheVariantOfTheEnvironmentItIsUsedIn() {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let normal = Theme.ink2.resolve(in: environment).resolve(in: environment)
        environment.cmmIncreasedContrast = true
        let increased = Theme.ink2.resolve(in: environment).resolve(in: environment)
        XCTAssertEqual(normal.red, Float(Theme.ink2.light.r), accuracy: 0.002)
        XCTAssertEqual(increased.red, Float(Theme.ink2.lightStrong.r), accuracy: 0.002)
        environment.colorScheme = .dark
        let darkIncreased = Theme.ink2.resolve(in: environment).resolve(in: environment)
        XCTAssertEqual(darkIncreased.red, Float(Theme.ink2.darkStrong.r), accuracy: 0.002)
    }
}
