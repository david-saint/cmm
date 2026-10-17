import CoreGraphics
import Foundation

/// What a key does on the map. The map is one tab stop, like the list; inside it the arrows move the focus to the
/// neighbouring tile in the direction pressed, Space and Return tick the focused tile, Home and End jump to the first and
/// last in layout order. Pure, so it is tested on the board's layout without a window; the view applies the action.
public enum MapNavigation {
    public enum Key: Equatable, Sendable {
        case up
        case down
        case left
        case right
        case space
        case `return`
        case home
        case end
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Move the focus to this tile id.
        case focus(String)
        /// Tick or untick the tile with this id.
        case toggle(String)
    }

    /// The focus, or nil when that tile is no longer on the map (the plan changed).
    public static func validFocus(_ focused: String?, in model: MapModel) -> String? {
        guard let focused, model.tile(id: focused) != nil else { return nil }
        return focused
    }

    public static func handle(_ key: Key, focused: String?, in model: MapModel) -> Action {
        guard let first = model.tiles.first, let last = model.tiles.last else { return .none }
        let current = validFocus(focused, in: model)

        switch key {
        case .home:
            return .focus(first.id)
        case .end:
            return .focus(last.id)
        case .space, .return:
            return current.map { .toggle($0) } ?? .none
        case .up, .down, .left, .right:
            guard let current, let from = model.tile(id: current) else { return .focus(first.id) }
            return neighbour(of: from, toward: key, in: model.tiles).map { .focus($0.id) } ?? .none
        }
    }

    /// The tile next to `tile` in a direction: among those wholly beyond its edge, the ones that face it (overlap it
    /// across the direction) come first, then the nearest, and, between equally near ones, the one whose middle is
    /// closest to its middle. A tile that nothing faces falls back to the nearest that is merely beyond the edge.
    static func neighbour(of tile: MapTile, toward key: Key, in tiles: [MapTile]) -> MapTile? {
        let from = tile.rect
        let epsilon = 0.5

        func measure(_ rect: CGRect) -> (distance: Double, faces: Bool, offset: Double)? {
            switch key {
            case .right:
                guard rect.minX >= from.maxX - epsilon else { return nil }
                return (Double(rect.minX - from.maxX), overlap(from.minY, from.maxY, rect.minY, rect.maxY), abs(Double(rect.midY - from.midY)))
            case .left:
                guard rect.maxX <= from.minX + epsilon else { return nil }
                return (Double(from.minX - rect.maxX), overlap(from.minY, from.maxY, rect.minY, rect.maxY), abs(Double(rect.midY - from.midY)))
            case .down:
                guard rect.minY >= from.maxY - epsilon else { return nil }
                return (Double(rect.minY - from.maxY), overlap(from.minX, from.maxX, rect.minX, rect.maxX), abs(Double(rect.midX - from.midX)))
            case .up:
                guard rect.maxY <= from.minY + epsilon else { return nil }
                return (Double(from.minY - rect.maxY), overlap(from.minX, from.maxX, rect.minX, rect.maxX), abs(Double(rect.midX - from.midX)))
            default:
                return nil
            }
        }

        var best: (tile: MapTile, distance: Double, faces: Bool, offset: Double)?
        for candidate in tiles where candidate.id != tile.id {
            guard let m = measure(candidate.rect) else { continue }
            guard let current = best else {
                best = (candidate, m.distance, m.faces, m.offset)
                continue
            }
            let better: Bool
            if m.faces != current.faces {
                better = m.faces
            } else if abs(m.distance - current.distance) > epsilon {
                better = m.distance < current.distance
            } else {
                better = m.offset < current.offset
            }
            if better { best = (candidate, m.distance, m.faces, m.offset) }
        }
        return best?.tile
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool {
        min(a1, b1) - max(a0, b0) > 0
    }
}
