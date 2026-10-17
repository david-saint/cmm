import CoreGraphics
import Foundation

/// The squarified treemap (Bruls, Huizing and van Wijk) behind the reclaimable-space map: rectangles whose areas are
/// proportional to weights, laid out so they stay as close to square as the data allows. Deterministic: the same
/// weights in the same order in the same container always give the same rectangles.
public enum Treemap {
    /// Rectangles for `weights`, in the same order, filling `rect` exactly. The caller sorts the weights from largest to
    /// smallest (the algorithm needs it for its squarish rows, and the order is what the map's keyboard order follows).
    /// Weights that are not above zero are treated as equal shares when nothing has any weight, and as nothing otherwise.
    public static func squarify(weights: [Double], in rect: CGRect) -> [CGRect] {
        let count = weights.count
        guard count > 0 else { return [] }
        guard rect.width > 0, rect.height > 0 else {
            return Array(repeating: CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 0), height: max(rect.height, 0)), count: count)
        }

        var shares = weights.map { max($0, 0) }
        if shares.reduce(0, +) <= 0 { shares = Array(repeating: 1, count: count) }
        let total = shares.reduce(0, +)
        let areas = shares.map { $0 / total * Double(rect.width * rect.height) }

        var frames = [CGRect](repeating: .zero, count: count)
        var remaining = rect
        var start = 0
        while start < count {
            let side = Double(min(remaining.width, remaining.height))
            // Grow the row while adding the next area does not make its worst aspect ratio worse.
            var end = start + 1
            var worst = Self.worstRatio(areas[start..<end], side: side)
            while end < count {
                let next = Self.worstRatio(areas[start...end], side: side)
                guard next <= worst else { break }
                worst = next
                end += 1
            }

            let rowArea = areas[start..<end].reduce(0, +)
            let isLast = end == count
            if remaining.width >= remaining.height {
                // a column down the left side, as wide as its area needs
                let thickness = isLast ? Double(remaining.width) : min(rowArea / side, Double(remaining.width))
                var y = Double(remaining.minY)
                for index in start..<end {
                    let isLastInRow = index == end - 1
                    let height = isLastInRow ? Double(remaining.maxY) - y : areas[index] / max(thickness, 1e-12)
                    frames[index] = CGRect(x: Double(remaining.minX), y: y, width: thickness, height: max(height, 0))
                    y += height
                }
                remaining = CGRect(
                    x: Double(remaining.minX) + thickness, y: Double(remaining.minY),
                    width: max(Double(remaining.width) - thickness, 0), height: Double(remaining.height)
                )
            } else {
                // a row along the top, as tall as its area needs
                let thickness = isLast ? Double(remaining.height) : min(rowArea / side, Double(remaining.height))
                var x = Double(remaining.minX)
                for index in start..<end {
                    let isLastInRow = index == end - 1
                    let width = isLastInRow ? Double(remaining.maxX) - x : areas[index] / max(thickness, 1e-12)
                    frames[index] = CGRect(x: x, y: Double(remaining.minY), width: max(width, 0), height: thickness)
                    x += width
                }
                remaining = CGRect(
                    x: Double(remaining.minX), y: Double(remaining.minY) + thickness,
                    width: Double(remaining.width), height: max(Double(remaining.height) - thickness, 0)
                )
            }
            start = end
        }
        return frames
    }

    /// The worst aspect ratio (always at least 1) among a row's rectangles, were the row laid along `side`.
    private static func worstRatio(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0 else { return .infinity }
        let thickness = sum / side
        var worst = 1.0
        for area in row where area > 0 {
            let length = area / thickness
            worst = max(worst, max(length / thickness, thickness / length))
        }
        return worst
    }
}

