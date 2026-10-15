import Foundation

/// The state of a group's checkbox.
public enum TriState: Hashable, Sendable {
    case off
    case on
    /// Some of the group's items are ticked and some are not.
    case mixed
}

/// Where an item is offered. Safe items are ticked for you, review items are listed apart and ticked only by you,
/// and everything else (the reserved `manual` tier and any tier this app does not know) is shown but can never be
/// ticked, so it can never be handed to cmm.
public enum PlanSection: String, Hashable, Sendable, CaseIterable {
    case safe
    case review
    case other

    init(tier: Tier) {
        switch tier {
        case .safe: self = .safe
        case .review: self = .review
        case .manual, .other: self = .other
        }
    }

    /// Whether a person may tick items of this section.
    var isTickable: Bool { self != .other }
}

/// The items of one `group` label in one section, largest first. A group label that holds items of two tiers (a safe
/// one and a review one, say) makes two groups, so a tick on one can never reach the other.
public struct PlanGroup: Hashable, Sendable, Identifiable {
    public let name: String
    public let section: PlanSection
    public let items: [PlanItem]
    public let bytes: Int64

    public var count: Int { items.count }
    /// The rule that planned the items (the first one's, as a group is one rule's label).
    public var rule: String { items.first?.rule ?? "" }
    public var id: String { "\(section.rawValue)/\(name)" }
}

/// The paths handed to `cmm apply`: the ticked items of one plan, in that plan's order.
///
/// This is safety rule 2 made structural. The only public way to make one takes a `Plan` (which cannot be built
/// outside this module) and keeps only the paths that are items of that plan, so there is no way for the app to
/// pass a path that was typed, constructed or left over from an older plan. The `unchecked` initializer is for
/// tests and is not visible to the app target.
public struct ApplySelection: Hashable, Sendable {
    public let paths: [String]
    public let bytes: Int64

    public var count: Int { paths.count }

    public init(plan: Plan, ticked: Set<String>) {
        var seen = Set<String>()
        var paths: [String] = []
        var bytes: Int64 = 0
        // Only safe and review items can be chosen; a manual or unknown tier is dropped even if a path was forged in.
        for item in plan.items
        where PlanSection(tier: item.tier).isTickable && ticked.contains(item.path) && seen.insert(item.path).inserted {
            paths.append(item.path)
            bytes += item.bytes
        }
        self.paths = paths
        self.bytes = bytes
    }

    init(unchecked paths: [String], bytes: Int64 = 0) {
        self.paths = paths
        self.bytes = bytes
    }
}

/// Which items of a plan are ticked. A value type: the view model owns one and changes it through these methods.
///
/// Items of tier `safe` start ticked. Items of tier `review` are never ticked for you: only an explicit tick on the
/// item or on its group takes them. Items of any other tier cannot be ticked at all.
public struct SelectionModel: Equatable, Sendable {
    public let plan: Plan
    /// Groups by section (safe, review, other), and inside a section largest first; items inside a group largest first.
    public let groups: [PlanGroup]
    /// The paths of the ticked items. Always a subset of the plan's tickable paths.
    public private(set) var ticked: Set<String>

    private let known: Set<String>
    private let tickable: Set<String>
    private let uniqueItems: [PlanItem]

    public init(plan: Plan) {
        var seen = Set<String>()
        var unique: [PlanItem] = []
        for item in plan.items where seen.insert(item.path).inserted {
            unique.append(item)
        }

        struct Key: Hashable {
            let section: PlanSection
            let name: String
        }
        let byKey = Dictionary(grouping: unique) { Key(section: PlanSection(tier: $0.tier), name: $0.group) }
        let order = Dictionary(uniqueKeysWithValues: PlanSection.allCases.enumerated().map { ($1, $0) })
        let groups = byKey.map { key, items -> PlanGroup in
            let sorted = items.sorted { ($1.bytes, $0.path) < ($0.bytes, $1.path) }
            return PlanGroup(name: key.name, section: key.section, items: sorted, bytes: sorted.reduce(0) { $0 + $1.bytes })
        }
        .sorted {
            if $0.section != $1.section { return order[$0.section]! < order[$1.section]! }
            return $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name
        }

        self.plan = plan
        self.groups = groups
        self.uniqueItems = unique
        self.known = seen
        self.tickable = Set(unique.filter { PlanSection(tier: $0.tier).isTickable }.map(\.path))
        self.ticked = Set(unique.filter { $0.tier == .safe }.map(\.path))
    }

    public static func == (lhs: SelectionModel, rhs: SelectionModel) -> Bool {
        lhs.plan == rhs.plan && lhs.ticked == rhs.ticked
    }

    // MARK: reading

    public func groups(in section: PlanSection) -> [PlanGroup] {
        groups.filter { $0.section == section }
    }

    public func isTicked(_ item: PlanItem) -> Bool {
        ticked.contains(item.path)
    }

    /// Whether a person may tick this item (safe and review tiers only).
    public func isTickable(_ item: PlanItem) -> Bool {
        tickable.contains(item.path)
    }

    /// The state of a group's checkbox, counting only the items that can be ticked.
    public func state(of group: PlanGroup) -> TriState {
        let candidates = group.items.filter { tickable.contains($0.path) }
        let on = candidates.reduce(0) { ticked.contains($1.path) ? $0 + 1 : $0 }
        if on == 0 { return .off }
        return on == candidates.count ? .on : .mixed
    }

    public var selectedCount: Int { ticked.count }

    public var selectedBytes: Int64 {
        uniqueItems.reduce(0) { ticked.contains($1.path) ? $0 + $1.bytes : $0 }
    }

    /// Bytes of ticked review items (zero until someone ticks one).
    public var selectedReviewBytes: Int64 {
        uniqueItems.reduce(0) { ticked.contains($1.path) && $1.tier == .review ? $0 + $1.bytes : $0 }
    }

    /// The "Safe to remove" figure: everything cmm calls safe, whatever is ticked.
    public var plannedBytes: Int64 {
        uniqueItems.reduce(0) { $1.tier == .safe ? $0 + $1.bytes : $0 }
    }

    public var safeCount: Int {
        uniqueItems.reduce(0) { $1.tier == .safe ? $0 + 1 : $0 }
    }

    /// What cmm offers for review (Docker's prunes, for example): never part of the safe figure.
    public var reviewBytes: Int64 {
        uniqueItems.reduce(0) { $1.tier == .review ? $0 + $1.bytes : $0 }
    }

    public var reviewCount: Int {
        uniqueItems.reduce(0) { $1.tier == .review ? $0 + 1 : $0 }
    }

    public var itemCount: Int { uniqueItems.count }

    /// What would be handed to cmm right now.
    public var applySelection: ApplySelection {
        ApplySelection(plan: plan, ticked: ticked)
    }

    // MARK: changing

    /// Ticks or unticks one item. An item that is not in this plan, or whose tier cannot be ticked, is ignored.
    public mutating func setTicked(_ on: Bool, for item: PlanItem) {
        guard tickable.contains(item.path) else { return }
        if on { ticked.insert(item.path) } else { ticked.remove(item.path) }
    }

    public mutating func toggle(_ item: PlanItem) {
        setTicked(!isTicked(item), for: item)
    }

    /// A group that is fully ticked is cleared; an empty or half-ticked one is ticked completely (its own items only).
    public mutating func toggle(_ group: PlanGroup) {
        let turnOn = state(of: group) != .on
        for item in group.items {
            setTicked(turnOn, for: item)
        }
    }
}
