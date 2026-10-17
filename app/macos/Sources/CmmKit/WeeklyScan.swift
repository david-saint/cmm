import Foundation

/// The scan the weekly reminder speaks from (spec R7, the board `C-Notification`). It is the window's own scan, so that a click
/// on the note opens the window on "the same numbers from the 10:00 scan", and it never takes a screen away from someone using
/// it:
///
/// - a plan the window got less than 15 minutes ago, on the rest or nothing-to-clean screen, is used as it is (a scan would
///   reset the person's ticks);
/// - a scan that is already running is waited for, and its plan used;
/// - while the cleaning screen, the confirmation card, or (with the window open) a result or an error is up, it refuses: nothing
///   is written down, and the reminder tries again later that day;
/// - otherwise it asks the window to scan.
///
/// It only ever scans: the reminder never starts a cleaning.
@MainActor
public struct WeeklyScan {
    public enum Refusal: Error, Equatable {
        /// A screen of the window is in someone's use.
        case screenInUse
        /// The window's scan was still running when the wait ran out.
        case stillScanning
        /// The scan ended without a plan (it failed).
        case noPlan
    }

    /// A plan younger than this is the week's numbers already.
    public static let freshFor: TimeInterval = 15 * 60

    private let model: AppModel
    private let mainWindowOpen: @MainActor () -> Bool
    private let lastScanAt: @MainActor () -> Date?
    private let now: @Sendable () -> Date
    private let waitLimit: TimeInterval
    private let pause: @Sendable (TimeInterval) async -> Void

    /// - Parameters:
    ///   - lastScanAt: when the window's newest plan was made (`AppModelWatcher.lastScanAt`).
    ///   - waitLimit: how long to wait for a scan that is already running, checking every `step` seconds.
    public init(
        model: AppModel,
        mainWindowOpen: @escaping @MainActor () -> Bool,
        lastScanAt: @escaping @MainActor () -> Date?,
        now: @escaping @Sendable () -> Date,
        waitLimit: TimeInterval = 10 * 60,
        pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.model = model
        self.mainWindowOpen = mainWindowOpen
        self.lastScanAt = lastScanAt
        self.now = now
        self.waitLimit = waitLimit
        self.pause = pause
    }

    /// How often a running scan is looked at while it is waited for.
    static let step: TimeInterval = 1

    /// Makes (or finds) the scan, and gives its plan: the plan the reminder speaks from, or why there is none this time.
    public func scan() async throws -> Plan {
        if LifecyclePolicy.screenInUse(phase: model.phase, confirmationOpen: model.confirmation != nil, mainWindowOpen: mainWindowOpen()) {
            throw Refusal.screenInUse
        }
        if model.phase == .scanning {
            var waited: TimeInterval = 0
            while model.phase == .scanning {
                guard waited < waitLimit else { throw Refusal.stillScanning }
                await pause(Self.step)
                waited += Self.step
            }
            return try finished()
        }
        if model.phase == .ready || model.phase == .empty, let plan = model.plan, isFresh() {
            return plan
        }
        await model.scan()
        return try finished()
    }

    private func isFresh() -> Bool {
        guard let made = lastScanAt() else { return false }
        let age = now().timeIntervalSince(made)
        return age >= 0 && age < Self.freshFor
    }

    private func finished() throws -> Plan {
        guard model.phase == .ready || model.phase == .empty, let plan = model.plan else { throw Refusal.noPlan }
        return plan
    }
}
