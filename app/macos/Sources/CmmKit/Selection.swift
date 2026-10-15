import Foundation

/// The state of a group's checkbox.
public enum TriState: Hashable, Sendable {
    case off
    case on
    /// Some of the group's items are ticked and some are not.
    case mixed
}

/// The items of one `group` label, largest first.
public struct PlanGroup: Hashable, Sendable, Identifiable {
    public let name: String
    public let items: [PlanItem]
    public let bytes: Int64

    public var count: Int { items.count }
    public var id: String { name }
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
        for item in plan.items where ticked.contains(item.path) && seen.insert(item.path).inserted {
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
public struct SelectionModel: Equatable, Sendable {
    public let plan: Plan
    /// Groups largest first; items inside a group largest first. Built from the plan's items.
    public let groups: [PlanGroup]
    /// The paths of the ticked items. Always a subset of the plan's paths.
    public private(set) var ticked: Set<String>

    private let known: Set<String>
    private let uniqueItems: [PlanItem]

    /// Items of tier `safe` start ticked; everything else does not.
    public init(plan: Plan) {
        var seen = Set<String>()
        var unique: [PlanItem] = []
        for item in plan.items where seen.insert(item.path).inserted {
            unique.append(item)
        }

        let byName = Dictionary(grouping: unique, by: \.group)
        let groups = byName.map { name, items -> PlanGroup in
            let sorted = items.sorted { ($1.bytes, $0.path) < ($0.bytes, $1.path) }
            return PlanGroup(name: name, items: sorted, bytes: sorted.reduce(0) { $0 + $1.bytes })
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }

        self.plan = plan
        self.groups = groups
        self.uniqueItems = unique
        self.known = seen
        self.ticked = Set(unique.filter { $0.tier == .safe }.map(\.path))
    }

    public static func == (lhs: SelectionModel, rhs: SelectionModel) -> Bool {
        lhs.plan == rhs.plan && lhs.ticked == rhs.ticked
    }

    // MARK: reading

    public func isTicked(_ item: PlanItem) -> Bool {
        ticked.contains(item.path)
    }

    public func state(of group: PlanGroup) -> TriState {
        let on = group.items.reduce(0) { ticked.contains($1.path) ? $0 + 1 : $0 }
        if on == 0 { return .off }
        return on == group.items.count ? .on : .mixed
    }

    public var selectedCount: Int { ticked.count }

    public var selectedBytes: Int64 {
        uniqueItems.reduce(0) { ticked.contains($1.path) ? $0 + $1.bytes : $0 }
    }

    /// The "Safe to remove" figure: everything cmm calls safe, whatever is ticked.
    public var plannedBytes: Int64 {
        uniqueItems.reduce(0) { $1.tier == .safe ? $0 + $1.bytes : $0 }
    }

    public var safeCount: Int {
        uniqueItems.reduce(0) { $1.tier == .safe ? $0 + 1 : $0 }
    }

    public var itemCount: Int { uniqueItems.count }

    /// What would be handed to cmm right now.
    public var applySelection: ApplySelection {
        ApplySelection(plan: plan, ticked: ticked)
    }

    // MARK: changing

    /// Ticks or unticks one item. An item that is not in this plan is ignored.
    public mutating func setTicked(_ on: Bool, for item: PlanItem) {
        guard known.contains(item.path) else { return }
        if on { ticked.insert(item.path) } else { ticked.remove(item.path) }
    }

    public mutating func toggle(_ item: PlanItem) {
        setTicked(!isTicked(item), for: item)
    }

    /// A group that is fully ticked is cleared; an empty or half-ticked one is ticked completely.
    public mutating func toggle(_ group: PlanGroup) {
        let turnOn = state(of: group) != .on
        for item in group.items {
            setTicked(turnOn, for: item)
        }
    }
}
