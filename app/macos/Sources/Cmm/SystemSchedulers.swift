import CmmKit
import Foundation

// The thin adaptors between CmmKit's timing protocols and the system's: `NSBackgroundActivityScheduler` for what comes round now
// and then (the free-space sampler, the reminder's heartbeat), and a wall-clock dispatch timer for the reminder's moment. They
// only pass things through; when and why is CmmKit's (`SamplerSchedule`, `BackgroundServices`), tested with fakes. No test makes
// one of these (a source test checks it).

/// What comes round now and then, timed by the system: it picks the moment within the tolerance, comes round after the Mac wakes
/// when a visit is overdue, and is told when each visit's work is done.
struct SystemActivityScheduler: ActivityScheduler {
    /// The system's name for the activity, one per kind (`com.davidsaint.cmm.sampler`, `com.davidsaint.cmm.weekly`).
    let identifier: String

    func schedule(interval: TimeInterval, tolerance: TimeInterval, body: @escaping @Sendable () async -> Void) -> any ScheduledActivity {
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = tolerance
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            let done = Completion(completion)
            Task {
                await body()
                done.call()
            }
        }
        return Activity(scheduler: scheduler)
    }

    /// The system's completion for one visit, carried to the end of the work it was for.
    private final class Completion: @unchecked Sendable {
        private let handler: NSBackgroundActivityScheduler.CompletionHandler

        init(_ handler: @escaping NSBackgroundActivityScheduler.CompletionHandler) {
            self.handler = handler
        }

        func call() {
            handler(.finished)
        }
    }

    private final class Activity: ScheduledActivity, @unchecked Sendable {
        private let scheduler: NSBackgroundActivityScheduler

        init(scheduler: NSBackgroundActivityScheduler) {
            self.scheduler = scheduler
        }

        func cancel() {
            scheduler.invalidate()
        }
    }
}

/// A one-shot timer by the wall clock (`DispatchWallTime`): it fires at a moment of the calendar, and when the Mac slept through
/// it, as soon as the Mac wakes. It fires on the main queue.
struct SystemWallClock: WallClockTimer {
    func schedule(at date: Date, fire: @escaping @Sendable () -> Void) -> any ScheduledActivity {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let deadline = DispatchWallTime(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000)))
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: deadline, repeating: .never, leeway: .seconds(5))
        source.setEventHandler(handler: fire)
        source.resume()
        return Timer(source: source)
    }

    private final class Timer: ScheduledActivity, @unchecked Sendable {
        private let source: any DispatchSourceTimer

        init(source: any DispatchSourceTimer) {
            self.source = source
        }

        func cancel() {
            source.cancel()
        }
    }
}
