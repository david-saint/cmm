import CoreGraphics
import Foundation

/// The time of the band's flights into the map and back: a spring for the way out (.spring(duration: 0.5, bounce: 0.15)),
/// an ease for the way back (0.35 s), 20 ms between one tile leaving and the next, and the band's own 0.22 s.
///
/// The views draw the flights from this clock instead of from SwiftUI's animations, so the same moment can be drawn twice
/// and be the same, and so a flight can be tested, and rendered at any instant for the review.
public enum FlightClock {
    public static let unfoldDuration = 0.5
    public static let unfoldBounce = 0.15
    /// Between one tile leaving the band and the next, largest first.
    public static let stagger = 0.02
    public static let foldDuration = 0.35
    /// The band's end enlarging when the pointer comes to it.
    public static let hoverDuration = 0.22
    /// When a flight is exactly on its tile. A spring's tail never quite ends, and a tile that takes over from a shape that
    /// is a fraction of a point away would jump by it; so the tail, which is a few tenths of a percent, is eased out over the
    /// tenth of a second after the spring's own duration.
    public static let settle = 0.6
    /// What is added to the last flight's end before the tiles take over.
    public static let landingMargin = 0.02

    /// The step response of a damped spring that takes `duration` seconds to settle and has this much `bounce`: 0 before it
    /// is let go, 1 when it has settled. The same curve SwiftUI's `Spring(duration:bounce:)` follows.
    public static func spring(at time: Double, duration: Double = unfoldDuration, bounce: Double = unfoldBounce) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / duration
        let damping = 1 - bounce
        if damping >= 1 {
            return 1 - (1 + omega * time) * exp(-omega * time)
        }
        let damped = omega * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * omega * time) * (cos(damped * time) + damping * omega / damped * sin(damped * time))
    }

    /// How far along a tile is, `time` seconds after it was let go: the spring, with its tail eased onto the target.
    public static func flight(at time: Double) -> Double {
        guard time > 0 else { return 0 }
        guard time < settle else { return 1 }
        let window = 1 - smoothstep(unfoldDuration, settle, time)
        return 1 + (spring(at: time) - 1) * window
    }

    /// The way back: a plain ease in and out.
    public static func ease(at time: Double, duration: Double = foldDuration) -> Double {
        smoothstep(0, duration, time)
    }

    /// 0 up to `edge0`, 1 from `edge1`, and an S in between.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The flights between the band's slices and the map's tiles, in window coordinates: for each tile where it is, where its
/// slice is, and when it leaves.
///
/// Unfolding, the slices lift off the band and grow into the tiles, the largest first (20 ms apart), while the pane slides
/// in. Folding, all the tiles go back to the band together over 0.35 s and are gone when they arrive. Nothing here draws.
public struct UnfoldPlan: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case unfold
        case fold
    }

    public struct Flight: Equatable, Sendable, Identifiable {
        public let tile: MapTile
        /// How its slice looks.
        public let look: BandMagnifier.Look
        /// The tile, where it is on the open map.
        public let tileRect: CGRect
        /// Its slice on the band: where it leaves from (unfolding) or comes to (folding).
        public let bandRect: CGRect
        /// Seconds after the start that it leaves.
        public let delay: Double

        public var id: String { tile.id }
    }

    /// One flight at one moment.
    public struct Pose: Equatable, Sendable {
        public let rect: CGRect
        /// 0 is the slice's own look, 1 the tile's: one turns into the other on the way.
        public let tileWeight: Double
        public let opacity: Double
    }

    public let direction: Direction
    /// Largest first; equal sizes in the map's order.
    public let flights: [Flight]
    /// Seconds until the last one has landed and the tiles take over (or, folding, until the last one is gone).
    public let duration: Double

    /// - Parameters:
    ///   - band: the layout the band is in on the side of the flight where it is not the map: the window the slices leave
    ///     from, or, folding, the closed window they go back to.
    ///   - enlarged: whether the band's end is already enlarged where the slices leave from (the pointer is on the band).
    ///     Otherwise they leave from the end as it is. They always go back to the end as it is.
    ///   - windowWidth: the pane hugs the window's right edge, so the map's place depends on it.
    public init?(
        direction: Direction, map: MapModel, capacity: Int64?, free: Int64, band: HeroLayout, enlarged: Bool, windowWidth: Double
    ) {
        let enlarging = direction == .unfold && enlarged
        guard let magnifier = BandMagnifier(
            capacity: capacity, free: free, tiles: map.tiles, width: band.bandWidth,
            enlargement: enlarging ? BandMagnifier.targetFactor : 1
        ) else { return nil }

        let thickness = BandMagnifier.thickness(magnified: enlarging)
        let origin = HeroLayout.mapOrigin(windowWidth: windowWidth)
        let ranked = map.tiles.enumerated().sorted {
            $0.element.bytes != $1.element.bytes ? $0.element.bytes > $1.element.bytes : $0.offset < $1.offset
        }

        var flights: [Flight] = []
        for (rank, entry) in ranked.enumerated() {
            let tile = entry.element
            guard let slice = magnifier.slice(for: tile.id) else { continue }
            flights.append(Flight(
                tile: tile, look: slice.look,
                tileRect: tile.rect.offsetBy(dx: origin.x, dy: origin.y),
                bandRect: CGRect(x: band.bandLeading + slice.x, y: band.bandLineTop, width: slice.width, height: thickness),
                delay: direction == .unfold ? Double(rank) * FlightClock.stagger : 0
            ))
        }
        guard !flights.isEmpty else { return nil }

        self.direction = direction
        self.flights = flights
        switch direction {
        case .unfold: duration = (flights.last?.delay ?? 0) + FlightClock.settle + FlightClock.landingMargin
        case .fold: duration = FlightClock.foldDuration + FlightClock.landingMargin
        }
    }

    public func pose(of flight: Flight, at time: Double) -> Pose {
        switch direction {
        case .unfold:
            let progress = FlightClock.flight(at: time - flight.delay)
            return Pose(
                rect: Self.blend(flight.bandRect, flight.tileRect, progress),
                tileWeight: FlightClock.smoothstep(0, 0.55, progress),
                opacity: 1
            )
        case .fold:
            let progress = FlightClock.ease(at: time)
            return Pose(
                rect: Self.blend(flight.tileRect, flight.bandRect, progress),
                tileWeight: 1 - FlightClock.smoothstep(0.2, 0.8, progress),
                opacity: 1 - FlightClock.smoothstep(0.8, 1, progress)
            )
        }
    }

    private static func blend(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        return CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
    }
}
