import CmmKit
import SwiftUI

/// The block every screen opens with: a line of small print, the big number with its unit, and a phrase in New York.
///
/// The boards set the number with `line-height: 0.9`; centring the text in a frame 0.9 em tall puts the baseline where
/// the browser puts it, because the "half-leading" of a short line box is split evenly above and below.
struct HeroHeader: View {
    let layout: HeroLayout
    let eyebrow: String
    let number: SizeText.Parts
    let phrase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(Typeface.ui(layout.eyebrowSize, .medium))
                .tracking(layout.eyebrowSize * 0.01)
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .lineLimit(1)
            BigNumber(number: number, layout: layout)
                .padding(.top, layout.numberTopGap)
            Phrase(text: phrase, size: layout.phraseSize)
                .padding(.top, layout.phraseTopGap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.text) \(phrase)")
        .accessibilityValue(eyebrow)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `8.4` and `GB`: the figure in a hairline weight, its unit lighter and grey, on one baseline.
struct BigNumber: View {
    let number: SizeText.Parts
    let layout: HeroLayout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: layout.numberGap) {
            Text(number.value)
                .font(Typeface.ui(layout.numberSize, .thin))
                .tracking(-layout.numberSize * 0.05)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Text(number.unit)
                .font(Typeface.ui(layout.unitSize, .light))
                .tracking(-layout.unitSize * 0.02)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: layout.numberSize * 0.9)
    }
}

/// The serif phrase under the number ("is safe to remove."), 1.15 line height.
struct Phrase: View {
    let text: String
    let size: Double
    var maxWidth: Double = .infinity

    var body: some View {
        Text(text)
            .font(Typeface.serif(size))
            .tracking(-size * 0.01)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // A fixed 1.15 line box, as in the boards: a taller font overflows it equally above and below.
            .frame(height: size * 1.15, alignment: .center)
    }
}

/// Running text with the line height the boards give it (CSS line-height, which SwiftUI spells as spacing plus padding).
struct Paragraph: View {
    let text: String
    let size: Double
    let lineHeight: Double
    var color: Tone = Theme.ink2

    var body: some View {
        // SwiftUI sets SF at about 1.257 em per line; the boards want `lineHeight`, so the difference is added.
        let extra = max(lineHeight - size * 1.257, 0)
        Text(text)
            .font(Typeface.ui(size))
            .foregroundStyle(color)
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension MotionStyle {
    /// The animation for a state change: a gentle spring, or a short crossfade under Reduce Motion.
    var animation: Animation {
        switch self {
        case .spring: .spring(duration: duration, bounce: 0.08)
        case .crossfade: .easeInOut(duration: duration)
        }
    }
}