/// Where the map's tiles go: groups side by side in a squarified layout, items squarified inside their group, with the
/// board's gaps (6 pt between groups, 3 pt between items of a group, half a gap to the container's edge) and no frames
/// or headers. Only the sizes of things matter here, so it works on ids and bytes.
///
/// Tiles are in proportion to bytes, except that no tile is allowed to be too small to point at: an item whose tile
/// would be thinner than `minimumSide` (a few kilobytes beside tens of gigabytes) is given a larger share, and the
/// large tiles give up that much, so every item can be reached.
public struct MapLayout: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let bytes: Int64

        public init(id: String, bytes: Int64) {
            self.id = id
            self.bytes = bytes
        }
    }

    public struct Group: Equatable, Sendable {
        public let id: String
        public let entries: [Entry]

        public init(id: String, entries: [Entry]) {
            self.id = id
            self.entries = entries
        }
    }

    public static let groupGap = 6.0
    public static let itemGap = 3.0
    /// The smallest width and height a tile may have, so a tiny item can still be hovered, clicked and reached.
    public static let minimumSide = 16.0
    /// The share of the area an item gets at the very least (before the reachability pass), or what a crowd leaves.
    static let minimumShare = 0.002
    /// Past this many tiles the reachability pass is skipped (nothing could make a thousand tiles reachable).
    static let reachabilityLimit = 300

    public let size: CGSize
    /// Each tile's frame, by entry id.
    public let frames: [String: CGRect]
    /// The entry ids in layout order: the largest group first, and inside a group the largest item first. The map's
    /// keyboard order (Home and End) follows it.
    public let order: [String]

    public init(groups: [Group], size: CGSize) {
        self.size = size
        let entries = groups.flatMap(\.entries)
        guard !entries.isEmpty else {
            frames = [:]
            order = []
            return
        }

        // Weights: bytes, with a floor so nothing vanishes; zero bytes everywhere means equal shares.
        let totalBytes = entries.reduce(0.0) { $0 + Double(max($1.bytes, 0)) }
        var weights: [String: Double] = [:]
        if totalBytes > 0 {
            let floor = min(Self.minimumShare, 0.5 / Double(entries.count)) * totalBytes
            for entry in entries { weights[entry.id] = max(Double(max(entry.bytes, 0)), floor) }
        } else {
            for entry in entries { weights[entry.id] = 1 }
        }

        var best = Self.arrange(groups: groups, weights: weights, size: size)
        if entries.count <= Self.reachabilityLimit {
            // Give a too-small tile a bigger share, a few times, until every tile can be pointed at.
            for _ in 0..<12 {
                var changed = false
                for (id, frame) in best.frames {
                    let side = min(frame.width, frame.height)
                    guard side < Self.minimumSide - 0.01, let weight = weights[id] else { continue }
                    // a thin strip grows in proportion to its weight, a square with its square root: take the stronger step
                    weights[id] = weight * min(max((Self.minimumSide + 1) / max(side, 0.25), 1.15), 40)
                    changed = true
                }
                guard changed else { break }
                best = Self.arrange(groups: groups, weights: weights, size: size)
            }
        }
        frames = best.frames
        order = best.order
    }

    private static func arrange(groups: [Group], weights: [String: Double], size: CGSize) -> (frames: [String: CGRect], order: [String]) {
        struct Sorted {
            let group: Group
            let entries: [Entry]
            let weight: Double
        }
        let sorted = groups.filter { !$0.entries.isEmpty }.map { group -> Sorted in
            let entries = group.entries.enumerated()
                .sorted { (weights[$0.element.id] ?? 0, $1.offset) > (weights[$1.element.id] ?? 0, $0.offset) }
                .map(\.element)
            return Sorted(group: group, entries: entries, weight: entries.reduce(0) { $0 + (weights[$1.id] ?? 0) })
        }
        .enumerated()
        .sorted { ($0.element.weight, $1.offset) > ($1.element.weight, $0.offset) }
        .map(\.element)

        let container = CGRect(x: 0, y: 0, width: max(size.width, 0), height: max(size.height, 0))
        let groupFrames = Treemap.squarify(weights: sorted.map(\.weight), in: container)

        var frames: [String: CGRect] = [:]
        var order: [String] = []
        for (index, entry) in sorted.enumerated() {
            // The group's own area, then the room its items share: half a group gap off every side, and half an item
            // gap given back so the items' own insets leave exactly the item gap between them.
            let content = inset(groupFrames[index], by: groupGap / 2)
            let items = Treemap.squarify(weights: entry.entries.map { weights[$0.id] ?? 0 }, in: inset(content, by: -itemGap / 2))
            for (itemIndex, item) in entry.entries.enumerated() {
                frames[item.id] = inset(items[itemIndex], by: itemGap / 2)
                order.append(item.id)
            }
        }
        return (frames, order)
    }

    private static func inset(_ rect: CGRect, by amount: Double) -> CGRect {
        let width = max(Double(rect.width) - 2 * amount, 0)
        let height = max(Double(rect.height) - 2 * amount, 0)
        // a rectangle squeezed to nothing collapses onto its middle instead of inverting
        let x = width == 0 ? Double(rect.midX) : Double(rect.minX) + amount
        let y = height == 0 ? Double(rect.midY) : Double(rect.minY) + amount
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
