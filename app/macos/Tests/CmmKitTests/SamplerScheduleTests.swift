import XCTest
@testable import CmmKit

/// The system's timer, by hand: nothing happens until a test says the time has come.
final class FakeActivityScheduler: ActivityScheduler, @unchecked Sendable {
    final class Activity: ScheduledActivity, @unchecked Sendable {
        let interval: TimeInterval
        let tolerance: TimeInterval
        let body: @Sendable () async -> Void
        private let cancelled = Locked(false)

        init(interval: TimeInterval, tolerance: TimeInterval, body: @escaping @Sendable () async -> Void) {
            self.interval = interval
            self.tolerance = tolerance
            self.body = body
        }

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func cancel() {
            cancelled.withLock { $0 = true }
        }
    }

    private let made = Locked<[Activity]>([])

    /// Everything that was ever scheduled, oldest first.
    var activities: [Activity] { made.withLock { $0 } }

    func schedule(interval: TimeInterval, tolerance: TimeInterval, body: @escaping @Sendable () async -> Void) -> any ScheduledActivity {
        let activity = Activity(interval: interval, tolerance: tolerance, body: body)
        made.withLock { $0.append(activity) }
        return activity
    }

    /// The system comes round to the newest schedule that is still on and waits for its body to end, as it does before it calls
    /// the activity finished. Says whether there was anyone to visit.
    @discardableResult
    func fire() async -> Bool {
        guard let activity = activities.last(where: { !$0.isCancelled }) else { return false }
        await activity.body()
        return true
    }

    /// A visit that was already on its way when the schedule was cancelled.
    func fireLate() async {
        await activities.last?.body()
    }
}

/// What the sampler asks cmm, answered by hand: the test says when each ask comes back and with what, and the fake counts how
/// many were out at once.
final class HandAnsweredSamples: @unchecked Sendable {
    typealias Answer = Result<SampleResult, CmmError>

    private struct State {
        var asked = 0
        var out = 0
        var mostAtOnce = 0
        var waiting: [CheckedContinuation<Answer, Never>] = []
    }

    private let state = Locked(State())

    var asked: Int { state.withLock { $0.asked } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }

    func ask() async throws -> SampleResult {
        let answer: Answer = await withCheckedContinuation { continuation in
            state.withLock {
                $0.asked += 1
                $0.out += 1
                $0.mostAtOnce = max($0.mostAtOnce, $0.out)
                $0.waiting.append(continuation)
            }
        }
        state.withLock { $0.out -= 1 }
        return try answer.get()
    }

    /// Answers the oldest ask nobody has answered yet.
    func answer(_ answer: Answer) {
        let continuation = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
        guard let continuation else { return XCTFail("nobody was waiting for an answer") }
        continuation.resume(returning: answer)
    }

    func answer(freeBytes: Int64, recorded: Bool = true) {
        answer(.success(SampleResult(recorded: recorded, t: nil, freeBytes: freeBytes, capacityBytes: nil)))
    }
}

/// Something done to the sampler in the background of a test, so that a test can wait for it without waiting for good: a sampler
/// that gets stuck fails its test instead of hanging the run.
final class SamplerJob: @unchecked Sendable {
    private let done = Locked(false)

    var isFinished: Bool { done.withLock { $0 } }

    init(_ body: @escaping @MainActor @Sendable () async -> Void) {
        Task { @MainActor [done] in
            await body()
            done.withLock { $0 = true }
        }
    }
}

struct SamplerStuck: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The free-space sampler (spec R6): when it asks cmm for a note, never two at once, a failure that is only a line in the log,
/// and nothing at all while it is off.
@MainActor
final class SamplerScheduleTests: XCTestCase {
    struct Received: Equatable {
        let freeBytes: Int64
        let recorded: Bool
        let at: Date
    }

    /// A sampler with everything it is given held where the test can see it.
    @MainActor
    final class Rig {
        let scheduler = FakeActivityScheduler()
        let samples = HandAnsweredSamples()
        let clock: Locked<Date>
        let log = Locked<[String]>([])
        let received = Locked<[Received]>([])
        let sampler: SamplerSchedule

