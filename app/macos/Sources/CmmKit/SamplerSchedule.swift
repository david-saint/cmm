import Foundation

/// What the app asks of the system to do something now and then, so that the system picks the moment (in the app this is
/// `NSBackgroundActivityScheduler`, which is not built yet). The body is async and never throws; whoever implements this calls
/// the system's completion when the body returns, whatever happened inside it.
public protocol ActivityScheduler: Sendable {
    func schedule(interval: TimeInterval, tolerance: TimeInterval, body: @escaping @Sendable () async -> Void) -> any ScheduledActivity
}

/// A scheduled activity, which can be cancelled.
public protocol ScheduledActivity: Sendable {
    func cancel()
}

/// Notes the free space for the history (spec R6): `cmm sample --json` when it is turned on and the app launches, every thirty
/// minutes (the system times it, within ten), when the Mac wakes, and when a cleaning ends. cmm decides whether a note is due
/// (thirty minutes since the last, or the free space moved by 256 MiB), so asking often costs nothing but a moment.
///
/// One sample is in flight at a time. A request that comes while one is waits for it and then makes one more (however many
/// came), so a cleaning that ends while a sample is out is still followed by a sample that sees it. A sample that fails is
/// ignored, with one quiet line in the log. Turning it off cancels the schedule and drops what a sample still out brings back.
@MainActor
public final class SamplerSchedule {
    /// Why a sample is asked for. (Only the log says; they all do the same.)
    public enum Trigger: String, Equatable, Sendable, CaseIterable {
        /// It was turned on, or the app launched with it on.
        case started = "start"
        /// The system's schedule came round.
        case scheduled = "schedule"
        case wake = "wake"
        /// A cleaning ended: the one thing that moves the free space by a lot at once.
        case cleaningEnded = "cleaning"
    }

    /// How often the system is asked to come round, and how far from that it may be.
    public static let interval: TimeInterval = 30 * 60
    public static let tolerance: TimeInterval = 10 * 60

    public private(set) var isActive = false

    private let scheduler: any ActivityScheduler
    private let sample: @Sendable () async throws -> SampleResult
    private let now: @Sendable () -> Date
    private let onSample: @MainActor (SampleResult, Date) -> Void
    private let log: @Sendable (String) -> Void

    private var activity: (any ScheduledActivity)?
    /// The one task that is asking cmm, for as long as someone has asked and it has not answered.
    private var flight: Task<Void, Never>?
    /// Someone asked while a sample was out (or asked, and the sample has not begun).
    private var pending = false
    private var pendingReason = Trigger.scheduled
    /// Counts the times it was turned off, so that a sample that was out at the time can tell it is not wanted any more.
    private var epoch = 0

    /// `sample` asks cmm for one; `onSample` gets what it said, with the moment it came back (by `now`); `log` takes the one
    /// quiet line a failure leaves.
    public init(
        scheduler: any ActivityScheduler,
        sample: @escaping @Sendable () async throws -> SampleResult,
        now: @escaping @Sendable () -> Date,
        onSample: @escaping @MainActor (SampleResult, Date) -> Void = { _, _ in },
        log: @escaping @Sendable (String) -> Void
    ) {
        self.scheduler = scheduler
        self.sample = sample
        self.now = now
        self.onSample = onSample
        self.log = log
    }

    /// Asks cmm for a sample through the client, and for nothing else.
    public convenience init(
        client: any CmmClient,
        scheduler: any ActivityScheduler,
        now: @escaping @Sendable () -> Date,
        onSample: @escaping @MainActor (SampleResult, Date) -> Void = { _, _ in },
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(scheduler: scheduler, sample: { try await client.sample() }, now: now, onSample: onSample, log: log)
    }

    deinit {
        activity?.cancel()
    }

    /// Turn it on: schedule the system's visits and take a sample now. Does nothing when it is on.
    public func start() async {
        guard !isActive else { return }
        isActive = true
        activity = scheduler.schedule(interval: Self.interval, tolerance: Self.tolerance) { [weak self] in
            await self?.trigger(.scheduled)
        }
        await trigger(.started)
    }

    /// Turn it off: cancel the schedule, forget what was waiting, and ignore what a sample still out brings back.
    public func stop() {
        guard isActive else { return }
        isActive = false
        activity?.cancel()
        activity = nil
        pending = false
        epoch += 1
    }

    /// Ask for a sample, for a reason. Ignored while it is off. Returns when the sample (and the one that waited behind it, if
    /// any) is done, so that whoever the system called can say it has finished.
    public func trigger(_ reason: Trigger) async {
        guard isActive else { return }
        pending = true
        pendingReason = reason
        if let flight {
            await flight.value
            return
        }
        let flight = Task { await drain() }
        self.flight = flight
        await flight.value
    }

    /// Asks cmm, again for as long as someone asked while it was busy. Nothing in here lets a second sample start before the
    /// first has answered, and nothing the sample brings back counts once it was turned off.
    private func drain() async {
        while pending && isActive {
            pending = false
            let turn = epoch
            let reason = pendingReason
            do {
                let result = try await sample()
                if turn == epoch { onSample(result, now()) }
            } catch {
                if turn == epoch { log(Self.line(reason: reason, error: error)) }
            }
        }
        flight = nil
    }

    /// One line that names what asked and what went wrong, and never what cmm printed (it can hold a path).
    private static func line(reason: Trigger, error: any Error) -> String {
        let what = (error as? CmmError)?.title ?? String(describing: type(of: error))
        return "No free-space note (\(reason.rawValue)): \(what)."
    }
}
