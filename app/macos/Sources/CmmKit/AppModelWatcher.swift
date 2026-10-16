import Foundation

/// Follows the window's model without a view, and says once when a scan has finished (with its plan) and once when a cleaning
/// has ended (with cmm's summary, or nil when it ended in an error). The menu bar item, the free-space sampler and the History
/// hear of the window's work through it whether or not the window is open; it only looks.
///
/// It goes by what a finished piece of work leaves behind (a plan, a summary, a cleaning's failure) rather than by the phases in
/// between, which can pass faster than anyone looks: two scans never leave the same plan, because cmm stamps each with its time.
@MainActor
public final class AppModelWatcher {
    /// When the newest plan was made: the earlier of cmm's own time for it and the moment the app received it. Nil before a
    /// scan has finished.
    public private(set) var lastScanAt: Date?

    private let model: AppModel
    private let now: @Sendable () -> Date
    private let scanFinished: @MainActor (Plan) -> Void
    private let cleaningEnded: @MainActor (CleanSummary?) -> Void
    private var watch: Watch<Snapshot>?
    private var reportedPlan: Plan?
    private var reportedSummary: CleanSummary?
    private var reportedFailure: AppFailure?

    private struct Snapshot: Equatable {
        let phase: AppModel.Phase
        let plan: Plan?
        let summary: CleanSummary?
        let failure: AppFailure?
    }

    public init(
        model: AppModel,
        now: @escaping @Sendable () -> Date = { Date() },
        scanFinished: @escaping @MainActor (Plan) -> Void,
        cleaningEnded: @escaping @MainActor (CleanSummary?) -> Void
    ) {
        self.model = model
        self.now = now
        self.scanFinished = scanFinished
        self.cleaningEnded = cleaningEnded
    }

    /// Starts following. A scan that had already finished is reported at once.
    public func start() {
        guard watch == nil else { return }
        let model = model
        let watch = Watch(
            { Snapshot(phase: model.phase, plan: model.plan, summary: model.summary, failure: model.failure) },
            changed: { [weak self] in self?.saw($0) }
        )
        self.watch = watch
        saw(watch.value)
    }

    public func stop() {
        watch?.cancel()
        watch = nil
    }

    private func saw(_ snapshot: Snapshot) {
        if snapshot.phase == .ready || snapshot.phase == .empty, let plan = snapshot.plan, plan != reportedPlan {
            reportedPlan = plan
            let received = now()
            lastScanAt = min(plan.generatedAt ?? received, received)
            scanFinished(plan)
        }

        if let summary = snapshot.summary {
            if summary != reportedSummary {
                reportedSummary = summary
                cleaningEnded(summary)
            }
        } else {
            reportedSummary = nil
        }

        if let failure = snapshot.failure, failure.stage == .clean {
            if failure != reportedFailure {
                reportedFailure = failure
                cleaningEnded(nil)
            }
        } else {
            reportedFailure = nil
        }
    }
}
