import SwiftUI

/// A colour in sRGB, as plain numbers, so the tokens can be read and measured (the contrast tests do) without a window.
struct RGBA: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    /// `0xRRGGBB` with an optional alpha.
    init(_ hex: Int, _ alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    init(r: Double, g: Double, b: Double, a: Double) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// This colour laid over an opaque `background`.
    func over(_ background: RGBA) -> RGBA {
        RGBA(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a), a: 1)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio, 1 to 21.
    func contrast(with other: RGBA) -> Double {
        let (x, y) = (luminance, other.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// A token of the design: a colour in a light window and in a dark one, and a stronger one for each when the person has
/// turned on Increase Contrast.
///
/// It is a `ShapeStyle`, so it goes wherever a colour does (`foregroundStyle`, `fill`, `strokeBorder`) and is resolved
/// there, from that view's own environment: its colour scheme, and `colorSchemeContrast`, which SwiftUI sets from the
/// system's Increase Contrast switch. Resolving it in the environment (rather than through an `NSColor` that is asked
/// for its appearance) is what makes the contrast variants reachable, and testable: `cmmIncreasedContrast` stands in
/// for the switch.
struct Tone: ShapeStyle, Sendable {
    let light: RGBA
    let dark: RGBA
    let lightStrong: RGBA
    let darkStrong: RGBA

    func rgba(dark isDark: Bool, increasedContrast: Bool) -> RGBA {
        switch (isDark, increasedContrast) {
        case (false, false): light
        case (true, false): dark
        case (false, true): lightStrong
        case (true, true): darkStrong
        }
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        rgba(
            dark: environment.colorScheme == .dark,
            increasedContrast: environment.colorSchemeContrast == .increased || environment.cmmIncreasedContrast
        ).color
    }
}

/// The colours and type of design C.
///
/// Every colour is a pair (light, dark) read from the boards. Where the person has turned on Increase Contrast, the
/// hairlines, the dotted strokes, the rings and the quiet text get a stronger variant that stays visible against the
/// background.
enum Theme {
    // Surfaces and ink
    static let background = tone(0xFFFFFF, 0x0B0B0C)
    static let ink = tone(0x0D0D0F, 0xF5F5F7)
    static let ink2 = tone(0x6C6C70, 0x98989D, lightStrong: 0x48484C, darkStrong: 0xB9B9BE)

    // Lines
    static let hair = tone(RGBA(0x000000, 0.08), RGBA(0xFFFFFF, 0.09), lightStrong: RGBA(0x000000, 0.55), darkStrong: RGBA(0xFFFFFF, 0.60))
    static let ring = tone(RGBA(0x000000, 0.28), RGBA(0xFFFFFF, 0.34), lightStrong: RGBA(0x000000, 0.62), darkStrong: RGBA(0xFFFFFF, 0.72))
    static let paneLine = tone(RGBA(0x000000, 0.07), RGBA(0xFFFFFF, 0.08), lightStrong: RGBA(0x000000, 0.45), darkStrong: RGBA(0xFFFFFF, 0.50))

    // Meaning: green is what goes, amber is what needs a look
    static let accent = tone(0x14975A, 0x30C477, lightStrong: 0x0B6B3F, darkStrong: 0x5BE08F)
    static let accentText = tone(0x0F7A47, 0x4AD28A, lightStrong: 0x0A5D35, darkStrong: 0x7AEBA6)
    /// The green of a word that is set small (the cleaning list's "Removing" and "Deleted"): the boards' dark accent as it
    /// is, and in light the darker text green, which holds 4.5:1 on white where the mark's green does not.
    static let accentLabel = tone(0x0F7A47, 0x30C477, lightStrong: 0x0A5D35, darkStrong: 0x5BE08F)
    static let review = tone(0xD58A1E, 0xE9A23B, lightStrong: 0xA8650A, darkStrong: 0xF4B656)
    static let reviewText = tone(0x9A5A00, 0xEDB15A)
    static let reviewFill = tone(
        RGBA(0xD58A1E, 0.16), RGBA(0xE9A23B, 0.18), lightStrong: RGBA(0xD58A1E, 0.26), darkStrong: RGBA(0xE9A23B, 0.30)
    )

    // The band and the progress line
    static let track = tone(0xE9E9EC, 0x232326, lightStrong: 0xCFCFD4, darkStrong: 0x3A3A3F)
    static let progressTrack = tone(
        RGBA(0x000000, 0.08), RGBA(0xFFFFFF, 0.12), lightStrong: RGBA(0x000000, 0.22), darkStrong: RGBA(0xFFFFFF, 0.30)
    )

    // Buttons
    static let button = tone(0x0D0D0F, 0xF5F5F7)
    static let buttonText = tone(0xFFFFFF, 0x0B0B0C)
    static let soft = tone(RGBA(0x000000, 0.05), RGBA(0xFFFFFF, 0.08), lightStrong: RGBA(0x000000, 0.12), darkStrong: RGBA(0xFFFFFF, 0.18))
    static let softLine = tone(RGBA(0x000000, 0.08), RGBA(0xFFFFFF, 0.16), lightStrong: RGBA(0x000000, 0.55), darkStrong: RGBA(0xFFFFFF, 0.65))
    static let hover = tone(RGBA(0x000000, 0.06), RGBA(0xFFFFFF, 0.10))
    static let checkInk = tone(0xFFFFFF, 0x0B0B0C)

    // Results
    static let danger = tone(0xC8102E, 0xFF6961, lightStrong: 0xA30D26, darkStrong: 0xFFB0AA)
    static let fail = danger
    /// "Delete N Items" on the card's soft button: the board's red, a touch lighter in dark where the board's own would
    /// fall just under 4.5:1 on that button's lighter ground.
    static let deleteLabel = tone(0xC8102E, 0xFF7A72, lightStrong: 0xA30D26, darkStrong: 0xFFB0AA)
    static let skip = tone(0x6C6C70, 0x98989D, lightStrong: 0x48484C, darkStrong: 0xB9B9BE)

    // The glass of the pane and the card, laid over the system's own glass or material
    static let paneTint = tone(RGBA(0xF6F6F7, 0.86), RGBA(0x1E1E20, 0.84))
    static let cardTint = tone(RGBA(0xFCFCFD, 0.86), RGBA(0x28282B, 0.86))

    // The pane's one soft shadow (CSS 0 10 30) and the card's long one (0 28 64, pulled in by 10) and near one (0 4 14).
    // SwiftUI's radius is the Gaussian's sigma, which is half of a CSS blur; the long one is pushed a little further
    // down and made a little lighter in place of the CSS spread, which SwiftUI does not have.
    static let paneShadow = SurfaceShadow(color: tone(RGBA(0x000000, 0.07), RGBA(0x000000, 0.45)), radius: 15, y: 10)
    static let cardShadow = SurfaceShadow(color: tone(RGBA(0x000000, 0.22), RGBA(0x000000, 0.55)), radius: 28, y: 30)
    static let cardNearShadow = SurfaceShadow(color: tone(RGBA(0x000000, 0.08), RGBA(0x000000, 0.35)), radius: 7, y: 4)

    // MARK: building tokens

    private static func tone(_ light: RGBA, _ dark: RGBA, lightStrong: RGBA? = nil, darkStrong: RGBA? = nil) -> Tone {
        Tone(light: light, dark: dark, lightStrong: lightStrong ?? light, darkStrong: darkStrong ?? dark)
    }

    private static func tone(_ light: Int, _ dark: Int, lightStrong: Int? = nil, darkStrong: Int? = nil) -> Tone {
        tone(RGBA(light), RGBA(dark), lightStrong: lightStrong.map { RGBA($0) }, darkStrong: darkStrong.map { RGBA($0) })
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
