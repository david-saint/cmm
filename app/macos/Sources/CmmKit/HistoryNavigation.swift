import Foundation

extension RunRows {
    /// The cleanings in the order the list shows them, newest first: the rows of each week, one week after another.
    public var listed: [Row] { weeks.flatMap(\.rows) }
}

/// What a key does in the History list. The list is one stop for the Tab key, and inside it the keys are the List's: up and
/// down move between the cleanings, right opens the one with the keyboard and left closes it, Space and Return open or close
/// it, Home and End go to the first and the last. (The items of an open cleaning are only read, so the keyboard stays on the
/// rows.) Pure, so it is tested without a window; the face does what it says.
public enum HistoryNavigation {
    public enum Action: Equatable, Sendable {
        case none
        /// Move the keyboard to this cleaning (`RunRows.Row.id`).
        case focus(String)
        case expand(String)
        case collapse(String)
    }

    /// The cleaning with the keyboard, or nil when it is no longer listed (a new report came in).
    public static func validFocus(_ focused: String?, in rows: [RunRows.Row]) -> String? {
        guard let focused, rows.contains(where: { $0.id == focused }) else { return nil }
        return focused
    }

    /// - Parameter rows: the cleanings in the order they are listed, newest first (the weeks' rows, one after another).
    public static func handle(_ key: DetailsNavigation.Key, focused: String?, rows: [RunRows.Row], expanded: Set<String>) -> Action {
        guard let first = rows.first, let last = rows.last else { return .none }
        let index = validFocus(focused, in: rows).flatMap { id in rows.firstIndex { $0.id == id } }
        let row = index.map { rows[$0] }

        switch key {
        case .down:
            guard let index else { return .focus(first.id) }
            return index + 1 < rows.count ? .focus(rows[index + 1].id) : .none
        case .up:
            guard let index else { return .focus(last.id) }
            return index > 0 ? .focus(rows[index - 1].id) : .none
        case .home:
            return .focus(first.id)
        case .end:
            return .focus(last.id)
        case .right:
            guard let row, row.hasDetails, !expanded.contains(row.id) else { return .none }
            return .expand(row.id)
        case .left:
            guard let row, expanded.contains(row.id) else { return .none }
            return .collapse(row.id)
        case .space, .return:
            guard let row, row.hasDetails else { return .none }
            return expanded.contains(row.id) ? .collapse(row.id) : .expand(row.id)
        }
    }
}
