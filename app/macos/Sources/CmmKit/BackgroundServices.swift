import Foundation

/// A timer that goes by the wall clock: it fires at a moment of the calendar, and when the Mac slept through that moment, as soon
/// as it wakes (in the app this is a `DispatchWallTime` timer). Cancelling it is final.
public protocol WallClockTimer: Sendable {
    func schedule(at date: Date, fire: @escaping @Sendable () -> Void) -> any ScheduledActivity
}

/// What runs while cmm runs and its window may be closed (spec R6, R7): the free-space sampler and the Monday reminder, each only
/// while its switch is on. Nothing here runs a process of its own or deletes anything: the sampler asks cmm for a note of the
/// free space, and the reminder asks the window for its scan.
///
/// - The sampler starts when the history switch is on (at launch, or when it is turned on), and stops when it goes off. Its own
///   schedule comes round every 30 minutes, and a cleaning that ends asks for one more note.
/// - The reminder is looked at when cmm launches, when its switch is turned on (once macOS has answered its question about
///   notifications, so that a reminder due that day is not spent on a note macOS would not show) and when its weekday or time
///   changes; then at the moment the planner names, by a wall-clock timer (which also fires after the Mac wakes, if the moment
///   passed in its sleep); and by an hourly heartbeat that the system also runs after a wake. A look that is not due costs
///   nothing. A check that could not scan (a screen in use, a failed scan) is tried again ten minutes later, until the day is
///   over and the planner says next week.
@MainActor
public final class BackgroundServices {
    /// The heartbeat: about hourly, as the system sees fit.
    public static let heartbeatInterval: TimeInterval = 60 * 60
    public static let heartbeatTolerance: TimeInterval = 15 * 60
    /// How long after a check that could not scan it is tried again.
    public static let retryAfter: TimeInterval = 10 * 60

    /// The moment the reminder's timer is set for, if it is set.
    public private(set) var reminderTimerAt: Date?
    public private(set) var heartbeatRunning = false
    /// What the reminder's last check came to.
    public private(set) var lastOutcome: WeeklyReminder.Outcome?

    private let settings: SettingsModel
    private let sampler: SamplerSchedule
    private let reminder: WeeklyReminder
    private let timer: any WallClockTimer
    private let heartbeat: any ActivityScheduler
    private let now: @Sendable () -> Date

    private var timerActivity: (any ScheduledActivity)?
    private var heartbeatActivity: (any ScheduledActivity)?
    private var watch: Watch<Switches>?
    private var switches: Switches?

    /// The switches that start and stop something here, and whether macOS shows cmm's notifications.
    private struct Switches: Equatable {
        let history: Bool
        let reminder: Bool
        let schedule: WeeklySchedule
        let notifications: NotificationAuthorization
    }

    public init(
        settings: SettingsModel,
        sampler: SamplerSchedule,
        reminder: WeeklyReminder,
        timer: any WallClockTimer,
        heartbeat: any ActivityScheduler,
        now: @escaping @Sendable () -> Date
    ) {
        self.settings = settings
        self.sampler = sampler
        self.reminder = reminder
        self.timer = timer
        self.heartbeat = heartbeat
        self.now = now
    }

    deinit {
        timerActivity?.cancel()
        heartbeatActivity?.cancel()
    }

    /// cmm has launched: what macOS says about notifications is read (never asked), what is switched on starts, and from now on
    /// the switches are followed.
    public func start() async {
        guard watch == nil else { return }
        await settings.refresh()
        let settings = settings
        let watch = Watch(
            {
                Switches(
                    history: settings.historyEnabled, reminder: settings.weeklyReminderEnabled, schedule: settings.weeklySchedule,
                    notifications: settings.notifications
                )
            },
            changed: { [weak self] switches in
                Task { @MainActor in await self?.follow(switches) }
            }
        )
        self.watch = watch
        await follow(watch.value)
    }

    /// A cleaning of the window's ended: the free space moved, so the sampler takes one more note (if it is on).
    public func cleaningEnded() async {
        await sampler.trigger(.cleaningEnded)
    }

    /// Looks at the reminder now (the timer, the heartbeat, a launch, the switch), and sets the timer for the next look.
    public func checkReminder() async {
        let outcome = await reminder.check()
        lastOutcome = outcome
        switch outcome {
        case .off:
            setTimer(at: nil)
        case .notDue(let until):
            setTimer(at: until)
        case .busy:
            break  // the check that is running sets the timer when it ends
        case .scanFailed:
            setTimer(at: now().addingTimeInterval(Self.retryAfter))
        case .quiet, .delivered:
            setTimer(at: reminder.nextCheck())
        }
    }

    // MARK: following the switches

    private func follow(_ new: Switches) async {
        let old = switches
        switches = new

        if new.history != old?.history {
            if new.history { await sampler.start() } else { sampler.stop() }
        }

        guard new.reminder else {
            if old?.reminder == true || old == nil {
                stopHeartbeat()
                setTimer(at: nil)
            }
            return
        }
        startHeartbeat()
        let allowed = new.notifications == .allowed
        let turnedOn = old?.reminder != true
        let movedOrAllowed = new.schedule != old?.schedule || (allowed && old?.notifications != .allowed)
        if turnedOn && allowed || !turnedOn && movedOrAllowed {
            await checkReminder()
        } else if turnedOn {
            // macOS has not said yes (yet): the timer and the heartbeat look later, and the planner decides then.
            setTimer(at: reminder.nextCheck())
        }
    }

    // MARK: the timer and the heartbeat

    private func setTimer(at date: Date?) {
        timerActivity?.cancel()
        timerActivity = nil
        reminderTimerAt = date
        guard let date else { return }
        timerActivity = timer.schedule(at: date) { [weak self] in
            Task { @MainActor in await self?.checkReminder() }
        }
    }

    private func startHeartbeat() {
        guard heartbeatActivity == nil else { return }
        heartbeatRunning = true
        heartbeatActivity = heartbeat.schedule(interval: Self.heartbeatInterval, tolerance: Self.heartbeatTolerance) { [weak self] in
            await self?.checkReminder()
        }
    }

    private func stopHeartbeat() {
        heartbeatActivity?.cancel()
        heartbeatActivity = nil
        heartbeatRunning = false
    }
}
