import Foundation
import Observation

/// What the History face keeps while it is open, and nothing longer: which cleanings are open to their items. The face makes
/// its own each time it appears, so a closed pane, or another face, starts again at rest; a test hands one in to draw a
/// given moment.
@MainActor
@Observable
public final class HistoryFaceState {
    /// The cleanings that are open to their items (`RunRows.Row.id`).
    public var expanded: Set<String>

    public init(expanded: Set<String> = []) {
        self.expanded = expanded
    }

    /// Opens a cleaning that is closed, and closes one that is open.
    public func toggle(_ run: String) {
        setExpanded(run, !expanded.contains(run))
    }

    public func setExpanded(_ run: String, _ open: Bool) {
        if open { expanded.insert(run) } else { expanded.remove(run) }
    }
}
