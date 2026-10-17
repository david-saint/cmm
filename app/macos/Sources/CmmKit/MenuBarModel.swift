import Foundation
import Observation

/// What the menu bar item knows between one look and the next, and what it shows (spec R5, the boards `C-MenuBar-States` and
/// `C-MenuBar-Dark`). It is told what happened (a scan or a cleaning of the window's, a free-space note, a history report) and
/// keeps it in memory only: nothing it knows is ever stored.
///
/// The popover says something else without anything happening at two moments: when "just cleaned" ends, an hour after a
/// cleaning, and at midnight, when "Last cleaned Tue" may become a date. At those moments `tick` moves on, and a view that drew
/// the presentation draws it again.
@MainActor
@Observable
public final class MenuBarModel {
    public private(set) var context = MenuBarContext()
    /// The volume cmm last named (a plan's or the history's), which the header calls by the name Finder gives it.
    public private(set) var volume: String?
    /// Moves on at the moments the popover would say something else of its own accord.
    public private(set) var tick = 0

    /// The volume cmm reads when nothing has named one: the startup volume's writable half, which Finder calls by the startup
    /// volume's name.
    public static let defaultVolume = "/System/Volumes/Data"

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var nextTick: Task<Void, Never>?
    @ObservationIgnored private var nextTickAt: Date?

    /// `sleep` waits for that many seconds (a test hands in one it controls).
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
    }

    // MARK: what happened

    /// A scan of the window's finished (the window's own, or the weekly reminder's, which is the same).
    public func recordScan(_ plan: Plan) {
        context.recordScan(plan: plan, at: now())
        volume = plan.host.volume
        scheduleTick()
    }

    /// The window finished a cleaning.
    public func recordCleaning(_ summary: CleanSummary) {
        context.recordCleaning(summary)
        scheduleTick()
    }

    /// `cmm sample` read the free space.
    public func recordSample(_ sample: SampleResult, receivedAt: Date) {
        context.recordSample(sample, receivedAt: receivedAt)
    }

    /// A history report arrived (for the History face, or for the menu bar's "Last cleaned").
    public func recordHistory(_ report: HistoryReport) {
        context.recordHistory(report, now: now())
        if volume == nil, !report.host.volume.isEmpty { volume = report.host.volume }
        scheduleTick()
    }

    // MARK: what it shows

    /// The item and the popover for this moment. `volumeName` turns the volume cmm named into the name Finder gives it.
    public func presentation(
        phase: AppModel.Phase, confirmationOpen: Bool, volumeName: (String) -> String, calendar: Calendar, locale: Locale
    ) -> MenuBarPresentation {
        _ = tick
        return context.presentation(
            phase: phase, confirmationOpen: confirmationOpen, volumeName: volumeName(volume ?? Self.defaultVolume),
            now: now(), calendar: calendar, locale: locale
        )
    }

    /// Whether the popover's Scan may scan: the window's own rule for ⌘R (`MenuBarPopover.canScan`), and never while a screen of
    /// the window is in someone's use (a scan would take the card, or a result on the screen, away from them).
    public static func scanEnabled(
        _ popover: MenuBarPopover, phase: AppModel.Phase, confirmationOpen: Bool, mainWindowOpen: Bool
    ) -> Bool {
        popover.canScan
            && !LifecyclePolicy.screenInUse(phase: phase, confirmationOpen: confirmationOpen, mainWindowOpen: mainWindowOpen)
    }

    // MARK: the moments it changes of its own accord

    /// The next of: the end of "just cleaned", if it is still to come, and the start of the next day (found from the start of
    /// this one, so a day that begins at 01:00 after a clock change is found too).
    func nextChange(after date: Date) -> Date {
        let today = calendar.startOfDay(for: date)
        let midnight = calendar.date(byAdding: .day, value: 1, to: today).map { calendar.startOfDay(for: $0) }
            ?? date.addingTimeInterval(86_400)
        guard let cleaning = context.cleaning else { return midnight }
        let end = cleaning.finishedAt.addingTimeInterval(MenuBarState.justCleanedFor)
        return end > date ? min(end, midnight) : midnight
    }

    private func scheduleTick() {
        let at = nextChange(after: now())
        guard at != nextTickAt else { return }
        nextTick?.cancel()
        nextTickAt = at
        let wait = max(at.timeIntervalSince(now()), 0)
        let sleep = sleep
        nextTick = Task { @MainActor [weak self] in
            await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            self.nextTickAt = nil
            self.tick &+= 1
            self.scheduleTick()
        }
    }
}
