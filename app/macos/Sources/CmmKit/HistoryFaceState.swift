import Foundation
import Observation

/// What the History face keeps while it is open, and nothing longer: which cleanings are open to their items, and the moment
/// under the pointer on the chart. The face makes its own each time it appears, so a closed pane, or another face, starts
/// again at rest; a test hands one in to draw a given moment (the pointer cannot be moved by a test: SwiftUI's hover answers
/// only the real one).
@MainActor
@Observable
public final class HistoryFaceState {
    /// The cleanings that are open to their items (`RunRows.Row.id`).
    public var expanded: Set<String>
    /// The moment under the pointer on the chart, or nil while the pointer is elsewhere.
    public var pointerTime: Date?

    public init(expanded: Set<String> = [], pointerTime: Date? = nil) {
        self.expanded = expanded
        self.pointerTime = pointerTime
    }

    /// Opens a cleaning that is closed, and closes one that is open.
    public func toggle(_ run: String) {
        setExpanded(run, !expanded.contains(run))
    }

    public func setExpanded(_ run: String, _ open: Bool) {
        if open { expanded.insert(run) } else { expanded.remove(run) }
    }
}
