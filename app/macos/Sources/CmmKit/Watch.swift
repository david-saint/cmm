import Foundation
import Observation

/// Calls `changed` every time the value that `current` reads from observable objects changes, until it is cancelled or let go.
///
/// It is how the app's long-lived parts follow the models without a view: a view goes away when its window closes, and the menu
/// bar item, the sampler and the reminder must hear of a scan or a cleaning whether or not a window is open. Observation says that
/// something will change before it has, so the value is read again on the main actor's next turn, when the change has landed;
/// a change back to the value last reported is not reported again.
@MainActor
public final class Watch<Value: Equatable> {
    private let current: @MainActor () -> Value
    private let changed: @MainActor (Value) -> Void
    private var last: Value
    private var active = true

    /// `current` is called once now (the value it returns is the one changes are measured from) and again after every change.
    public init(_ current: @escaping @MainActor () -> Value, changed: @escaping @MainActor (Value) -> Void) {
        self.current = current
        self.changed = changed
        last = current()
        arm()
    }

    /// The value as of the last change that was reported (or the first reading).
    public var value: Value { last }

    public func cancel() {
        active = false
    }

    private func arm() {
        guard active else { return }
        withObservationTracking {
            _ = current()
        } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        guard active else { return }
        let now = current()
        arm()
        guard now != last else { return }
        last = now
        changed(now)
    }
}
