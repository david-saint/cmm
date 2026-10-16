import CoreGraphics
import Foundation

/// One tile of the reclaimable-space map.
///
/// A tile is a tickable item of the plan (safe and review tiers only; nothing else ever has a tile), except that the
/// items of one group made only of commands (Docker's three prunes) are a single tile that ticks and unticks all of them.
/// The list's expanded rows stay the place to tick them one by one.
public struct MapTile: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case item(PlanItem)
        /// A group of commands, ticked together.
        case group(PlanGroup)
    }

    public let id: String
    public let target: Target
    /// `lane-a`, `uv cache`, `Docker`.
    public let title: String
    /// `node_modules`, `~/.cache/uv`; nil for a command or a group of them.
    public let subtitle: String?
    /// What tells this tile from the others of its group: `lane-a node_modules`. For a tile of a group of one it is
    /// just the title (the path under it is a detail).
    public let fullName: String
    public let bytes: Int64
    public let sizeText: String
    public let section: PlanSection
    public let state: TriState
    /// How many items are ticked in the tile (one or none, except for a group tile).
    public let tickedCount: Int
    public let itemCount: Int
    /// The caption's second line.
    public let note: String
    /// Whether its items free their space inside another program's storage, so ticking them adds nothing to what the disk
    /// gets back.
    public let freesInside: Bool
    public let rect: CGRect

    public var isReview: Bool { section == .review }
    public var isGroup: Bool { if case .group = target { true } else { false } }

    // MARK: words

    /// `Review · not ticked`, `Safe · ticked`, `Review · 1 of 3 ticked`.
    public var status: String {
        let tier = isReview ? "Review" : "Safe"
        switch state {
        case .on: return "\(tier) · ticked"
        case .off: return "\(tier) · not ticked"
        case .mixed: return "\(tier) · \(tickedCount) of \(itemCount) ticked"
        }
    }

    public var caption: MapCaption {
        MapCaption(title: fullName, sizeText: sizeText, status: status, isReview: isReview, note: note)
    }

    public var accessibilityLabel: String { fullName }

    /// `1.4 GB, safe to remove, ticked`
    public var accessibilityValue: String {
        let tick: String
        switch state {
        case .on: tick = "ticked"
        case .off: tick = "not ticked"
        case .mixed: tick = "partly ticked"
        }
        return "\(sizeText), \(isReview ? "review" : "safe to remove"), \(tick)"
    }

    /// `lane-a node_modules, 1.4 GB, safe to remove, ticked`
    public var spoken: String { "\(accessibilityLabel), \(accessibilityValue)" }

    public var accessibilityHint: String {
        isGroup ? "Ticks or unticks all \(itemCount) cleanups" : "Ticks or unticks this item"
    }
}

/// The two lines under the map: who, how big, in what state, and one line about it.
public struct MapCaption: Equatable, Sendable {
    public let title: String
    public let sizeText: String
    /// `Review · not ticked`
    public let status: String
    public let isReview: Bool
    /// `3 cleanups, inside Docker's disk image, volumes are never offered`
    public let note: String
}

/// Whose caption the map shows: the tile with the keyboard focus, and only when nothing has it, the tile under the pointer.
public enum MapCaptionRule {
    public static func subject(focused: String?, hovered: String?, in model: MapModel) -> MapTile? {
        if let focused, let tile = model.tile(id: focused) { return tile }
        if let hovered, let tile = model.tile(id: hovered) { return tile }
        return nil
    }
}

/// What a tile shows by its size, in points: the name and the size from 96 x 56, the size alone from 44 x 28, the badge
/// alone from 28 x 28, and below that only the fill. Such a tile is still reached by hover, the arrow keys, Space and
/// VoiceOver, which is why the badge and the words are never the only way to it.
public enum TileLabels {
    public enum Level: Int, Comparable, Sendable {
        case fillOnly
        case badgeOnly
        case sizeOnly
        case nameAndSize

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var showsBadge: Bool { self >= .badgeOnly }
        public var showsSize: Bool { self >= .sizeOnly }
        public var showsName: Bool { self >= .nameAndSize }
    }

