import Foundation

/// The disk band as the doorway to the map.
///
/// Hovered, and for as long as the map is open, the band's reclaimable end is drawn five times as wide as it is (the
/// used track gives the room; the free space keeps its true width), one slice per tile of the map, under a bracket
/// that says how much is enlarged and by how much. A band that is bigger than the disk's truth always says so.
///
///     used (grey) | reclaimable, enlarged: one slice per tile | free (outline)
///
/// Everything here is geometry and words; the views draw it. Slice ids are the tiles' ids, so a slice and its tile are
/// the same thing to the hover, the focus and the unfold between them.
public struct BandMagnifier: Equatable, Sendable {
    public enum Look: Equatable, Sendable {
        /// Ticked, and the disk gets the space back: solid green.
        case ticked
        /// Not ticked: a faint green.
        case unticked
        /// Needs a look, or is ticked but frees its space inside another program's storage: dotted amber, never green.
        case review
    }

    public struct Frame: Equatable, Sendable {
        public let x: Double
        public let width: Double
    }

    public struct Slice: Equatable, Sendable {
        public let id: String
        public let x: Double
        public let width: Double
        public let look: Look
    }

    /// How a slice is lit: by the pointer on its tile (or on it), and by the keyboard focus on its tile.
    public struct Emphasis: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let lit = Emphasis(rawValue: 1)
        public static let ringed = Emphasis(rawValue: 2)
    }

    /// The enlargement asked for.
    public static let targetFactor = 5.0
    /// Between the used track, the reclaimable end and the free space.
    public static let gap = 2.0
    /// Between two slices.
    public static let sliceGap = 1.0
    /// The used track never gives up more than this leaves of it.
    public static let minimumUsedWidth = 24.0
    public static let minimumSliceWidth = 2.0
    /// Below this the end is not really enlarged, and the band does not say it is.
    static let enlargedThreshold = 1.5

    /// The band is 6 pt thick, and 10 pt when hovered or magnified; the bracket sits 6 pt under it and is 5 pt high,
    /// and the caption sits 4 pt under the bracket.
    public static func thickness(magnified: Bool) -> Double { magnified ? 10 : 6 }
    public static let bracketGap = 6.0
    public static let bracketHeight = 5.0
    public static let captionGap = 4.0

    public let width: Double
    public let usedWidth: Double
    public let reclaimable: Frame
    public let free: Frame
    /// How many times wider the reclaimable end is drawn than it is: 5 when there is room, less when the end is a big
    /// part of the disk.
    public let factor: Double
    public let reclaimableBytes: Int64
    public let slices: [Slice]

    public var isEnlarged: Bool { factor >= Self.enlargedThreshold }

    /// `17.4 GB reclaimable, enlarged ×5`, or without the second half when nothing is enlarged.
    public var caption: String { caption(whileHovered: false) }

    /// The caption as the board writes it under a band that is only enlarged while the pointer is on it: `enlarged ×5 while
    /// hovered`. With the map open the band stays enlarged and says how much there is as well (`caption`).
    public func caption(whileHovered: Bool) -> String {
        let bytes = SizeText.string(reclaimableBytes)
        guard isEnlarged else { return "\(bytes) reclaimable" }
        let nearest = factor.rounded()
        let text = abs(factor - nearest) < 0.05 ? "\(Int(nearest))" : String(format: "%.1f", factor)
        return whileHovered ? "enlarged ×\(text) while hovered" : "\(bytes) reclaimable, enlarged ×\(text)"
    }

    /// Nil without a believable capacity, without tiles, or without room. `enlargement` is how many times wider than its
    /// truth the end is asked to be; 1 is the end as it is (never less), which is where the slices come from and go back to.
    public init?(
        capacity: Int64?, free freeBytes: Int64, tiles: [MapTile], width: Double, enlargement: Double = BandMagnifier.targetFactor
    ) {
        guard let capacity = DiskBand.validCapacity(capacity, free: freeBytes), width > 0, !tiles.isEmpty else { return nil }

        let bytes = tiles.reduce(Int64(0)) { $0 + max($1.bytes, 0) }
        let perByte = width / Double(capacity)
        let trueWidth = Double(bytes) * perByte
        let freeWidth = Double(max(freeBytes, 0)) * perByte
        let room = width - 2 * Self.gap - freeWidth - Self.minimumUsedWidth

        let enlarged = min(max(enlargement, 1) * trueWidth, max(room, trueWidth))
        let used = max(width - 2 * Self.gap - enlarged - freeWidth, 0)
        // when the room runs out entirely the free space gives way last, so the three still add up to the width
        let freeRoom = width - used - 2 * Self.gap - enlarged

        self.width = width
        self.usedWidth = used
        self.reclaimable = Frame(x: used + Self.gap, width: enlarged)
        self.free = Frame(x: used + Self.gap + enlarged + Self.gap, width: max(freeRoom, 0))
        self.factor = trueWidth > 0 ? enlarged / trueWidth : 1
        self.reclaimableBytes = bytes

        // One slice per tile, as wide as its bytes are of the end, with a point between slices.
        let inner = max(enlarged - Self.sliceGap * Double(tiles.count - 1), 0)
        var widths = tiles.map { bytes > 0 ? Double(max($0.bytes, 0)) / Double(bytes) * inner : inner / Double(tiles.count) }
        if inner >= Self.minimumSliceWidth * Double(tiles.count) {
            var deficit = 0.0
            for index in widths.indices where widths[index] < Self.minimumSliceWidth {
                deficit += Self.minimumSliceWidth - widths[index]
                widths[index] = Self.minimumSliceWidth
            }
            if deficit > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
                widths[widest] = max(Self.minimumSliceWidth, widths[widest] - deficit)
            }
        }
        var x = used + Self.gap
        var slices: [Slice] = []
        for (index, tile) in tiles.enumerated() {
            slices.append(Slice(id: tile.id, x: x, width: widths[index], look: Self.look(of: tile)))
            x += widths[index] + Self.sliceGap
        }
        self.slices = slices
    }

    private static func look(of tile: MapTile) -> Look {
        if tile.isReview { return tile.state == .on && !tile.freesInside ? .ticked : .review }
        return tile.state == .off ? .unticked : .ticked
    }

    // MARK: pointing

    /// The slice under a point of the band (x along the whole line). The point between two slices belongs to the one
    /// before it; the used track, the free space and the gaps around the end belong to nobody.
    public func sliceID(atX x: Double) -> String? {
        guard x >= reclaimable.x, x < reclaimable.x + reclaimable.width + Self.sliceGap / 2 else { return nil }
        return slices.last { x >= $0.x }?.id
    }

    public func slice(for id: String) -> Slice? {
        slices.first { $0.id == id }
    }

    /// How the slice of a tile is lit: the pointer on the tile (or on the slice) lights it, the keyboard focus on the tile
    /// rings it, and so does the pointer when it is on the slice itself in the band, which is what the bubble is naming.
    public static func emphasis(of id: String, hovered: String?, focused: String?, pointerOnBand: Bool = false) -> Emphasis {
        var emphasis: Emphasis = []
        if hovered == id {
            emphasis.insert(.lit)
            if pointerOnBand { emphasis.insert(.ringed) }
        }
        if focused == id { emphasis.insert(.ringed) }
        return emphasis
    }
}

/// The small label over the slice the pointer is on: the tile's name and how big it is, `uv cache 2.5 GB`.
public struct BandBubble: Equatable, Sendable {
    public let name: String
    public let size: String

    public init(tile: MapTile) {
        name = tile.fullName
        size = tile.sizeText
    }

    /// What VoiceOver would say, `uv cache, 2.5 GB`.
    public var spoken: String { "\(name), \(size)" }

    /// Where the bubble starts along the band: centred on its slice, and never past either end of the band.
    public static func originX(sliceMidX: Double, bubbleWidth: Double, bandWidth: Double) -> Double {
        max(0, min(sliceMidX - bubbleWidth / 2, bandWidth - bubbleWidth))
    }
}
