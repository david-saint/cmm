import SwiftUI

/// The colours the History face adds to design C (the boards `C-History` and `C-History-Dark`), each with a stronger variant
/// for Increase Contrast. Everything else on the face uses the tokens of `Theme`.
extension Theme {
    /// The ground of a cleaning that is open to its items: ink at 3.5 % (white at 5 % in dark).
    static let historyOpenRow = historyTone(
        RGBA(0x000000, 0.035), RGBA(0xFFFFFF, 0.05), lightStrong: RGBA(0x000000, 0.07), darkStrong: RGBA(0xFFFFFF, 0.09)
    )

    // The chart
    /// The line of what was free: ink at 72 % (white at 78 % in dark).
    static let historyLine = historyTone(
        RGBA(0x0D0D0F, 0.72), RGBA(0xF5F5F7, 0.78), lightStrong: RGBA(0x0D0D0F, 0.92), darkStrong: RGBA(0xF5F5F7, 0.95)
    )
    /// The read-out's vertical line: ink at 35 %.
    static let historyCursor = historyTone(
        RGBA(0x0D0D0F, 0.35), RGBA(0xF5F5F7, 0.35), lightStrong: RGBA(0x0D0D0F, 0.65), darkStrong: RGBA(0xF5F5F7, 0.70)
    )
    /// The read-out's box, its edge and its shadow.
    static let historyTip = historyTone(RGBA(0xFFFFFF, 0.94), RGBA(0x2C2C30, 0.95))
    static let historyTipLine = historyTone(
        RGBA(0x000000, 0.12), RGBA(0xFFFFFF, 0.12), lightStrong: RGBA(0x000000, 0.55), darkStrong: RGBA(0xFFFFFF, 0.65)
    )
    static let historyTipShadow = historyTone(RGBA(0x000000, 0.12), RGBA(0x000000, 0.50))
    /// "No samples" over a gap: the quiet ink, a little fainter still. The board sets it at 75 %, which is about 3:1 on the
    /// pane; at 85 % it keeps the floor of the map's quiet words (3.5:1), and with Increase Contrast it is the strong quiet ink.
    static let historyQuiet = historyTone(
        RGBA(0x6C6C70, 0.85), RGBA(0x98989D, 0.85), lightStrong: RGBA(0x48484C), darkStrong: RGBA(0xB9B9BE)
    )
}

private func historyTone(_ light: RGBA, _ dark: RGBA, lightStrong: RGBA? = nil, darkStrong: RGBA? = nil) -> Tone {
    Tone(light: light, dark: dark, lightStrong: lightStrong ?? light, darkStrong: darkStrong ?? dark)
}
