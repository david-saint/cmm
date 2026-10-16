import CmmKit
import SwiftUI

/// The free-space chart of the History face (the board `C-History`): the line of what was free, broken where cmm was not
/// running, a green rise at each cleaning that gave the disk something back, the axis from zero, the days under it, the value
/// now, and, under the pointer, the reading nearest to it. It strokes and fills what `HistoryChartLayout` says.
///
/// To VoiceOver it is one element that reads the face's paragraph (the list below it is the same story in words, row by row).
/// Nothing in it moves by itself, so Reduce Motion has nothing to stop.
struct HistoryChart: View {
    let layout: HistoryChartLayout
    let label: String
    let state: HistoryFaceState

    var body: some View {
        Canvas { context, _ in
            Self.draw(layout, in: &context)
        }
        .frame(width: layout.width, height: HistoryChartLayout.height)
        .overlay(alignment: .topLeading) {
            HistoryChartGapWords(layout: layout, state: state)
            HistoryChartReadout(layout: layout, state: state)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): state.pointerTime = layout.time(atX: location.x)
            case .ended: state.pointerTime = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    private static func draw(_ layout: HistoryChartLayout, in context: inout GraphicsContext) {
        let plot = layout.plot

        var zero = Path()
        zero.move(to: CGPoint(x: plot.minX, y: plot.maxY + 0.5))
        zero.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY + 0.5))
        context.stroke(zero, with: .style(Theme.hair), lineWidth: 1)

        let stroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
        for points in layout.lines {
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .style(Theme.historyLine), style: stroke)
        }
        for dot in layout.dots {
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 1.5, y: dot.y - 1.5, width: 3, height: 3)), with: .style(Theme.historyLine))
        }

        for rise in layout.rises {
            var path = Path()
            path.move(to: CGPoint(x: rise.x, y: rise.fromY))
            path.addLine(to: CGPoint(x: rise.x, y: rise.toY))
            context.stroke(path, with: .style(Theme.accent), style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: rise.x - 2.5, y: rise.toY - 2.5, width: 5, height: 5)), with: .style(Theme.accent))
        }

        for label in layout.valueLabels + layout.timeLabels {
            write(label, in: &context, font: Typeface.ui(HistoryChartLayout.labelSize), tone: Theme.ink2)
        }
        if let now = layout.nowLabel {
            write(now, in: &context, font: Typeface.ui(HistoryChartLayout.nowLabelSize, .semibold), tone: Theme.ink)
        }
    }

    static func write(_ label: HistoryChartLayout.Label, in context: inout GraphicsContext, font: Font, tone: Tone) {
        let anchor: UnitPoint = switch label.anchor {
        case .leading: UnitPoint(x: 0, y: 0.5)
        case .center: .center
        case .trailing: UnitPoint(x: 1, y: 0.5)
        }
        context.draw(Text(label.text).font(font).monospacedDigit().foregroundStyle(tone), at: CGPoint(x: label.x, y: label.y), anchor: anchor)
    }
}

/// "No samples" over each gap wide enough for the words, in the quiet ink; the gap under the pointer leaves them to the read-out,
/// which says the same and names the days.
struct HistoryChartGapWords: View {
    let layout: HistoryChartLayout
    let state: HistoryFaceState

    var body: some View {
        let hovered = state.pointerTime.flatMap(layout.gap(at:))
        Canvas { context, _ in
            for gap in layout.gaps where gap != hovered {
                if let label = gap.label {
                    HistoryChart.write(label, in: &context, font: Typeface.ui(HistoryChartLayout.labelSize), tone: Theme.historyQuiet)
                }
            }
        }
        .frame(width: layout.width, height: HistoryChartLayout.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The read-out under the pointer: a thin vertical line, the reading ringed, and its words in a small box beside the line
/// (`Tue 7 Oct, 15:00` over `22.9 GB free`; over a gap, `No samples` over its days). Only the pointer shows it.
struct HistoryChartReadout: View {
    let layout: HistoryChartLayout
    let state: HistoryFaceState
    @Environment(\.cmm) private var env
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let time = state.pointerTime, let readout = layout.readout(at: time) {
            let origin = layout.readoutOrigin(for: readout)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: readout.lineX, y: layout.plot.minY))
                    path.addLine(to: CGPoint(x: readout.lineX, y: layout.plot.maxY))
                }
                .stroke(Theme.historyCursor, lineWidth: 1)
                if let point = readout.point {
                    ZStack {
                        Circle().fill(Theme.background)
                        Circle().stroke(Theme.historyLine, lineWidth: 1.5)
                    }
                    .frame(width: 6, height: 6)
                    .position(point)
                }
                box(readout)
                    .offset(x: origin.x, y: origin.y)
            }
            .frame(width: layout.width, height: HistoryChartLayout.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The board's box: 11 pt words on 15 pt lines, 5 by 9 pt inside a rounded box of 8, with a hairline edge and a soft shadow.
    private func box(_ readout: HistoryChartLayout.Readout) -> some View {
        let shadow = Theme.historyTipShadow.rgba(dark: scheme == .dark, increasedContrast: false).color
        return VStack(alignment: .leading, spacing: 2) {
            Text(readout.first)
                .fontWeight(readout.firstIsEmphasized ? .semibold : .regular)
                .foregroundStyle(readout.firstIsEmphasized ? Theme.ink : Theme.ink2)
            Text(readout.second)
                .fontWeight(readout.firstIsEmphasized ? .regular : .semibold)
                .foregroundStyle(readout.firstIsEmphasized ? Theme.ink2 : Theme.ink)
        }
        .font(Typeface.ui(HistoryChartLayout.readoutSize))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.historyTip)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.historyTipLine, lineWidth: 0.5))
                .shadow(color: shadow, radius: 7, y: 4 * env.shadowDirection)
        }
    }
}
