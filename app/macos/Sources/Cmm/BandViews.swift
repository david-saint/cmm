import CmmKit
import SwiftUI

/// The band itself: six points tall, segments in proportion to bytes with a 2 pt gap, only the two ends rounded.
/// What is selected is solid green, what has been freed is a green outline, free space is a hairline outline, review is
/// dotted, and everything else is the quiet grey of "used".
struct DiskBandView: View {
    let band: DiskBand
    let width: CGFloat
    var height: CGFloat = 6

    var body: some View {
        let frames = band.frames(width: Double(width), gap: 2, minimum: 2)
        ZStack(alignment: .topLeading) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                segment(frame)
                    .frame(width: frame.width, height: height)
                    .offset(x: frame.x)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: band)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func segment(_ frame: DiskBand.Frame) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: frame.roundsLeading ? 3 : 0, bottomLeadingRadius: frame.roundsLeading ? 3 : 0,
            bottomTrailingRadius: frame.roundsTrailing ? 3 : 0, topTrailingRadius: frame.roundsTrailing ? 3 : 0,
            style: .continuous
        )
        switch frame.kind {
        case .used: shape.fill(Theme.track)
        case .review: DottedFill().clipShape(shape)
        case .selected: shape.fill(Theme.accent)
        case .freed: shape.strokeBorder(Theme.accent, lineWidth: 1.5)
        case .free: shape.strokeBorder(Theme.hair, lineWidth: 1)
        }
    }
}

/// The caption and the band under the text column, and, when there is one, the line about what was held back.
/// The caption and the band are one element for VoiceOver, read as a single sentence.
struct BandBlock: View {
    let band: DiskBand?
    let caption: BandText.Caption
    let sentence: String
    let layout: HeroLayout
    var heldLine: String?
    /// Under the confirmation card the bar stays and the words around it go.
    var covered = false

    var body: some View {
        let s = layout.scale
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let leading = caption.leading {
                        Text(leading)
                    }
                    Spacer(minLength: 12)
                    CaptionRuns(runs: caption.trailing)
                }
                .font(Typeface.ui(12 * s))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .opacity(covered ? 0 : 1)

                if let band {
                    DiskBandView(band: band, width: layout.bandWidth, height: 6)
                        .padding(.top, 10 * s)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence)

            if let heldLine {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12 * s))
                    Text(heldLine)
                }
                .font(Typeface.ui(11.5 * s))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .padding(.top, 14 * s)
                .opacity(covered ? 0 : 1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: layout.bandWidth, alignment: .leading)
    }
}

/// The right part of the caption: plain runs, the emphasized figure in ink and semibold, an arrow set off by 6 pt.
struct CaptionRuns: View {
    let runs: [BandText.Run]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                if run.isArrow {
                    Text(run.text).padding(.horizontal, 6)
                } else if run.emphasized {
                    Text(run.text).foregroundStyle(Theme.ink).fontWeight(.semibold)
                } else {
                    Text(run.text)
                }
            }
        }
    }
}
