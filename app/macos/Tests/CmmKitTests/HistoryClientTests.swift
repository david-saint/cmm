import XCTest
@testable import CmmKit

/// `history()` and `sample()` of the real `ProcessCmmClient`, talking to the fake cmm script: the arguments cmm is given,
/// what comes back, how it fails, and that neither can ever get in the way of a scan or a cleanup. Nothing here can delete
/// anything: the fake only prints canned output and records what it was asked.
final class HistoryClientTests: XCTestCase {
    // MARK: history

    func testHistoryAsksForEverythingOverNinetyDaysAndReturnsTheDecodedReport() async throws {
        let fake = try makeFakeCmm()
        let report = try await fake.client().history()

        XCTAssertEqual(fake.invocations(), ["history --json --limit 0 --days 90"])
        XCTAssertEqual(report.runs.count, 1)
        XCTAssertEqual(report.runs.first?.freedBytes, 4_642_000_000)
        XCTAssertEqual(report.samples.count, 3)
        XCTAssertEqual(report.host.freeBytes, 24_000_000_000)
        XCTAssertFalse(fake.processIsAlive())
    }

    func testHistoryFailureCarriesTheExitStatusAndStderr() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(mode: "history-error").history()
            XCTFail("a failing cmm must not give a history")
        } catch let CmmError.historyFailed(status, stderr) {
            XCTAssertEqual(status, 2)
            XCTAssertTrue(stderr.contains("permission denied"), stderr)
        }
    }

    func testHistoryOutputThatIsNotJSONIsMalformed() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(mode: "garbage-history").history()
            XCTFail("text is not a history")
        } catch CmmError.malformedHistory {
            // expected
        }
    }

    func testAHistoryOfAnotherSchemaIsRefused() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(history: "history-schema2.json").history()
            XCTFail("schema 2 must be refused")
        } catch let error as CmmError {
            XCTAssertEqual(error, .unsupportedHistorySchema(found: 2))
        }
    }

    func testHugeStderrDoesNotBlockTheChild() async throws {
        // 1 MB on stderr is far more than a pipe holds: if nobody read it, cmm would block for ever.
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "noisy")
        let report = try await client.history()
        XCTAssertEqual(report.runs.count, 1)
        let sample = try await client.sample()
        XCTAssertTrue(sample.recorded)
    }

    func testAHistoryThatNeverAnswersIsEndedAfterTheTimeoutAndSaysSo() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "quick-hang", quickCommandTimeout: 0.3)
        let started = Date()
        do {
            _ = try await client.history()
            XCTFail("a cmm that does not answer is an error")
        } catch let CmmError.historyFailed(_, stderr) {
            XCTAssertTrue(stderr.contains("cmm did not answer within 1 second."), stderr)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout, not the fake's own 20 s, ended it")
        let ended = await eventually { !fake.processIsAlive() }
        XCTAssertTrue(ended, "cmm history must not be left running")
    }

    func testCancellingAHistoryEndsTheProcess() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "quick-hang")
        let task = Task { try await client.history() }

        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)
        task.cancel()

        let result = await task.result
        guard case .failure = result else { return XCTFail("a cancelled history must not succeed") }
        let ended = await eventually { !fake.processIsAlive() }
        XCTAssertTrue(ended, "cmm history must not be left running")
    }

    // MARK: sample

    func testSampleAsksForOneLineOfJSONAndReturnsIt() async throws {
        let fake = try makeFakeCmm()
        let result = try await fake.client().sample()

        XCTAssertEqual(fake.invocations(), ["sample --json"])
        XCTAssertEqual(result, SampleResult(
            recorded: true, t: TestTime.utc("2026-10-15T09:00:00Z"), freeBytes: 24_000_000_000, capacityBytes: 245_107_195_904
        ))
        XCTAssertFalse(fake.processIsAlive())
    }

    func testASampleThatWasNotDueIsAnAnswerNotAnError() async throws {
        let fake = try makeFakeCmm()
        let result = try await fake.client(sample: #"{"recorded":false,"t":"2026-10-15T09:00:00Z","free_bytes":24000000000}"#).sample()
        XCTAssertFalse(result.recorded)
        XCTAssertEqual(result.freeBytes, 24_000_000_000)
    }

    func testSampleFailureCarriesTheExitStatusAndStderr() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(mode: "sample-error").sample()
            XCTFail("a failing cmm must not give a sample")
        } catch let CmmError.sampleFailed(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("permission denied"), stderr)
        }
    }

    func testSampleOutputThatIsNotJSONIsMalformed() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(mode: "garbage-sample").sample()
            XCTFail("text is not a sample")
        } catch CmmError.malformedSample {
            // expected
        }
    }

    func testASampleThatNeverAnswersIsEndedAfterTheTimeout() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "quick-hang", quickCommandTimeout: 0.3)
        do {
            _ = try await client.sample()
            XCTFail("a cmm that does not answer is an error")
        } catch let CmmError.sampleFailed(_, stderr) {
            XCTAssertTrue(stderr.contains("cmm did not answer within 1 second."), stderr)
        }
        let ended = await eventually { !fake.processIsAlive() }
        XCTAssertTrue(ended, "cmm sample must not be left running")
    }

    func testTheTimeoutIsSaidInWholeSecondsRoundedUp() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "quick-hang", quickCommandTimeout: 1.2)
        do {
            _ = try await client.sample()
            XCTFail("a cmm that does not answer is an error")
        } catch let CmmError.sampleFailed(_, stderr) {
            XCTAssertTrue(stderr.contains("cmm did not answer within 2 seconds."), stderr)
        }
    }

    // MARK: how much cmm may print

    func testARealisticallyLongHistoryIsNotTooBig() async throws {
        // ninety days of notes every half hour is about 4,300; this is nearly five times that, a megabyte and a half
        let fake = try makeFakeCmm()
        let report = try await fake.client(mode: "big-history", environment: ["FAKE_CMM_SAMPLES": "20000"]).history()
        XCTAssertEqual(report.samples.count, 20_000)
        XCTAssertEqual(report.ignoredEntries, 0)
        XCTAssertEqual(report.host.freeBytes, 24_000_000_000)
    }

    func testTheLimitsOnWhatCmmMayPrintAreTheOnesTheDocumentationStates() {
        XCTAssertEqual(ProcessCmmClient.maxHistoryBytes, 64 * 1024 * 1024, "cmm reads at most 8 MB of each history file")
        XCTAssertEqual(ProcessCmmClient.maxSampleBytes, 64 * 1024, "a note of the free space is one short line")
    }

    func testASampleOfExactlyTheLimitIsNotTooBigAndOneByteMoreIs() async throws {
        let fake = try makeFakeCmm()
        let limit = ProcessCmmClient.maxSampleBytes
        do {
            _ = try await fake.client(mode: "big-output", environment: ["FAKE_CMM_BYTES": "\(limit)"]).sample()
            XCTFail("text is not a note")
        } catch let CmmError.malformedSample(why) {
            XCTAssertFalse(why.contains("printed more than"), "exactly the limit is allowed: \(why)")
        }
        do {
            _ = try await fake.client(mode: "big-output", environment: ["FAKE_CMM_BYTES": "\(limit + 1)"]).sample()
            XCTFail("text is not a note")
        } catch let CmmError.malformedSample(why) {
            XCTAssertEqual(why, "cmm printed more than 64 KB, which is not a note of the free space")
        }
    }

    func testAMissingBinaryIsReportedForBothCommands() async throws {
        let fake = try makeFakeCmm()
        var configuration = ProcessCmmClient.Configuration()
        configuration.binaryURL = fake.root.appendingPathComponent("no-such-cmm")
        let client = ProcessCmmClient(configuration: configuration)
        do {
            _ = try await client.history()
            XCTFail("there is no cmm to run")
        } catch CmmError.binaryNotFound {}
        do {
            _ = try await client.sample()
            XCTFail("there is no cmm to run")
        } catch CmmError.binaryNotFound {}
    }

    // MARK: they never get in the way of a scan or a cleanup

    func testASampleAndAHistoryWhileAScanIsRunningFailNeitherThemNorTheScan() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "plan-hang")
        let scanning = Task { try await client.plan() }
        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)

        let sample = try await client.sample()  // the one slot of plan and apply is not theirs
        let report = try await client.history()
        XCTAssertTrue(sample.recorded)
        XCTAssertEqual(report.runs.count, 1)

        fake.release()
        _ = await scanning.result
    }

    func testASampleWhileACleanupIsRunningDoesNotMakeTheCleanupFail() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "slow")
        let plan = try TestPlans.fixture("plan-v1.json")
        let selection = ApplySelection(plan: plan, ticked: Set(plan.items.map(\.path)))
        let applying = Task { try await collect(client.apply(selection: selection)) }
        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)

        let sample = try await client.sample()
        XCTAssertTrue(sample.recorded)

        fake.release()
        let events = try await applying.value
        XCTAssertNotNil(events.last?.done)
    }

    func testAQuickCommandNeverTakesThePlansSlot() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "quick-hang")
        let sampling = Task { try await client.sample() }
        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)

        let plan = try await client.plan()  // would be `busy` if the sample held the one slot
        XCTAssertEqual(plan.items.count, 4)

        fake.release()
        _ = await sampling.result
    }

    func testStopReachesAScanOrACleanupAndNeverAQuickCommand() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "quick-hang")
        let sampling = Task { try await client.sample() }
        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)

        client.stop()  // the person pressed Stop: that is about a cleanup, and there is none
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fake.processIsAlive(), "stop() is about the plan or the apply that runs, not a sample")

        fake.release()
        _ = await sampling.result
    }

    func testTwoQuickCommandsMayRunAtOnce() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client()
        async let first = client.history()
        async let second = client.history()
        async let third = client.sample()
        let (a, b, c) = try await (first, second, third)
        XCTAssertEqual(a, b)
        XCTAssertTrue(c.recorded)
    }
}
