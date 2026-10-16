import SwiftUI

/// The colours the History face adds to design C (the boards `C-History` and `C-History-Dark`), each with a stronger variant
/// for Increase Contrast. Everything else on the face uses the tokens of `Theme`.
extension Theme {
    /// The ground of a cleaning that is open to its items: ink at 3.5 % (white at 5 % in dark).
    static let historyOpenRow = historyTone(
        RGBA(0x000000, 0.035), RGBA(0xFFFFFF, 0.05), lightStrong: RGBA(0x000000, 0.07), darkStrong: RGBA(0xFFFFFF, 0.09)
    )
}

private func historyTone(_ light: RGBA, _ dark: RGBA, lightStrong: RGBA? = nil, darkStrong: RGBA? = nil) -> Tone {
    Tone(light: light, dark: dark, lightStrong: lightStrong ?? light, darkStrong: darkStrong ?? dark)
}
