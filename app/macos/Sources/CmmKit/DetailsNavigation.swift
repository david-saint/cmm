import Foundation

/// What a key does in the Details list. The list is one tab stop, and inside it the arrows move between the rows
/// that can be ticked (the groups, and the items of the groups that are open), space ticks, and right and left open
/// and close a group the way a Finder list does. Pure, so it is tested without a window; the view applies the action.
public enum DetailsNavigation {
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
        /// Move the focus to this row id.
        case focus(String)
        /// Tick or untick the group or item with this row id.
        case toggleTick(String)
        /// Open or close the group with this row id.
        case expand(String)
        case collapse(String)
    }

    /// The focus, or nil when that row is no longer in the list (its group was closed, the plan changed).
    public static func validFocus(_ focused: String?, in model: DetailsModel) -> String? {
        guard let focused, model.focusableIDs.contains(focused) else { return nil }
        return focused
    }

    public static func handle(_ key: Key, focused: String?, in model: DetailsModel) -> Action {
        let ids = model.focusableIDs
        guard let first = ids.first, let last = ids.last else { return .none }
        let current = validFocus(focused, in: model)
        let index = current.flatMap { ids.firstIndex(of: $0) }
        let groups = Dictionary(
            uniqueKeysWithValues: model.sections.flatMap(\.rows).compactMap { row -> (String, DetailsModel.GroupRow)? in
                if case .group(let group) = row { return (group.id, group) }
                return nil
            }
        )

        switch key {
        case .down:
            guard let index else { return .focus(first) }
            return index + 1 < ids.count ? .focus(ids[index + 1]) : .none
        case .up:
            guard let index else { return .focus(last) }
            return index > 0 ? .focus(ids[index - 1]) : .none
        case .home:
            return .focus(first)
        case .end:
            return .focus(last)
        case .right:
            guard let current, let index, let group = groups[current] else { return .none }
            if !group.isExpanded { return .expand(current) }
            let next = index + 1 < ids.count ? ids[index + 1] : nil
            return next.map { $0.hasPrefix("item:") ? .focus($0) : .none } ?? .none
        case .left:
            guard let current, let index else { return .none }
            if let group = groups[current] { return group.isExpanded ? .collapse(current) : .none }
            let parent = ids[..<index].last { $0.hasPrefix("group:") }
            return parent.map { .focus($0) } ?? .none
        case .space:
            return current.map { .toggleTick($0) } ?? .none
        case .return:
            guard let current else { return .none }
            if let group = groups[current] { return group.isExpanded ? .collapse(current) : .expand(current) }
            return .toggleTick(current)
        }
    }
}
