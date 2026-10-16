import CmmKit
import SwiftUI

/// One segment of the ordinary band: used is the quiet grey, review is dotted, what is ticked is solid green, what has been
/// freed is a green outline and free space is a hairline outline. Only the two ends of the band are rounded.
struct BandSegmentView: View {
    let frame: DiskBand.Frame
    let radius: CGFloat

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: frame.roundsLeading ? radius : 0, bottomLeadingRadius: frame.roundsLeading ? radius : 0,
            bottomTrailingRadius: frame.roundsTrailing ? radius : 0, topTrailingRadius: frame.roundsTrailing ? radius : 0,
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
                BandSegmentView(frame: frame, radius: height / 2)
                    .frame(width: frame.width, height: height)
                    .offset(x: frame.x)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: band)
        .accessibilityHidden(true)
    }
}

/// What the rest screen's band needs to be a doorway to the map: its reclaimable end at five times its width and at its
/// true width (one slice per tile in each, the slices of the one growing into those of the other), and the tiles to name
/// the slices by.
struct BandDoorway {
    let magnified: BandMagnifier
    let collapsed: BandMagnifier
    let tiles: [String: MapTile]

    init?(map: MapModel, capacity: Int64?, free: Int64, width: Double) {
        guard
            let magnified = BandMagnifier(capacity: capacity, free: free, tiles: map.tiles, width: width),
            let collapsed = BandMagnifier(capacity: capacity, free: free, tiles: map.tiles, width: width, enlargement: 1)
        else { return nil }
        self.magnified = magnified
        self.collapsed = collapsed
        self.tiles = Dictionary(uniqueKeysWithValues: map.tiles.map { ($0.id, $0) })
    }
}

/// The caption and the band under the text column, then, when there is one, the quiet line about space that goes
/// inside another program's storage, and the line about what was held back.
/// The caption and the band are one element for VoiceOver, read as a single sentence.
///
/// On the rest screen the band is a doorway to the map: hovered, and for as long as the map is open, it is ten points
/// thick and its reclaimable end is five times as wide, one slice per tile, with a bracket and a caption under it that
/// say so. The pointer names the slice it is on, and a click on a slice opens the map on that tile.
struct BandBlock: View {
    /// Everything the rest screen's band does besides drawing: where the pointer is, which tile has the keyboard, and what
    /// a click on a slice does.
    struct Doorway {
        let band: BandDoorway
        let window: WindowState
        let motion: MotionStyle
        /// A click on a slice: open the map on that tile.
        let open: (String) -> Void
        /// "Show the map" for VoiceOver, which cannot point at a slice.
        let showMap: () -> Void
    }

    let band: DiskBand?
    let caption: BandText.Caption
    let sentence: String
    let layout: HeroLayout
    /// `+ 6.2 GB inside Docker's disk image, not counted above.`
    var insideLine: String?
    var heldLine: String?
    /// Under the confirmation card the bar stays and the words around it go.
    var covered = false
    var doorway: Doorway?

    @State private var sliceUnderPointer: String?

    /// Under the band, when it is magnified: 6 pt of air, the bracket (5), 4 pt, and the caption's line.
    private static let bracketZone = 6.0 + 5.0 + 4.0 + 13.0

    var body: some View {
        let s = layout.scale
        let mapOpen = doorway?.window.mapOpen ?? false
        let magnified = doorway?.window.isBandMagnified ?? false
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
                .frame(height: layout.bandLabelsHeight, alignment: .top)

                if let band {
                    bandZone(band, mapOpen: mapOpen)
                        .padding(.top, layout.bandLineGap)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence)
            .accessibilityAction(named: "Show the map") { doorway?.showMap() }

            if let insideLine {
                Text(insideLine)
                    .font(Typeface.ui(11.5 * s))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10 * s)
                    // hovered, the bracket and its caption are where this line is: it gives way, and comes back
                    .opacity(covered || (magnified && !mapOpen) ? 0 : 1)
            }

