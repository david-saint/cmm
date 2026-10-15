import AppKit
import SwiftUI

/// The colours and type of design C.
///
/// Every colour is a pair (light, dark) read from the boards, resolved by the appearance of the window it is drawn in,
/// so the window follows the system without any code asking which mode it is. Where the person has turned on Increase
/// Contrast, the hairlines, the dotted strokes and the rings get a stronger variant that stays visible against the
/// background.
enum Theme {
    // Surfaces and ink
    static let background = tone(c(0xFFFFFF), c(0x0B0B0C))
    static let ink = tone(c(0x0D0D0F), c(0xF5F5F7))
    static let ink2 = tone(c(0x6C6C70), c(0x98989D), lightContrast: c(0x48484C), darkContrast: c(0xB9B9BE))

    // Lines
    static let hair = tone(c(0x000000, 0.08), c(0xFFFFFF, 0.09), lightContrast: c(0x000000, 0.40), darkContrast: c(0xFFFFFF, 0.45))
    static let ring = tone(c(0x000000, 0.28), c(0xFFFFFF, 0.34), lightContrast: c(0x000000, 0.62), darkContrast: c(0xFFFFFF, 0.72))
    static let paneLine = tone(c(0x000000, 0.07), c(0xFFFFFF, 0.08), lightContrast: c(0x000000, 0.35), darkContrast: c(0xFFFFFF, 0.40))

    // Meaning: green is what goes, amber is what needs a look
    static let accent = tone(c(0x14975A), c(0x30C477), lightContrast: c(0x0B6B3F), darkContrast: c(0x5BE08F))
    static let accentText = tone(c(0x0F7A47), c(0x4AD28A), lightContrast: c(0x0A5D35), darkContrast: c(0x7AEBA6))
    static let review = tone(c(0xD58A1E), c(0xE9A23B), lightContrast: c(0xA8650A), darkContrast: c(0xF4B656))
    static let reviewText = tone(c(0x9A5A00), c(0xEDB15A))
    static let reviewFill = tone(
        c(0xD58A1E, 0.16), c(0xE9A23B, 0.18), lightContrast: c(0xD58A1E, 0.26), darkContrast: c(0xE9A23B, 0.30)
    )

    // The band and the progress line
    static let track = tone(c(0xE9E9EC), c(0x232326), lightContrast: c(0xCFCFD4), darkContrast: c(0x3A3A3F))
    static let progressTrack = tone(
        c(0x000000, 0.08), c(0xFFFFFF, 0.12), lightContrast: c(0x000000, 0.22), darkContrast: c(0xFFFFFF, 0.30)
    )

    // Buttons
    static let button = tone(c(0x0D0D0F), c(0xF5F5F7))
    static let buttonText = tone(c(0xFFFFFF), c(0x0B0B0C))
    static let soft = tone(c(0x000000, 0.05), c(0xFFFFFF, 0.08), lightContrast: c(0x000000, 0.12), darkContrast: c(0xFFFFFF, 0.18))
    static let softLine = tone(
        c(0x000000, 0.08), c(0xFFFFFF, 0.16), lightContrast: c(0x000000, 0.40), darkContrast: c(0xFFFFFF, 0.50)
    )
    static let hover = tone(c(0x000000, 0.06), c(0xFFFFFF, 0.10))
    static let checkInk = tone(c(0xFFFFFF), c(0x0B0B0C))

    // Results
    static let danger = tone(c(0xC8102E), c(0xFF6961))
    static let fail = tone(c(0xC8102E), c(0xFF6961))
    static let skip = tone(c(0x6C6C70), c(0x98989D), lightContrast: c(0x48484C), darkContrast: c(0xB9B9BE))

    // The glass of the pane and the card when the system's own glass is not available
    static let paneTint = tone(c(0xF6F6F7, 0.86), c(0x1E1E20, 0.84))
    static let cardTint = tone(c(0xFCFCFD, 0.86), c(0x28282B, 0.86))

    // MARK: building colours

    /// `0xRRGGBB` with an optional alpha, in sRGB.
    private static func c(_ hex: Int, _ alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha)
        )
    }

    /// A colour that is `light` in a light window and `dark` in a dark one, with stronger variants for Increase Contrast.
    private static func tone(
        _ light: NSColor, _ dark: NSColor, lightContrast: NSColor? = nil, darkContrast: NSColor? = nil
    ) -> Color {
        let lightStrong = lightContrast ?? light
        let darkStrong = darkContrast ?? dark
        return Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return dark
            case .accessibilityHighContrastDarkAqua?: return darkStrong
            case .accessibilityHighContrastAqua?: return lightStrong
            default: return light
            }
        })
    }
}

/// The three faces of the design: SF for the interface, New York for the phrase under the number, SF Mono for paths.
enum Typeface {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
