import SwiftUI

// The colours of the menu bar item, its popover, the one-time card and Settings that the window's tokens do not already have,
// read from the boards `C-MenuBar-States`, `C-MenuBar-Dark` and `C-Optin`. They are kept apart from `Theme.swift` so the two
// halves of the milestone can be merged without touching the same lines; the contrast tests hold them to the same floors.

extension Theme {
    /// The amber dot of "Low on space" (the boards' `--low`), in the menu bar item and the popover's header. It is never the only
    /// signal: the words "Low on space" (and VoiceOver's "low on space") go with it.
    static let low = Tone(
        light: RGBA(0xC77700), dark: RGBA(0xF0A43A), lightStrong: RGBA(0x9A5C00), darkStrong: RGBA(0xFFBE5C)
    )

    /// The popover's ground as the boards draw it. The system draws the real one (the menu bar item's panel and its material);
    /// this is what the renders put behind the popover to compare it with the boards, and what the contrast tests measure on.
    static let popoverGround = Tone(
        light: RGBA(0xFAFAFC, 0.96), dark: RGBA(0x26262A, 0.84), lightStrong: RGBA(0xFAFAFC, 0.96), darkStrong: RGBA(0x26262A, 0.84)
    )

    /// The band's "used" stretch in the popover (the boards' popover `--track`): a step lighter in dark than the window's, which
    /// would vanish into the panel's darker ground.
    static let popoverTrack = Tone(
        light: RGBA(0xE3E3E6), dark: RGBA(0x2C2C30), lightStrong: RGBA(0xC4C4CA), darkStrong: RGBA(0x4A4A50)
    )

    /// The one-time card's soft ground and its soft "Turn on" button (the board's `--soft` and `--soft-btn`).
    static let cardGround = Tone(
        light: RGBA(0x000000, 0.035), dark: RGBA(0xFFFFFF, 0.06), lightStrong: RGBA(0x000000, 0.06), darkStrong: RGBA(0xFFFFFF, 0.10)
    )
    static let cardButton = Tone(
        light: RGBA(0x000000, 0.07), dark: RGBA(0xFFFFFF, 0.12), lightStrong: RGBA(0x000000, 0.14), darkStrong: RGBA(0xFFFFFF, 0.18)
    )
    /// The card's edge, drawn only with Increase Contrast, where its soft ground alone would not stand out.
    static let cardEdge = Tone(
        light: RGBA(0x000000, 0), dark: RGBA(0xFFFFFF, 0), lightStrong: RGBA(0x000000, 0.55), darkStrong: RGBA(0xFFFFFF, 0.60)
    )
}