            if let heldLine {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12 * s))
                    Text(heldLine)
                }
                .font(Typeface.ui(11.5 * s))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .padding(.top, (insideLine == nil ? 14 : 8) * s)
                .opacity(covered || (magnified && !mapOpen) ? 0 : 1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: layout.bandWidth, alignment: .leading)
    }

    // MARK: the band

    @ViewBuilder private func bandZone(_ band: DiskBand, mapOpen: Bool) -> some View {
        if let doorway {
            let window = doorway.window
            let flying = window.flight?.kind == .unfold
            let magnified = window.isBandMagnified
            let zoneHeight = mapOpen ? BandMagnifier.thickness(magnified: true) + Self.bracketZone : BandMagnifier.thickness(magnified: false)
            ZStack(alignment: .topLeading) {
                DoorwayBand(
                    band: band, doorway: doorway.band, width: layout.bandWidth, magnified: magnified, flying: flying,
                    window: window, motion: doorway.motion
                )
                BandBracket(
                    end: doorway.band.magnified, caption: doorway.band.magnified.caption(whileHovered: !mapOpen), scale: layout.scale
                )
                .offset(y: BandMagnifier.thickness(magnified: true))
                .opacity(magnified && !flying && !covered ? 1 : 0)
                .animation(doorway.motion.animatesMagnifier ? .snappy(duration: FlightClock.hoverDuration) : nil, value: magnified)

                if !flying, !covered, window.bandHovered, let id = window.hoveredTile, let tile = doorway.band.tiles[id],
                    let slice = doorway.band.magnified.slice(for: id)
                {
                    BandBubbleView(bubble: BandBubble(tile: tile), sliceMidX: slice.x + slice.width / 2, bandWidth: layout.bandWidth)
                        .offset(y: -(BandBubbleView.height + 6))
                }

                pointerArea(doorway, magnified: magnified, flying: flying)
            }
            .frame(width: layout.bandWidth, height: zoneHeight, alignment: .topLeading)
        } else {
            DiskBandView(band: band, width: layout.bandWidth, height: 6)
        }
    }

    /// The pointer's place: the band with 8 pt above and below, and, while it is magnified, the bracket and its caption as
    /// well, so that going down from the band to its bracket does not end the hover. Over it, once the end is magnified,
    /// one invisible button per slice (the point after a slice belongs to it): a click on one opens the map on its tile.
    ///
    /// The slices are buttons, and not a tap at a place, so that a click is what a button does everywhere: it can be
    /// tested by clicking, and it is the same click as a tile's. They are left out of VoiceOver, which has the map's tiles
    /// and the band's "Show the map" action.
    private func pointerArea(_ doorway: Doorway, magnified: Bool, flying: Bool) -> some View {
        let pad = 8.0
        let band = BandMagnifier.thickness(magnified: true)
        let below = magnified ? band + Self.bracketZone : BandMagnifier.thickness(magnified: false)
        let end = doorway.band.magnified
        let reach = 3.0
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.bandWidth, height: pad + below + pad)
                .contentShape(Rectangle())
                .offset(y: -pad)
            if magnified, !flying, !covered {
                ForEach(Array(end.slices.enumerated()), id: \.element.id) { index, slice in
                    let isLast = index == end.slices.count - 1
                    Button { doorway.open(slice.id) } label: {
                        Color.clear
                            .frame(width: slice.width + (isLast ? 0 : BandMagnifier.sliceGap), height: band + 2 * reach)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .offset(x: slice.x, y: -reach)
                }
            }
        }
        .onContinuousHover { phase in
            guard !covered else { return }
            switch phase {
            case .active(let point):
                doorway.window.bandHovered = true
                let id = end.sliceID(atX: point.x)
                sliceUnderPointer = id
                if doorway.window.hoveredTile != id { doorway.window.hoveredTile = id }
            case .ended:
                doorway.window.bandHovered = false
                if let id = sliceUnderPointer, doorway.window.hoveredTile == id { doorway.window.hoveredTile = nil }
                sliceUnderPointer = nil
            }
        }
        .accessibilityHidden(true)
    }
}

/// The band as a doorway: the ordinary band, or, magnified, with its reclaimable end enlarged and in slices.
///
/// Used and free are the same two shapes either way: they only change length when the end grows into the used track. The
/// ordinary reclaimable segments (review, ticked) give way to the slices, which spread from the end's true width to its
/// enlarged one. While the tiles are in the air (unfolding) the slices are away, and an empty outline marks where they were.
struct DoorwayBand: View {
    let band: DiskBand
    let doorway: BandDoorway
    let width: CGFloat
    let magnified: Bool
    let flying: Bool
    let window: WindowState
    let motion: MotionStyle
    @Environment(\.cmm) private var env