        init(at start: Date) {
            let clock = Locked(start)
            let samples = self.samples
            let received = self.received
            let log = self.log
            self.clock = clock
            sampler = SamplerSchedule(
                scheduler: scheduler,
                sample: { try await samples.ask() },
                now: { clock.withLock { $0 } },
                onSample: { result, at in
                    received.withLock { $0.append(Received(freeBytes: result.freeBytes, recorded: result.recorded, at: at)) }
                },
                log: { line in log.withLock { $0.append(line) } }
            )
        }

        var lines: [String] { log.withLock { $0 } }
        var notes: [Received] { received.withLock { $0 } }
        var freeBytesReceived: [Int64] { notes.map(\.freeBytes) }
    }

    private let launch = TestTime.utc("2026-10-15T09:00:00Z")

    private func makeRig() -> Rig {
        Rig(at: launch)
    }

    /// Waits until cmm has been asked `count` times.
    private func waitForAsks(_ count: Int, _ rig: Rig) async throws {
        let reached = await eventuallyOnMain(timeout: 3) { rig.samples.asked >= count }
        if !reached { throw SamplerStuck("cmm was asked \(rig.samples.asked) times, not \(count)") }
    }

    private func finish(_ job: SamplerJob, _ what: String) async throws {
        let reached = await eventuallyOnMain(timeout: 3) { job.isFinished }
        if !reached { throw SamplerStuck("\(what) never returned") }
    }

