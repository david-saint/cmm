import CoreGraphics
import Foundation

/// The one-time card on the home screen (the board `C-Optin`): what it says, when it is there and where it goes. It asks once,
/// ever; either answer puts it away for good (`SettingsModel.optInAnswered`).
public enum OptInCopy {
    public static let title = "Keep an eye on your disk?"
    public static let line = "Free space in the menu bar and a reminder on Mondays."
    /// The small print: with the line above, it names all four things Turn on switches on.
    public static let smallPrint =
        "Turn on also opens cmm at login and keeps a free-space history: one number every 30 minutes, nothing else. Each has its own switch in Settings."
    public static let turnOn = "Turn on"
    public static let notNow = "Not now"
}

/// Where the card goes: beside the headline, its right edge on the band's right end and its bottom on the pill's, as on the board,
/// and at the headline's own scale, so that wherever the board's headline fits beside it (four digits and the unit included), it
/// fits in every window size. It lies over the screen and moves nothing on it.
public struct OptInPlacement: Equatable, Sendable {
    /// The card's width on the board (1100 x 720), and how far below the top of the headline block the pill's bottom is there.
    public static let boardWidth = 320.0
    static let boardPillBottomBelowTop = 379.0

    /// The headline's scale, which the card's sizes follow.
    public let scale: Double
    public let width: Double
    /// The card's right edge and its bottom, from the window's top left corner.
    public let right: Double
    public let bottom: Double

    /// - Parameter pillFrame: where the rest screen's Clean pill is, in the window; nil (or empty) on the screen that has none.
    public init(windowWidth: Double, windowHeight: Double, pillFrame: CGRect?) {
        let layout = HeroLayout(screen: .rest, width: windowWidth, height: windowHeight)
        scale = layout.scale
        width = Self.boardWidth * layout.scale
        right = windowWidth - layout.leading
        if let pill = pillFrame, pill.height > 0 {
            bottom = pill.maxY
        } else {
            bottom = layout.top + Self.boardPillBottomBelowTop * layout.scale
        }
    }

    /// The card's frame for a card of this height.
    public func frame(height: Double) -> CGRect {
        CGRect(x: right - width, y: bottom - height, width: width, height: height)
    }

    /// The card is there only until it is answered, and only at rest: on the ready and nothing-to-clean screens, never during a
    /// scan, a cleaning or its result, never with the confirmation card up, and not while the Details pane covers its place.
    public static func isShown(optInAnswered: Bool, phase: AppModel.Phase, confirmationOpen: Bool, detailsOpen: Bool) -> Bool {
        guard !optInAnswered, !confirmationOpen else { return false }
        switch phase {
        case .ready: return !detailsOpen
        case .empty: return !detailsOpen
        case .idle, .scanning, .cleaning, .done, .failed: return false
        }
    }
}