    public static func level(for size: CGSize) -> Level {
        let (w, h) = (Double(size.width), Double(size.height))
        if w >= 96, h >= 56 { return .nameAndSize }
        if w >= 44, h >= 28 { return .sizeOnly }
        if w >= 28, h >= 28 { return .badgeOnly }
        return .fillOnly
    }

    /// 8 pt, or 5 pt when a side is under 30 pt.
    public static func cornerRadius(for size: CGSize) -> Double {
        min(size.width, size.height) < 30 ? 5 : 8
    }

    /// The badge is 16 pt and sits 8 pt from the top left; in a tile too narrow (under the size's 44) or too low (under the
    /// name's 56) for that margin it is centred across, as on the board.
    public static func badgeOrigin(for size: CGSize) -> CGPoint {
        let x = size.width < 44 ? ((Double(size.width) - 16) / 2).rounded(.down) : 8
        let y = size.height < 56 ? ((Double(size.height) - 16) / 2).rounded(.down) : 8
        return CGPoint(x: x, y: y)
    }

    /// How big the size is set: 30 pt in a tile like the board's Docker, 22 pt in one like uv's, 13 pt in the rest.
    public enum SizeStyle: Sendable {
        case hero
        case large
        case regular
    }

    public static func sizeStyle(for size: CGSize) -> SizeStyle {
        let (w, h) = (Double(size.width), Double(size.height))
        if w >= 320, h >= 160 { return .hero }
        if w >= 200, h >= 100 { return .large }
        return .regular
    }
}

/// The map: a tile for every tickable item (the prunes of a group of commands as one), laid out as a squarified treemap
/// in the container's size. The layout depends on bytes alone, so ticking never moves a tile.
public struct MapModel: Equatable, Sendable {
    public let size: CGSize
    /// In layout order: the largest group first, and inside a group the largest item first.
    public let tiles: [MapTile]

    private let index: [String: Int]

    public init(selection: SelectionModel, size: CGSize, home: String) {
        self.size = size

        struct Pending {
            let id: String
            let target: MapTile.Target
            let title: String
            let subtitle: String?
            let fullName: String
            let bytes: Int64
            let section: PlanSection
            let state: TriState
            let tickedCount: Int
            let itemCount: Int
            let note: String
            let freesInside: Bool
        }

        var pending: [String: Pending] = [:]
        var groups: [MapLayout.Group] = []

        for group in selection.groups where group.section == .safe || group.section == .review {
            var entries: [MapLayout.Entry] = []
            let title = RuleCatalog.mapTitle(rule: group.rule, label: group.name)

            if group.items.count >= 2, group.items.allSatisfy({ $0.action == .command }) {
                let id = "group:\(group.id)"
                let ticked = group.items.filter { selection.isTicked($0) }.count
                pending[id] = Pending(
                    id: id, target: .group(group), title: title, subtitle: nil, fullName: title, bytes: group.bytes,
                    section: group.section, state: selection.state(of: group), tickedCount: ticked, itemCount: group.count,
                    note: Self.groupNote(group), freesInside: group.items.allSatisfy { $0.freesInside != nil }
                )
                entries.append(MapLayout.Entry(id: id, bytes: group.bytes))
            } else {
                let names = group.items.count == 1 ? nil : Self.itemNames(in: group, home: home)
                for (offset, item) in group.items.enumerated() {
                    let id = "item:\(item.path)"
                    let isTicked = selection.isTicked(item)
                    let name = names?[offset]
                    let itemTitle: String
                    let subtitle: String?
                    let fullName: String
                    if let name {
                        itemTitle = name.title
                        subtitle = name.subtitle
                        fullName = name.subtitle.map { "\(name.title) \($0)" } ?? name.title
                    } else {
                        itemTitle = title
                        subtitle = item.action == .command ? nil : PathFormat.shorten(item.path, home: home)
                        fullName = title
                    }
                    pending[id] = Pending(
                        id: id, target: .item(item), title: itemTitle, subtitle: subtitle, fullName: fullName, bytes: item.bytes,
                        section: group.section, state: isTicked ? .on : .off, tickedCount: isTicked ? 1 : 0, itemCount: 1,
                        note: Self.itemNote(item, home: home), freesInside: item.freesInside != nil
                    )
                    entries.append(MapLayout.Entry(id: id, bytes: item.bytes))
                }
            }
            groups.append(MapLayout.Group(id: group.id, entries: entries))
        }

        let layout = MapLayout(groups: groups, size: size)
        var tiles: [MapTile] = []
        for id in layout.order {
            guard let p = pending[id], let rect = layout.frames[id] else { continue }
            tiles.append(MapTile(
                id: p.id, target: p.target, title: p.title, subtitle: p.subtitle, fullName: p.fullName, bytes: p.bytes,
                sizeText: SizeText.string(p.bytes), section: p.section, state: p.state, tickedCount: p.tickedCount,
                itemCount: p.itemCount, note: p.note, freesInside: p.freesInside, rect: rect
            ))
        }
        self.tiles = tiles
        self.index = Dictionary(uniqueKeysWithValues: tiles.enumerated().map { ($1.id, $0) })
    }