    /// Time enough for anything that is going to happen to have happened.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// Turns it on and answers the first sample.
    private func turnOn(_ rig: Rig, firstFreeBytes: Int64 = 100) async throws {
        let starting = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)
        rig.samples.answer(freeBytes: firstFreeBytes)
        try await finish(starting, "start()")
    }

    // MARK: the schedule

    func testItAsksTheSystemToComeRoundEveryHalfHourAndAllowsTenMinutesEitherWay() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        XCTAssertEqual(rig.scheduler.activities.count, 1)
        XCTAssertEqual(rig.scheduler.activities.first?.interval, 1_800)
        XCTAssertEqual(rig.scheduler.activities.first?.tolerance, 600)
    }

    func testTheIntervalIsHalfAnHourAndTheToleranceTenMinutes() {
        XCTAssertEqual(SamplerSchedule.interval, 30 * 60)
        XCTAssertEqual(SamplerSchedule.tolerance, 10 * 60)
    }

    func testNothingIsScheduledUntilItIsTurnedOn() {
        let rig = makeRig()
        XCTAssertTrue(rig.scheduler.activities.isEmpty)
        XCTAssertFalse(rig.sampler.isActive)
    }

    func testTurningItOnTwiceChangesNothing() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        let again = SamplerJob { await rig.sampler.start() }
        try await finish(again, "the second start()")
        XCTAssertEqual(rig.scheduler.activities.count, 1, "one schedule, not two")
        XCTAssertEqual(rig.samples.asked, 1, "and no second note for turning it on again")
        XCTAssertTrue(rig.sampler.isActive)
    }

    // MARK: the notes

    func testTurningItOnTakesANoteAtOnce() async throws {
        let rig = makeRig()
        let starting = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)
        XCTAssertTrue(rig.sampler.isActive)
        XCTAssertEqual(rig.scheduler.activities.count, 1, "the schedule is set before the first note is out")
        rig.samples.answer(freeBytes: 18_000_000_000)
        try await finish(starting, "start()")
        XCTAssertEqual(rig.notes, [Received(freeBytes: 18_000_000_000, recorded: true, at: launch)])
        XCTAssertTrue(rig.lines.isEmpty, "nothing went wrong, so nothing is said")
    }

    func testTheSystemComingRoundTakesANoteAndIsToldItIsDoneOnlyWhenTheNoteIs() async throws {
        let rig = makeRig()
        try await turnOn(rig)

        let visit = SamplerJob { _ = await rig.scheduler.fire() }
        try await waitForAsks(2, rig)
        await settle()
        XCTAssertFalse(visit.isFinished, "the system is not told it is finished while the note is out")

        rig.samples.answer(freeBytes: 200)
        try await finish(visit, "the visit")
        XCTAssertEqual(rig.freeBytesReceived, [100, 200])
    }

    func testWakingTheMacAndTheEndOfACleaningEachTakeANote() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        var expected = 1
        for reason in [SamplerSchedule.Trigger.wake, .cleaningEnded, .scheduled, .started] {
            expected += 1
            let asking = SamplerJob { await rig.sampler.trigger(reason) }
            try await waitForAsks(expected, rig)
            XCTAssertEqual(rig.samples.asked, expected, "\(reason)")
            rig.samples.answer(freeBytes: Int64(expected))
            try await finish(asking, "\(reason)")
        }
        XCTAssertEqual(rig.freeBytesReceived, [100, 2, 3, 4, 5])
        XCTAssertEqual(rig.samples.mostAtOnce, 1)
    }

    func testWhetherOrNotCmmWroteANoteTheReadingIsPassedOn() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        let asking = SamplerJob { await rig.sampler.trigger(.wake) }
        try await waitForAsks(2, rig)
        rig.samples.answer(freeBytes: 300, recorded: false)
        try await finish(asking, "wake")
        XCTAssertEqual(rig.notes.map(\.recorded), [true, false], "the menu bar wants the free space even when no note was due")
        XCTAssertEqual(rig.freeBytesReceived, [100, 300])
    }

    func testTheReadingIsDatedWhenItCameBackAndNotWhenItWasAskedFor() async throws {
        let rig = makeRig()
        let later = launch.addingTimeInterval(7)
        let starting = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)
        rig.clock.withLock { $0 = later }
        rig.samples.answer(freeBytes: 5)
        try await finish(starting, "start()")
        XCTAssertEqual(rig.notes.map(\.at), [later])
    }

    // MARK: while it is off

    func testNothingIsAskedWhileItIsOff() async throws {
        let rig = makeRig()
        let neverOn = SamplerJob { for reason in SamplerSchedule.Trigger.allCases { await rig.sampler.trigger(reason) } }
        try await finish(neverOn, "the asks of a sampler that was never turned on")
        XCTAssertEqual(rig.samples.asked, 0, "never turned on")

        try await turnOn(rig)
        rig.sampler.stop()
        let turnedOff = SamplerJob { for reason in SamplerSchedule.Trigger.allCases { await rig.sampler.trigger(reason) } }
        try await finish(turnedOff, "the asks of a sampler that was turned off")
        XCTAssertEqual(rig.samples.asked, 1, "turned off again: only the first note was ever asked for")
        XCTAssertFalse(rig.sampler.isActive)
    }

    func testAVisitThatWasAlreadyOnItsWayWhenItWasTurnedOffDoesNothing() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        rig.sampler.stop()
        let late = SamplerJob { await rig.scheduler.fireLate() }
        try await finish(late, "the late visit")
        XCTAssertEqual(rig.samples.asked, 1)
        XCTAssertEqual(rig.notes.count, 1)
    }

    func testTurningItOffCancelsTheSchedule() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        XCTAssertEqual(rig.scheduler.activities.map(\.isCancelled), [false])
        rig.sampler.stop()
        XCTAssertEqual(rig.scheduler.activities.map(\.isCancelled), [true])
        let visited = await rig.scheduler.fire()
        XCTAssertFalse(visited, "nobody is left to come round")
    }

    func testTurningOffSomethingThatIsOffChangesNothing() {
        let rig = makeRig()
        rig.sampler.stop()
        rig.sampler.stop()
        XCTAssertFalse(rig.sampler.isActive)
        XCTAssertTrue(rig.scheduler.activities.isEmpty)
        XCTAssertTrue(rig.lines.isEmpty)
    }

    func testTurningItOffDropsWhatANoteStillOutBringsBack() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        let visit = SamplerJob { _ = await rig.scheduler.fire() }
        try await waitForAsks(2, rig)

        rig.sampler.stop()
        rig.samples.answer(freeBytes: 999)
        try await finish(visit, "the visit")

        XCTAssertEqual(rig.freeBytesReceived, [100], "the note that came back after it was turned off is not passed on")
        XCTAssertTrue(rig.lines.isEmpty)
        XCTAssertEqual(rig.samples.asked, 2, "and no follow-up")
    }

    func testAFailureThatComesBackAfterItWasTurnedOffIsNotEvenLogged() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        let asking = SamplerJob { await rig.sampler.trigger(.wake) }
        try await waitForAsks(2, rig)
        rig.sampler.stop()
        rig.samples.answer(.failure(.sampleFailed(status: 1, stderr: "late")))
        try await finish(asking, "wake")
        XCTAssertTrue(rig.lines.isEmpty)
    }

    func testTurningItOnAgainSchedulesAgain() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        rig.sampler.stop()

        let starting = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(2, rig)
        rig.samples.answer(freeBytes: 7)
        try await finish(starting, "start()")

        XCTAssertEqual(rig.scheduler.activities.map(\.isCancelled), [true, false])
        XCTAssertTrue(rig.sampler.isActive)
        XCTAssertEqual(rig.freeBytesReceived, [100, 7])

        let visit = SamplerJob { _ = await rig.scheduler.fire() }
        try await waitForAsks(3, rig)
        rig.samples.answer(freeBytes: 8)
        try await finish(visit, "the visit")
        XCTAssertEqual(rig.freeBytesReceived, [100, 7, 8], "the new schedule is the one the system visits")
    }

    func testTurningItOffAndOnAgainWhileANoteIsOutNeverHasTwoOut() async throws {
        let rig = makeRig()
        let first = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)

        rig.sampler.stop()
        let second = SamplerJob { await rig.sampler.start() }
        await settle()
        XCTAssertEqual(rig.samples.asked, 1, "the old note is still out, so the new one waits for it")

        rig.samples.answer(freeBytes: 11)
        try await waitForAsks(2, rig)
        rig.samples.answer(freeBytes: 22)
        try await finish(first, "the first start()")
        try await finish(second, "the second start()")

        XCTAssertEqual(rig.freeBytesReceived, [22], "what the old one brought back belongs to before it was turned off")
        XCTAssertEqual(rig.samples.mostAtOnce, 1)
        XCTAssertEqual(rig.scheduler.activities.map(\.isCancelled), [true, false])
    }

    // MARK: one at a time

    func testAskingWhileANoteIsOutWaitsForItAndMakesOneMoreHoweverManyAsked() async throws {
        let rig = makeRig()
        let first = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)

        var waiting: [SamplerJob] = []
        for reason in [SamplerSchedule.Trigger.wake, .cleaningEnded, .scheduled, .wake, .cleaningEnded] {
            waiting.append(SamplerJob { await rig.sampler.trigger(reason) })
        }
        await settle()
        XCTAssertEqual(rig.samples.asked, 1, "none of them starts a second one")
        XCTAssertFalse(first.isFinished)
        XCTAssertEqual(waiting.filter(\.isFinished).count, 0)

        rig.samples.answer(freeBytes: 1)
        try await waitForAsks(2, rig)
        await settle()
        XCTAssertEqual(rig.samples.asked, 2, "five asks while one was out make one more, not five")
        XCTAssertFalse(first.isFinished, "and everyone waits for that one too")
        XCTAssertEqual(waiting.filter(\.isFinished).count, 0)

        rig.samples.answer(freeBytes: 2)
        try await finish(first, "start()")
        for (index, job) in waiting.enumerated() { try await finish(job, "ask \(index + 1)") }
        XCTAssertEqual(rig.samples.asked, 2)
        XCTAssertEqual(rig.samples.mostAtOnce, 1)
        XCTAssertEqual(rig.freeBytesReceived, [1, 2], "in the order they were taken")
    }

    func testACleaningThatEndsWhileANoteIsOutIsFollowedByANoteThatSeesIt() async throws {
        let rig = makeRig()
        try await turnOn(rig, firstFreeBytes: 10_000_000_000)

        let scheduled = SamplerJob { _ = await rig.scheduler.fire() }
        try await waitForAsks(2, rig)
        let cleaned = SamplerJob { await rig.sampler.trigger(.cleaningEnded) }
        await settle()

        rig.samples.answer(freeBytes: 10_000_000_001)  // read before the cleaning ended
        try await waitForAsks(3, rig)
        rig.samples.answer(freeBytes: 25_000_000_000)  // read after it
        try await finish(scheduled, "the visit")
        try await finish(cleaned, "the cleaning's ask")

        XCTAssertEqual(rig.freeBytesReceived.last, 25_000_000_000, "the last word is the one after the cleaning")
        XCTAssertEqual(rig.samples.mostAtOnce, 1)
    }

    func testAnAskThatComesDuringTheFollowUpGetsItsOwn() async throws {
        let rig = makeRig()
        try await turnOn(rig)

        let first = SamplerJob { await rig.sampler.trigger(.scheduled) }
        try await waitForAsks(2, rig)
        let second = SamplerJob { await rig.sampler.trigger(.wake) }
        await settle()
        rig.samples.answer(freeBytes: 2)
        try await waitForAsks(3, rig)  // the follow-up is out

        let third = SamplerJob { await rig.sampler.trigger(.cleaningEnded) }
        await settle()
        XCTAssertEqual(rig.samples.asked, 3)
        rig.samples.answer(freeBytes: 3)
        try await waitForAsks(4, rig)
        rig.samples.answer(freeBytes: 4)
        try await finish(first, "the first ask")
        try await finish(second, "the second ask")
        try await finish(third, "the third ask")

        XCTAssertEqual(rig.samples.asked, 4)
        XCTAssertEqual(rig.freeBytesReceived, [100, 2, 3, 4])
        XCTAssertEqual(rig.samples.mostAtOnce, 1)
    }

    func testAskingAgainOnceTheLastNoteIsDoneMakesANewOne() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        for round in 2...4 {
            let asking = SamplerJob { await rig.sampler.trigger(.scheduled) }
            try await waitForAsks(round, rig)
            rig.samples.answer(freeBytes: Int64(round))
            try await finish(asking, "ask \(round)")
        }
        await settle()
        XCTAssertEqual(rig.samples.asked, 4, "each ask after a finished note is a note of its own, with no stale follow-up")
        XCTAssertEqual(rig.samples.mostAtOnce, 1)
    }

    // MARK: failures

    func testAFailedNoteIsIgnoredWithOneQuietLine() async throws {
        let rig = makeRig()
        let starting = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)
        rig.samples.answer(.failure(.sampleFailed(status: 1, stderr: "could not read /Users/saint/Library: secret")))
        try await finish(starting, "start()")

        XCTAssertTrue(rig.notes.isEmpty)
        XCTAssertEqual(rig.lines.count, 1, "one line, however it failed")
        let line = try XCTUnwrap(rig.lines.first)
        XCTAssertTrue(line.contains("cmm could not note the free space"), line)
        XCTAssertTrue(line.contains("(start)"), "says what asked: \(line)")
        XCTAssertFalse(line.contains("/"), "no path in the log: \(line)")
        XCTAssertFalse(line.contains("secret"), "nor what cmm printed: \(line)")
        XCTAssertTrue(rig.sampler.isActive, "a failure does not turn it off")
        XCTAssertEqual(rig.scheduler.activities.map(\.isCancelled), [false])
    }

    func testTheNextAskAfterAFailureWorks() async throws {
        let rig = makeRig()
        let starting = SamplerJob { await rig.sampler.start() }
        try await waitForAsks(1, rig)
        rig.samples.answer(.failure(.malformedSample("not json")))
        try await finish(starting, "start()")

        let asking = SamplerJob { await rig.sampler.trigger(.scheduled) }
        try await waitForAsks(2, rig)
        rig.samples.answer(freeBytes: 42)
        try await finish(asking, "the next ask")
        XCTAssertEqual(rig.freeBytesReceived, [42])
        XCTAssertEqual(rig.lines.count, 1, "the second went well and says nothing")
    }

    func testAFailureDoesNotKeepTheSystemWaiting() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        let visit = SamplerJob { _ = await rig.scheduler.fire() }
        try await waitForAsks(2, rig)
        rig.samples.answer(.failure(.sampleFailed(status: 2, stderr: "")))
        try await finish(visit, "the visit after a failure")
        XCTAssertEqual(rig.lines.count, 1, "the body returned, so the system is told the activity is finished")
    }

    func testEveryReasonIsNamedInTheLineForItsFailure() async throws {
        let rig = makeRig()
        try await turnOn(rig)
        for (index, reason) in SamplerSchedule.Trigger.allCases.enumerated() {
            let asking = SamplerJob { await rig.sampler.trigger(reason) }
            try await waitForAsks(index + 2, rig)
            rig.samples.answer(.failure(.sampleFailed(status: 1, stderr: "")))
            try await finish(asking, "\(reason)")
        }
        XCTAssertEqual(rig.lines.count, 4)
        for (line, reason) in zip(rig.lines, SamplerSchedule.Trigger.allCases) {
            XCTAssertTrue(line.contains("(\(reason.rawValue))"), "\(reason): \(line)")
        }
    }

    func testAnErrorThatIsNotCmmsIsLoggedByItsTypeAndNotItsText() async throws {
        let lines = Locked<[String]>([])
        let sampler = SamplerSchedule(
            scheduler: FakeActivityScheduler(),
            sample: { throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such file /Users/saint/secret"]) },
            now: { Date(timeIntervalSince1970: 0) },
            log: { line in lines.withLock { $0.append(line) } }
        )
        let starting = SamplerJob { await sampler.start() }
        try await finish(starting, "start()")
        let written = lines.withLock { $0 }
        XCTAssertEqual(written.count, 1)
        let line = try XCTUnwrap(written.first)
        XCTAssertFalse(line.contains("/"), line)
        XCTAssertFalse(line.contains("secret"), line)
        XCTAssertTrue(line.contains("NSError"), line)
    }

    // MARK: through the client

    func testThroughTheClientItAsksForASampleAndForNothingElse() async throws {
        let fake = FakeCmmClient(plans: [], samples: [.success(SampleResult(recorded: true, t: nil, freeBytes: 77, capacityBytes: nil))])
        let scheduler = FakeActivityScheduler()
        let received = Locked<[Int64]>([])
        let sampler = SamplerSchedule(
            client: fake, scheduler: scheduler, now: { Date(timeIntervalSince1970: 0) },
            onSample: { result, _ in received.withLock { $0.append(result.freeBytes) } },
            log: { _ in }
        )
        let run = SamplerJob {
            await sampler.start()
            _ = await scheduler.fire()
            await sampler.trigger(.wake)
            sampler.stop()
        }
        try await finish(run, "turning it on, a visit and a wake")

        XCTAssertEqual(fake.sampleCalls, 3, "turned on, a visit, a wake")
        XCTAssertEqual(fake.planCalls, 0)
        XCTAssertEqual(fake.historyCalls, 0)
        XCTAssertTrue(fake.applyCalls.isEmpty)
        XCTAssertEqual(fake.stopCalls, 0)
        XCTAssertEqual(received.withLock { $0 }, [77, 77, 77])
    }

    func testAScheduleThatIsLetGoOfIsCancelled() async throws {
        let scheduler = FakeActivityScheduler()
        weak var weakSampler: SamplerSchedule?
        do {
            let sampler = SamplerSchedule(
                client: FakeCmmClient(plans: []), scheduler: scheduler, now: { Date(timeIntervalSince1970: 0) }, log: { _ in }
            )
            weakSampler = sampler
            let starting = SamplerJob { await sampler.start() }
            try await finish(starting, "start()")
            XCTAssertEqual(scheduler.activities.map(\.isCancelled), [false])
        }
        await eventuallyOnMain(timeout: 3) { weakSampler == nil }
        XCTAssertNil(weakSampler, "the schedule does not keep the sampler alive")
        XCTAssertEqual(scheduler.activities.map(\.isCancelled), [true], "and the system stops coming round once it is gone")
    }
}
