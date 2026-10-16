import CmmKit
import SwiftUI

/// One tile of the map: a button that ticks or unticks what it stands for, drawn as the boards draw it.
///
/// Safe tiles are green (a little when not ticked, more when ticked), review tiles have a dotted amber edge and no fill
/// until they are ticked. A badge, the same round checkbox as the list's, sits 8 pt from the top left, and what else is
/// written depends on the tile's size (`TileLabels`). Hover lifts the fill; the keyboard focus is a 2 pt ring 2 pt outside.
struct MapTileView: View {
    let tile: MapTile
    let hovered: Bool
    let focused: Bool
    /// The tile was clicked: it takes the focus and ticks.
    let select: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let size = tile.rect.size
        let level = TileLabels.level(for: size)
        let radius = TileLabels.cornerRadius(for: size)
        Button(action: select) {
            ZStack(alignment: .topLeading) {
                TileSkin(tile: tile, hovered: hovered, radius: radius)
                if level.showsBadge {
                    RoundCheck(state: tile.state, size: 16, solidOff: true)
                        .padding(.leading, TileLabels.badgeOrigin(for: size).x)
                        .padding(.top, TileLabels.badgeOrigin(for: size).y)
                }
                words(level: level, size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .overlay {
            if focused { ring(radius: radius) }
        }
        .onHover(perform: hover)
        .help(tile.spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityValue(tile.accessibilityValue)
        .accessibilityHint(tile.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, select)
    }

    /// 2 pt of the pane's own colour, then a 2 pt ring of ink: the boards' `0 0 0 2px pane, 0 0 0 4px focus`.
    private func ring(radius: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius + 2, style: .continuous).strokeBorder(Theme.paneSolid, lineWidth: 2).padding(-2)
            RoundedRectangle(cornerRadius: radius + 4, style: .continuous).strokeBorder(Theme.focusRing, lineWidth: 2).padding(-4)
        }
        .allowsHitTesting(false)
    }

    // MARK: the words on it

    @ViewBuilder private func words(level: TileLabels.Level, size: CGSize) -> some View {
        switch level {
        case .nameAndSize:
            nameBlock(size: size)
            sizeBlock(size: size)
        case .sizeOnly:
            Text(tile.sizeText)
                .font(Typeface.ui(12, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.leading, 30)
                .frame(width: size.width, height: size.height, alignment: .leading)
        case .badgeOnly, .fillOnly:
            EmptyView()
        }
    }

    private func nameBlock(size: CGSize) -> some View {
        let style = TileLabels.sizeStyle(for: size)
        let titleFont = Typeface.ui(style == .hero ? 13 : 12, .semibold)
        return Group {
            if tile.isReview {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(tile.title).font(titleFont).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                        reviewMark
                    }
                    Text(tile.title).font(titleFont).foregroundStyle(Theme.ink).lineLimit(2)
                }
            } else if let subtitle = tile.subtitle {
                // the path under the name only when both fit on a line each, as on the boards
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.title).font(titleFont).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                        // the boards' sub-line sits in the name's 15 pt line box
                        Text(subtitle).font(Typeface.mono(10.5)).foregroundStyle(Theme.ink2).lineLimit(1).fixedSize()
                            .frame(height: 15)
                    }
                    Text(tile.title).font(titleFont).foregroundStyle(Theme.ink).lineLimit(2)
                }
            } else {
                Text(tile.title).font(titleFont).foregroundStyle(Theme.ink).lineLimit(2)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .padding(.top, 7)
        .frame(width: size.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var reviewMark: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.review).frame(width: 6, height: 6)
            Text("Review").font(Typeface.ui(11, .semibold)).foregroundStyle(Theme.reviewText)
        }
        .fixedSize()
    }

    @ViewBuilder private func sizeBlock(size: CGSize) -> some View {
        let parts = SizeText.parts(tile.bytes)
        let bottom: CGFloat = size.height < 72 ? 6 : 7
        Group {
            switch TileLabels.sizeStyle(for: size) {
            case .hero:
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(parts.value).font(Typeface.ui(30, .light)).tracking(-0.6).foregroundStyle(Theme.ink)
                    Text(parts.unit).font(Typeface.ui(14)).foregroundStyle(Theme.ink2)
                }
                .padding(.leading, 10)
                .padding(.bottom, 9)
            case .large:
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.value).font(Typeface.ui(22, .light)).tracking(-0.44).foregroundStyle(Theme.ink)
                    Text(parts.unit).font(Typeface.ui(12)).foregroundStyle(Theme.ink2)
                }
                .padding(.leading, 10)
                .padding(.bottom, 8)
            case .regular:
                Text(tile.sizeText)
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.leading, 9)
                    .padding(.bottom, bottom)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }
}

/// A tile's fill and edge, as the boards draw them, without its words. It is also what a band slice turns into on the way
/// from the band to the map.
///
/// Safe tiles are green (a little when not ticked, more when ticked) with a 1 pt edge; review tiles have no fill until they
/// are ticked and a dotted amber edge at full strength; hover lifts the fill.
struct TileSkin: View {
    let tile: MapTile
    var hovered = false
    let radius: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            outline
        }
    }

    private var fill: Tone {
        if tile.isReview {
            switch (tile.state == .off, hovered) {
            case (true, false): return Theme.nothing
            case (true, true): return Theme.reviewHoverFill
            case (false, false): return Theme.reviewTickedFill
            case (false, true): return Theme.reviewTickedHoverFill
            }
        }
        switch (tile.state == .off, hovered) {
        case (true, false): return Theme.tileOffFill
        case (true, true): return Theme.tileHoverOffFill
        case (false, false): return Theme.tileOnFill
        case (false, true): return Theme.tileHoverOnFill
        }
    }

    @ViewBuilder private var outline: some View {
        if tile.isReview {
            // a dotted 1.5 pt amber edge at full strength, whatever the state
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .inset(by: 0.75)
                .stroke(Theme.review, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0, 3]))
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(hovered ? Theme.tileHoverLine : (tile.state == .off ? Theme.tileOffLine : Theme.tileOnLine), lineWidth: 1)
        }
    }
}