    public func tile(id: String) -> MapTile? {
        index[id].map { tiles[$0] }
    }

    /// The tile under a point of the map, or nil in a gap.
    public func tile(at point: CGPoint) -> MapTile? {
        tiles.first { $0.rect.contains(point) }
    }

    /// What "Review N GB more" opens the map on: the biggest tile that needs a look.
    public var reviewTileID: String? {
        tiles.filter(\.isReview).max { $0.bytes < $1.bytes }?.id
    }

    /// Everything on the map: what is reclaimable if every tile were ticked.
    public var totalBytes: Int64 { tiles.reduce(0) { $0 + $1.bytes } }

    // MARK: names and notes

    /// `3 cleanups, inside Docker's disk image, volumes are never offered`
    private static func groupNote(_ group: PlanGroup) -> String {
        var parts = [group.count == 1 ? "1 cleanup" : "\(group.count) cleanups"]
        var places: [String] = []
        for item in group.items {
            if let place = item.freesInside, !places.contains(place) { places.append(place) }
        }
        if !places.isEmpty { parts.append("inside \(HeldBack.join(places))") }
        if let clause = RuleCatalog.entries[group.rule]?.mapClause { parts.append(clause) }
        return parts.joined(separator: ", ")
    }

    /// The engine's note, or the path of a file, or what a command runs.
    private static func itemNote(_ item: PlanItem, home: String) -> String {
        if let note = item.note, !note.isEmpty { return note }
        if item.action == .command { return RuleCatalog.entries[item.rule]?.command ?? item.path }
        return PathFormat.shorten(item.path, home: home)
    }

    /// For the items of a group of files: the first folder their paths do not share and what follows it, so `lane-a` and
    /// `node_modules` instead of two long, nearly equal paths. With nothing in common, the last folder and where it is.
    private static func itemNames(in group: PlanGroup, home: String) -> [(title: String, subtitle: String?)] {
        let parts = group.items.map { $0.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
        // the folders every path has in common, never taking a path's own last component
        var shared = 0
        if let first = parts.first {
            let limit = parts.map { $0.count - 1 }.min() ?? 0
            while shared < limit, parts.allSatisfy({ $0[shared] == first[shared] }) { shared += 1 }
        }
        return zip(group.items, parts).map { item, components in
            if item.action == .command { return (item.path, nil) }
            if shared > 0, components.count > shared {
                let rest = components[(shared + 1)...]
                return (components[shared], rest.isEmpty ? nil : rest.joined(separator: "/"))
            }
            let last = components.last ?? item.path
            let parent = "/" + components.dropLast().joined(separator: "/")
            return (last, components.count > 1 ? PathFormat.shorten(parent, home: home) : nil)
        }
    }
}
