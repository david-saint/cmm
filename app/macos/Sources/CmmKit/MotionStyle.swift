import Foundation

/// How the window moves: with a spring, or, when the person has asked the system for less motion, with a crossfade.
/// The pane then fades in place instead of sliding in, and the confirmation card fades instead of growing from the
/// button. The views turn this into animations; the decision lives here so it is tested.
public enum MotionStyle: Equatable, Sendable {
    case spring
    case crossfade

    public static func resolve(reduceMotion: Bool) -> MotionStyle {
        reduceMotion ? .crossfade : .spring
    }

    public var slidesPane: Bool { self == .spring }
    public var growsCard: Bool { self == .spring }
    /// The band's slices fly into the map's tiles (and back) only with motion; without it the pane fades in place.
    public var flies: Bool { self == .spring }
    /// The band's end is enlarged with a short spring when the pointer comes to it; without motion it is simply enlarged.
    public var animatesMagnifier: Bool { self == .spring }

    /// Seconds.
    public var duration: Double {
        switch self {
        case .spring: 0.45
        case .crossfade: 0.2
        }
    }
}
