import CoreGraphics
import Foundation

/// Where the confirmation card goes: 12 pt left of and 55 pt above the Clean pill (the sheet board's card is at
/// (100, 452), its pill at (112, 507)), so it reads as growing out of the button, kept 16 pt inside the window. `anchor` is the point of the card, in unit coordinates, that the pill's centre
/// falls on: the card scales up from there.
public struct CardPlacement: Equatable, Sendable {
    /// The card's width and height in the boards (22 + 22 + 6 + 20 + 2 + 20 + 20 + 44 + 20).
    public static let width = 492.0
    public static let height = 176.0
    private static let margin = 16.0

    public let origin: CGPoint
    public let anchor: CGPoint

    public init(pill: CGRect, card: CGSize, window: CGSize) {
        guard pill.width > 0, pill.height > 0 else {
            origin = CGPoint(x: (window.width - card.width) / 2, y: (window.height - card.height) / 2)
            anchor = CGPoint(x: 0.5, y: 0.5)
            return
        }
        let x = min(max(pill.minX - 12, Self.margin), max(Self.margin, window.width - card.width - Self.margin))
        let y = min(max(pill.minY - 55, Self.margin), max(Self.margin, window.height - card.height - Self.margin))
        origin = CGPoint(x: x, y: y)
        anchor = CGPoint(
            x: min(max((pill.midX - x) / card.width, 0), 1),
            y: min(max((pill.midY - y) / card.height, 0), 1)
        )
    }
}
