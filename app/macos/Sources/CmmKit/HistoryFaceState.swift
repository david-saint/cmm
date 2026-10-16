import Foundation
import Observation

/// What the History face keeps while it is open, and nothing longer: which cleanings are open to their items, the moment
/// under the pointer on the chart, and whether a read has taken long enough to say so. The face makes its own each time it
/// appears, so a closed pane, or another face, starts again at rest; a test hands one in to draw a given moment (the pointer
/// cannot be moved by a test: SwiftUI's hover answers only the real one).
@MainActor
@Observable
public final class HistoryFaceState {
    /// How long a read may take before the face says it is reading. Most take less, and then nothing is said at all.
    public static let readingDelay: Duration = .milliseconds(300)

    /// The cleanings that are open to their items (`RunRows.Row.id`).
    public var expanded: Set<String>
    /// The moment under the pointer on the chart, or nil while the pointer is elsewhere.
    public var pointerTime: Date?
    /// A read has been out for `readingDelay`: the face says so, quietly, until it is done.
    public private(set) var showsReading = false

    @ObservationIgnored private let wait: @Sendable (Duration) async -> Void
    /// The wait for the read that is out, if one is.
    @ObservationIgnored private var waiting: Task<Void, Never>?

    /// - Parameter wait: how the face waits `readingDelay` (a test holds it, to look before and after).
    public init(
        expanded: Set<String> = [], pointerTime: Date? = nil,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.expanded = expanded
        self.pointerTime = pointerTime
        self.wait = wait
    }

    /// The History model began a read, or finished one. A read that ends within `readingDelay` is never mentioned; one that
    /// takes longer is, from then until it ends.
    public func readingChanged(_ reading: Bool) {
        waiting?.cancel()
        waiting = nil
        guard reading else {
            showsReading = false
            return
        }
        waiting = Task { [wait] in
            await wait(Self.readingDelay)
            guard !Task.isCancelled else { return }
            self.showsReading = true
        }
    }

    /// Opens a cleaning that is closed, and closes one that is open.
    public func toggle(_ run: String) {
        setExpanded(run, !expanded.contains(run))
    }

    public func setExpanded(_ run: String, _ open: Bool) {
        if open { expanded.insert(run) } else { expanded.remove(run) }
    }
}
