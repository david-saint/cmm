import Foundation
@testable import CmmKit

/// A `CmmClient` that never starts anything. Plans are scripted, `apply` either replays a script or hands the test
/// a live stream to push events into, and every call is recorded so tests can say what was (not) asked of cmm.
final class FakeCmmClient: CmmClient, @unchecked Sendable {
    /// Holds a `plan()` call until the test opens it, so the "scanning" state can be observed.
    final class Gate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream<Void>.makeStream()
        }

        func wait() async {
            for await _ in stream { return }
        }

        func open() {
            continuation.yield(())
            continuation.finish()
        }
    }

    enum ApplyScript {
        /// `apply` returns a stream the test feeds with `send` and ends with `finish` (ask for it with `script(.live)`).
        case live
        /// `apply` replays these events at once and then ends (throwing `error` if given).
        case replay([ApplyEvent], error: CmmError?)
    }

    private struct State {
        var planResults: [Result<Plan, CmmError>]
        var planCalls = 0
        var planGate: Gate?
        var historyResults: [Result<HistoryReport, CmmError>]
        var historyCalls = 0
        var historyGate: Gate?
        var sampleResults: [Result<SampleResult, CmmError>]
        var sampleCalls = 0
        var sampleGate: Gate?
        var applyCalls: [ApplySelection] = []
        var stopCalls = 0
        // Ends at once by default: a test that wrongly starts a cleanup then fails on its assertion instead of
        // hanging on a stream nobody feeds. Tests that drive events by hand ask for `.live`.
        var applyScript = ApplyScript.replay([Events.done()], error: nil)
        var liveContinuation: AsyncThrowingStream<ApplyEvent, any Error>.Continuation?
        var onStop: (@Sendable (FakeCmmClient) -> Void)?
    }

    private let state: Locked<State>

    /// A history with nothing in it, and a sample that was recorded: what the fake answers unless it is told otherwise.
    static let emptyHistory = HistoryReport(
        schemaVersion: 1, generatedAt: nil, host: HistoryHost(volume: "/", freeBytes: nil, capacityBytes: nil),
        runs: [], samples: [], unreadableLines: 0, ignoredEntries: 0
    )
    static let recordedSample = SampleResult(recorded: true, t: nil, freeBytes: 20_000_000_000, capacityBytes: nil)

    init(
        plans: [Result<Plan, CmmError>],
        histories: [Result<HistoryReport, CmmError>] = [.success(FakeCmmClient.emptyHistory)],
        samples: [Result<SampleResult, CmmError>] = [.success(FakeCmmClient.recordedSample)]
    ) {
        state = Locked(State(planResults: plans, historyResults: histories, sampleResults: samples))
    }

    convenience init(plan: Plan) {
        self.init(plans: [.success(plan)])
    }

    // MARK: scripting

    func holdPlans() -> Gate {
        let gate = Gate()
        state.withLock { $0.planGate = gate }
        return gate
    }

    func holdHistories() -> Gate {
        let gate = Gate()
        state.withLock { $0.historyGate = gate }
        return gate
    }

    func holdSamples() -> Gate {
        let gate = Gate()
        state.withLock { $0.sampleGate = gate }
        return gate
    }

    func script(_ script: ApplyScript) {
        state.withLock { $0.applyScript = script }
    }

    /// What the fake does when `stop()` is called (a real cmm would end its run with a `done` event).
    func onStop(_ reaction: @escaping @Sendable (FakeCmmClient) -> Void) {
        state.withLock { $0.onStop = reaction }
    }

    func send(_ event: ApplyEvent) {
        state.withLock { $0.liveContinuation }?.yield(event)
    }

    func finish(throwing error: CmmError? = nil) {
        state.withLock { $0.liveContinuation }?.finish(throwing: error)
    }

    // MARK: what was asked

    var planCalls: Int { state.withLock { $0.planCalls } }
    var historyCalls: Int { state.withLock { $0.historyCalls } }
    var sampleCalls: Int { state.withLock { $0.sampleCalls } }
    var applyCalls: [ApplySelection] { state.withLock { $0.applyCalls } }
    var stopCalls: Int { state.withLock { $0.stopCalls } }

    /// Waits until `apply` has been called (live scripts only).
    func waitForApply(timeout: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.withLock({ $0.liveContinuation != nil }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: CmmClient

    func plan() async throws -> Plan {
        let gate = state.withLock { state -> Gate? in
            state.planCalls += 1
            return state.planGate
        }
        await gate?.wait()
        return try state.withLock { state in
            let result = state.planResults.count > 1 ? state.planResults.removeFirst() : state.planResults[0]
            return try result.get()
        }
    }

    func history() async throws -> HistoryReport {
        let gate = state.withLock { state -> Gate? in
            state.historyCalls += 1
            return state.historyGate
        }
        await gate?.wait()
        return try state.withLock { state in
            let result = state.historyResults.count > 1 ? state.historyResults.removeFirst() : state.historyResults[0]
            return try result.get()
        }
    }

    func sample() async throws -> SampleResult {
        let gate = state.withLock { state -> Gate? in
            state.sampleCalls += 1
            return state.sampleGate
        }
        await gate?.wait()
        return try state.withLock { state in
            let result = state.sampleResults.count > 1 ? state.sampleResults.removeFirst() : state.sampleResults[0]
            return try result.get()
        }
    }

    func apply(selection: ApplySelection) -> AsyncThrowingStream<ApplyEvent, any Error> {
        let script = state.withLock { state -> ApplyScript in
            state.applyCalls.append(selection)
            return state.applyScript
        }
        return AsyncThrowingStream { continuation in
            switch script {
            case .live:
                state.withLock { $0.liveContinuation = continuation }
            case .replay(let events, let error):
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: error)
            }
        }
    }

    func stop() {
        let reaction = state.withLock { state -> (@Sendable (FakeCmmClient) -> Void)? in
            state.stopCalls += 1
            return state.onStop
        }
        reaction?(self)
    }
}

/// Events for scripts, so tests read as stories.
enum Events {
    static func start(selected: Int, matched: Int? = nil, bytes: Int64 = 0, free: Int64 = 20_000_000_000) -> ApplyEvent {
        .start(StartEvent(selected: selected, matched: matched ?? selected, bytes: bytes, freeBytes: free))
    }

    static func item(
        _ path: String,
        _ status: ItemStatus = .deleted,
        bytes: Int64 = 1_000,
        reason: String = "",
        freesInside: String? = nil
    ) -> ApplyEvent {
        .item(ItemEvent(
            rule: "rule", group: "Group", path: path, status: status, reason: reason,
            bytes: bytes, freedBytes: status == .deleted ? bytes : 0, freesInside: freesInside
        ))
    }

    /// `freed` is what the volume got back; `freedInside` what was freed inside another program's storage.
    static func done(
        deleted: Int = 0, skipped: Int = 0, failed: Int = 0, freed: Int64 = 0, freedInside: Int64 = 0,
        before: Int64 = 20_000_000_000, stopped: Bool = false, warnings: [String] = [], log: String? = nil
    ) -> ApplyEvent {
        .done(DoneEvent(
            deleted: deleted, skipped: skipped, failed: failed, freedBytes: freed, freedInsideBytes: freedInside,
            freeBefore: before, freeAfter: before + freed, stopped: stopped, warnings: warnings, log: log
        ))
    }
}

/// Polls a main-actor condition until it holds or the time is up.
@MainActor
@discardableResult
func eventuallyOnMain(timeout: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
