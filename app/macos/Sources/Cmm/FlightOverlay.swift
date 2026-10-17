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

/// One moment of the flights.
struct FlightFrame: View {
    let plan: FlightSchedule
    let time: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(plan.flights) { flight in
                piece(flight, pose: plan.pose(of: flight, at: time))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func piece(_ flight: FlightSchedule.Flight, pose: FlightSchedule.Pose) -> some View {
        let width = max(Double(pose.rect.width), 0)
        let height = max(Double(pose.rect.height), 0)
        let tileRadius = TileLabels.cornerRadius(for: flight.tileRect.size)
        // a slice is nearly square-cornered, a tile has its own radius: the one grows into the other
        let radius = min(2 + (tileRadius - 2) * pose.tileWeight, min(width, height) / 2)
        return ZStack {
            SliceView(look: flight.look)
                .opacity(1 - pose.tileWeight)
            TileSkin(tile: flight.tile, hovered: false, radius: radius)
                .opacity(pose.tileWeight)
        }
        .frame(width: width, height: height)
        .offset(x: pose.rect.minX, y: pose.rect.minY)
        .opacity(pose.opacity)
    }
}