    var body: some View {
        let frames = band.frames(width: Double(width), gap: 2, minimum: 2)
        let thickness = CGFloat(BandMagnifier.thickness(magnified: magnified))
        let radius = thickness / 2
        let end = doorway.magnified
        let usedWidth = magnified ? end.usedWidth : (frames.first { $0.kind == .used }?.width ?? 0)
        let freeFrame = frames.first { $0.kind == .free }
        let freeX = magnified ? end.free.x : (freeFrame?.x ?? Double(width))
        let freeWidth = magnified ? end.free.width : (freeFrame?.width ?? 0)
        let keyboard = window.mapKeyboard || env.showsFocusWithoutKeyboard

        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
            )
            .fill(Theme.track)
            .frame(width: max(usedWidth, 0), height: thickness)

            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                if frame.kind != .used, frame.kind != .free {
                    BandSegmentView(frame: frame, radius: radius)
                        .frame(width: frame.width, height: thickness)
                        .offset(x: frame.x)
                        .opacity(magnified ? 0 : 1)
                }
            }

            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous
            )
            .strokeBorder(Theme.hair, lineWidth: 1)
            .frame(width: max(freeWidth, 0), height: thickness)
            .offset(x: freeX)

            ForEach(Array(end.slices.enumerated()), id: \.element.id) { index, slice in
                let from = doorway.collapsed.slices[index]
                let emphasis = BandMagnifier.emphasis(
                    of: slice.id, hovered: window.hoveredTile, focused: keyboard ? window.focusedTile : nil,
                    pointerOnBand: window.bandHovered
                )
                SliceView(look: slice.look, lit: emphasis.contains(.lit), ringed: emphasis.contains(.ringed))
                    .frame(width: max(magnified ? slice.width : from.width, 0), height: thickness)
                    .offset(x: magnified ? slice.x : from.x)
                    .opacity(magnified && !flying ? 1 : 0)
                    .zIndex(emphasis.contains(.ringed) ? 1 : 0)
            }

            if flying {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Theme.sliceGhost, lineWidth: 1)
                    .frame(width: end.reclaimable.width, height: thickness)
                    .offset(x: end.reclaimable.x)
            }
        }
        .frame(width: width, height: thickness, alignment: .topLeading)
        .animation(motion.animatesMagnifier ? .snappy(duration: FlightClock.hoverDuration) : nil, value: magnified)
        .accessibilityHidden(true)
    }
}

/// One slice of the magnified end: solid green when ticked, a faint green when not, a dotted amber outline when it needs a
/// look (or frees its space inside another program). Lit, it goes to 55 %; ringed, it has the focus ring of its tile.
struct SliceView: View {
    let look: BandMagnifier.Look
    var lit = false
    var ringed = false

    var body: some View {
        ZStack {
            switch look {
            case .ticked:
                Rectangle().fill(Theme.accent)
            case .unticked:
                Rectangle().fill(lit ? Theme.sliceLit : Theme.sliceOff)
            case .review:
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(lit ? Theme.reviewHoverFill : Theme.nothing)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Theme.review, style: StrokeStyle(lineWidth: 1, dash: [1, 1]))
            }
        }
        .overlay {
            if ringed {
                // 1.5 pt of ink 1.5 pt outside the slice, as the board's `outline` with an `outline-offset`
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(Theme.focusRing, lineWidth: 1.5)
                    .padding(-2.25)
            }
        }
    }
}

/// The bracket under the magnified end and the words under it.
struct BandBracket: View {
    let end: BandMagnifier
    let caption: String
    let scale: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            BracketShape()
                .stroke(Theme.bracket, lineWidth: 1)
                .frame(width: end.reclaimable.width, height: BandMagnifier.bracketHeight)
                .offset(x: end.reclaimable.x, y: BandMagnifier.bracketGap)
            Text(caption)
                .font(Typeface.ui(10.5 * scale))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .offset(x: end.reclaimable.x, y: BandMagnifier.bracketGap + BandMagnifier.bracketHeight + BandMagnifier.captionGap)
        }
        .accessibilityHidden(true)
    }
}

/// Three sides of a box, the corners at the bottom rounded by 3 pt: a bracket that opens upward.
struct BracketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let r = min(3, box.height, box.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - r))
        path.addArc(center: CGPoint(x: box.minX + r, y: box.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: box.maxX - r, y: box.maxY))
        path.addArc(center: CGPoint(x: box.maxX - r, y: box.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        return path
    }
}

/// The label over the slice under the pointer: `uv cache 2.5 GB`, name in semibold, size in secondary ink.
struct BandBubbleView: View {
    let bubble: BandBubble
    let sliceMidX: Double
    let bandWidth: Double
    @Environment(\.colorScheme) private var scheme

    /// 3 pt, a line of 11 pt type and 3 pt.
    static let height = 20.0

    var body: some View {
        BubblePlacement(sliceMidX: sliceMidX) {
            HStack(spacing: 4) {
                Text(bubble.name).font(Typeface.ui(11, .semibold)).foregroundStyle(Theme.ink)
                Text(bubble.size).font(Typeface.ui(11)).monospacedDigit().foregroundStyle(Theme.ink2)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.bubbleFill)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.40 : 0.10), radius: 5, y: 3)
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.bubbleLine, lineWidth: 0.5)
            }
        }
        .frame(width: bandWidth, height: Self.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Puts its one child over `sliceMidX`, and never past either end of the band that is its own width.
private struct BubblePlacement: Layout {
    let sliceMidX: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let child = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? child.width, height: child.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.unspecified)
        let x = BandBubble.originX(sliceMidX: sliceMidX, bubbleWidth: size.width, bandWidth: bounds.width)
        child.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
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
