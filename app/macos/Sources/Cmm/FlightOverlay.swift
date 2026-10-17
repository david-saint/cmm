import CmmKit
import SwiftUI

/// The tiles in the air between the band and the map: each flight is a shape that goes from its slice to its tile (or back),
/// turning from the slice's look into the tile's on the way.
///
/// It is drawn from the plan and the clock (`FlightSchedule.pose`), not from SwiftUI's animations, so a moment of a flight is
/// always the same and can be tested and rendered. It sits over the window in the window's own coordinates and takes no
/// clicks; the real tiles take over, to the point, when the plan's time is up.
struct FlightOverlay: View {
    let plan: FlightSchedule
    let startedAt: Date
    /// Set by the snapshot tests: the moment to draw, in seconds from the start.
    var fixedTime: Double?

    var body: some View {
        Group {
            if let fixedTime {
                FlightFrame(plan: plan, time: fixedTime)
            } else {
                TimelineView(.animation) { context in
                    FlightFrame(plan: plan, time: context.date.timeIntervalSince(startedAt))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One moment of the flights, drawn in one pass.
///
/// A flight used to be a pair of views (the slice and the tile, faded one into the other), which makes the renderer set up a
/// group for every piece that is moving: with forty tiles in the air that was most of a frame's time, and the unfold stuttered.
/// Here every piece is drawn straight into one canvas, each shape with its own alpha, and looks the same.
struct FlightFrame: View {
    let plan: FlightSchedule
    let time: Double

    var body: some View {
        Canvas { context, _ in
            for flight in plan.flights {
                var layer = context
                Self.draw(flight, pose: plan.pose(of: flight, at: time), in: &layer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func draw(_ flight: FlightSchedule.Flight, pose: FlightSchedule.Pose, in context: inout GraphicsContext) {
        let rect = CGRect(x: pose.rect.minX, y: pose.rect.minY, width: max(pose.rect.width, 0), height: max(pose.rect.height, 0))
        guard rect.width > 0, rect.height > 0 else { return }
        let weight = pose.tileWeight
        let tileRadius = TileLabels.cornerRadius(for: flight.tileRect.size)
        // a slice is nearly square-cornered, a tile has its own radius: the one grows into the other
        let radius = min(2 + (tileRadius - 2) * weight, min(rect.width, rect.height) / 2)
        if weight < 0.999 { slice(flight.look, rect, alpha: (1 - weight) * pose.opacity, in: &context) }
        if weight > 0.001 { tile(flight.tile, rect, radius: radius, alpha: weight * pose.opacity, in: &context) }
    }

    /// `SliceView`: solid green ticked, a faint green not ticked, a dotted amber outline for what needs a look.
    private static func slice(_ look: BandMagnifier.Look, _ rect: CGRect, alpha: Double, in context: inout GraphicsContext) {
        context.opacity = alpha
        switch look {
        case .ticked:
            context.fill(Path(rect), with: .style(Theme.accent))
        case .unticked:
            context.fill(Path(rect), with: .style(Theme.sliceOff))
        case .review:
            let radius = min(2, min(rect.width, rect.height) / 2)
            context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .style(Theme.nothing))
            border(rect, radius: radius, width: 1, style: StrokeStyle(lineWidth: 1, dash: [1, 1]), tone: Theme.review, in: &context)
        }
    }

    /// `TileSkin`: the tile's fill and its edge (dotted amber for a review tile).
    private static func tile(_ tile: MapTile, _ rect: CGRect, radius: Double, alpha: Double, in context: inout GraphicsContext) {
        context.opacity = alpha
        context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .style(TileSkin.fill(for: tile, hovered: false)))
        if tile.isReview {
            let inset = 0.75
            let inner = rect.insetBy(dx: inset, dy: inset)
            guard inner.width > 0, inner.height > 0 else { return }
            let path = Path(roundedRect: inner, cornerRadius: max(min(radius - inset, min(inner.width, inner.height) / 2), 0), style: .continuous)
            context.stroke(path, with: .style(Theme.review), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0, 3]))
        } else {
            border(rect, radius: radius, width: 1, style: StrokeStyle(lineWidth: 1), tone: TileSkin.edge(for: tile, hovered: false), in: &context)
        }
    }

    /// `strokeBorder`: the line sits inside the rectangle.
    private static func border(
        _ rect: CGRect, radius: Double, width: Double, style: StrokeStyle, tone: Tone, in context: inout GraphicsContext
    ) {
        let inner = rect.insetBy(dx: width / 2, dy: width / 2)
        guard inner.width > 0, inner.height > 0 else { return }
        let corner = max(min(radius - width / 2, min(inner.width, inner.height) / 2), 0)
        context.stroke(Path(roundedRect: inner, cornerRadius: corner, style: .continuous), with: .style(tone), style: style)
    }
}
