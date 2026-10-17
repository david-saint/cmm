import XCTest
@testable import CmmKit

/// The real `ProcessCmmClient` talking to the fake cmm script. Nothing here can delete anything: the fake only
/// prints canned events and records what it was asked.
final class ProcessClientTests: XCTestCase {
    private func everythingInThePlan() throws -> ApplySelection {
        let plan = try TestPlans.fixture("plan-v1.json")
        return ApplySelection(plan: plan, ticked: Set(plan.items.map(\.path)))
    }

    // MARK: plan

    func testPlanReturnsTheDecodedPlan() async throws {
        let fake = try makeFakeCmm()
        let plan = try await fake.client().plan()

        XCTAssertEqual(plan.items.count, 4)
        XCTAssertEqual(plan.host.freeBytes, 27_633_246_208)
        XCTAssertEqual(fake.invocations(), ["plan --json"])
        XCTAssertFalse(fake.processIsAlive())
    }

    func testPlanFailureCarriesTheExitStatusAndStderr() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(mode: "plan-error").plan()
            XCTFail("a failing cmm must not give a plan")
        } catch let CmmError.planFailed(status, stderr) {
            XCTAssertEqual(status, 2)
            XCTAssertTrue(stderr.contains("cannot read the free space"), stderr)
        }
    }

    func testPlanOutputThatIsNotJSONIsMalformed() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(mode: "garbage-plan").plan()
            XCTFail("text is not a plan")
        } catch CmmError.malformedPlan {
            // expected
        }
    }

    func testAPlanOfAnotherSchemaIsRefused() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await fake.client(plan: "plan-schema2.json").plan()
            XCTFail("schema 2 must be refused")
        } catch let error as CmmError {
            XCTAssertEqual(error, .unsupportedSchema(found: 2))
        }
    }

    func testHugeStderrDoesNotBlockTheChild() async throws {
        // 1 MB on stderr is far more than a pipe holds: if nobody read it, cmm would block forever.
        let fake = try makeFakeCmm()
        let plan = try await fake.client(mode: "noisy").plan()
        XCTAssertEqual(plan.items.count, 4)
    }

    func testCancellingAPlanEndsTheProcess() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "plan-hang")
        let task = Task { try await client.plan() }

        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)
        task.cancel()

        let result = await task.result
        guard case .failure = result else { return XCTFail("a cancelled plan must not succeed") }
        let ended = await eventually { !fake.processIsAlive() }
        XCTAssertTrue(ended, "cmm plan must not be left running")
    }

    // MARK: the child process

    func testTheChildGetsTheSpecifiedPATHAndKeepsTheRestOfTheEnvironment() async throws {
        let fake = try makeFakeCmm()
        _ = try await fake.client(environment: ["HOME": "/Users/test-home", "PATH": "/should/be/replaced"]).plan()

        let env = try XCTUnwrap(fake.record("env.txt")).split(separator: "\n")
        XCTAssertTrue(
            env.contains("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
            "a Finder-launched app has a minimal PATH, so the app sets the one the spec names"
        )
        XCTAssertTrue(env.contains("HOME=/Users/test-home"), "everything else is passed on")
        XCTAssertEqual(ProcessCmmClient.defaultPath, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testThePATHCanBeOverriddenForSandboxedRuns() async throws {
        let fake = try makeFakeCmm()
        _ = try await fake.client(path: "/sandbox/bin:/usr/bin:/bin").plan()
        let env = try XCTUnwrap(fake.record("env.txt")).split(separator: "\n")
        XCTAssertTrue(env.contains("PATH=/sandbox/bin:/usr/bin:/bin"))
    }

    func testAMissingBinaryIsReportedWithItsPath() async throws {
        let fake = try makeFakeCmm()
        var configuration = ProcessCmmClient.Configuration()
        configuration.binaryURL = fake.root.appendingPathComponent("no-such-cmm")
        configuration.temporaryDirectory = fake.temporaryFolder
        let client = ProcessCmmClient(configuration: configuration)

        do {
            _ = try await client.plan()
            XCTFail("there is no cmm to run")
        } catch let CmmError.binaryNotFound(path) {
            XCTAssertTrue(path.hasSuffix("no-such-cmm"), path)
        }

        let events = await Task { try? await collect(client.apply(selection: ApplySelection(unchecked: ["/p"]))) }.value
        XCTAssertNil(events, "apply must fail too")
        XCTAssertEqual(fake.leftovers(), [], "no selection file is written when there is nothing to run")
    }

    func testACmmThatCannotBeStartedIsReportedAndLeavesNothingBehind() async throws {
        let fake = try makeFakeCmm()
        try Data("#!/nonexistent/interpreter\n".utf8).write(to: fake.script)  // executable, but cannot run
        let client = fake.client()

        do {
            _ = try await client.plan()
            XCTFail("cannot run")
        } catch CmmError.launchFailed {
            // expected
        }
        do {
            _ = try await collect(client.apply(selection: ApplySelection(unchecked: ["/p"])))
            XCTFail("cannot run")
        } catch CmmError.launchFailed {
            // expected
        }
        XCTAssertEqual(fake.leftovers(), [], "the selection file is removed even when cmm never started")
    }

    // MARK: apply

    func testApplyPassesTheContractArgumentsAndTheSelectionFile() async throws {
        let fake = try makeFakeCmm()
        let selection = try everythingInThePlan()

        _ = try await collect(fake.client().apply(selection: selection))

        let invocation = try XCTUnwrap(fake.invocations().first)
        XCTAssertTrue(invocation.hasPrefix("apply --yes --json --select-file "), invocation)
        let path = try XCTUnwrap(fake.record("selection.path"))
        XCTAssertTrue(path.hasPrefix(fake.temporaryFolder.resolvingSymlinksInPath().path)
            || path.hasPrefix(fake.temporaryFolder.path), "the selection file lives in the app's temporary folder: \(path)")
        let sent = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(fake.record("selection.json")).utf8))
        XCTAssertEqual(sent, selection.paths)
    }

    func testTheSelectionFileHadMode0600ForCmmAndIsGoneAfterwards() async throws {
        let fake = try makeFakeCmm()

        _ = try await collect(fake.client().apply(selection: try everythingInThePlan()))

        XCTAssertEqual(fake.record("selection.mode"), "600", "as cmm saw the file")
        XCTAssertEqual(fake.record("selection.dir.mode"), "700", "as cmm saw its folder")
        let path = try XCTUnwrap(fake.record("selection.path"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(fake.leftovers(), [], "the temporary folder is empty again")
    }

    func testTheSelectionFileIsRemovedAsSoonAsCmmHasReadIt() async throws {
        // Once cmm's `start` event is in, cmm holds the selection in memory, so the file is not needed any more.
        // Removing it then (not only when the run ends) means that quitting the app mid-clean, which ends the app
        // before the client can clean up after the run, leaves nothing behind.
        let fake = try makeFakeCmm()
        var checked = false
        for try await event in fake.client(mode: "slow").apply(selection: try everythingInThePlan()) {
            if event.isItem, !checked {
                checked = true
                XCTAssertTrue(fake.processIsAlive(), "cmm is still running")
                XCTAssertNotNil(fake.record("selection.json"), "and it did read the file")
                XCTAssertEqual(fake.leftovers(), [], "but the selection file is already gone")
                fake.release()
            }
        }
        XCTAssertTrue(checked)
    }

    func testStopBeforeCmmHasStartedRemovesTheSelectionFileAtOnce() async throws {
        // Between launching cmm and its `start` event (it plans again first) the file is still on disk. Stop, and
        // with it quitting, takes it away immediately instead of leaving it for an exit handler that may never run.
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "slow-start")
        let selection = try everythingInThePlan()
        let task = Task { try await collect(client.apply(selection: selection)) }

        let read = await eventually { fake.record("ready") != nil && fake.processIsAlive() }
        XCTAssertNotNil(fake.record("selection.path"))
        XCTAssertTrue(read, "cmm has read the file and is waiting before its start event")
        XCTAssertEqual(fake.leftovers().count, 1, "so the file is still there")

        client.stop()
        XCTAssertEqual(fake.leftovers(), [], "Stop removes it at once, without waiting for cmm to end")

        let result = await task.result
        guard case .failure = result else { return XCTFail("a run stopped before it began has no summary") }
        let ended = await eventually { !fake.processIsAlive() }
        XCTAssertTrue(ended)
        XCTAssertEqual(fake.record("interrupted"), "1")
    }

    func testApplyStreamsStartItemsAndDoneInOrder() async throws {
        let fake = try makeFakeCmm()
        let events = try await collect(fake.client().apply(selection: try everythingInThePlan()))

        XCTAssertEqual(events.count, 6)
        guard case .start(let start) = events[0] else { return XCTFail("first event: \(events[0])") }
        XCTAssertEqual(start.selected, 4)
        XCTAssertEqual(start.matched, 4)
        XCTAssertEqual(events[1...4].compactMap(\.item).map(\.status), [.deleted, .deleted, .deleted, .deleted])
        XCTAssertEqual(events[1...4].compactMap(\.item).map(\.path), try everythingInThePlan().paths)
        let done = try XCTUnwrap(events[5].done)
        XCTAssertEqual(done.deleted, 4)
        XCTAssertEqual(done.freedBytes, 3_081_535_488)
        XCTAssertFalse(done.stopped)
        XCTAssertFalse(fake.processIsAlive())
    }

    func testAPathThatIsNotInTheFreshPlanComesBackAsSkipped() async throws {
        // The contract: a selection can only narrow cmm's own fresh plan. (The app never sends such a path; this
        // documents what cmm does if one ever arrives.)
        let fake = try makeFakeCmm()
        let selection = ApplySelection(unchecked: ["/Users/test/Library/Caches/go-build", "/Users/test/not-in-the-plan"])

        let events = try await collect(fake.client().apply(selection: selection))

        let items = events.compactMap(\.item)
        XCTAssertEqual(items.map(\.status), [.deleted, .skipped])
        XCTAssertEqual(items[1].path, "/Users/test/not-in-the-plan")
        XCTAssertEqual(try XCTUnwrap(events.last?.done).skipped, 1)
    }

    func testAFailedItemStillEndsTheStreamNormally() async throws {
        let fake = try makeFakeCmm()
        // cmm exits with status 1 when an item failed, but it has told the story to the end.
        let events = try await collect(fake.client(mode: "fail-item").apply(selection: try everythingInThePlan()))

        let done = try XCTUnwrap(events.last?.done)
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.deleted, 3)
        XCTAssertEqual(events.compactMap(\.item).filter { $0.status == .failed }.count, 1)
    }

    func testAFatalErrorWithoutASummaryThrowsWithCmmsMessage() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await collect(fake.client(mode: "fatal").apply(selection: try everythingInThePlan()))
            XCTFail("a fatal error must not look like a finished cleanup")
        } catch let CmmError.applyFailed(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("the volume is not mounted"), stderr)
        }
        XCTAssertEqual(fake.leftovers(), [], "the selection file is removed after a fatal error too")
    }

    func testEventsWithoutADoneEventAndExitStatusZeroAreNotASuccess() async throws {
        let fake = try makeFakeCmm()
        var seen: [ApplyEvent] = []
        do {
            for try await event in fake.client(mode: "no-done").apply(selection: try everythingInThePlan()) {
                seen.append(event)
            }
            XCTFail("no summary means the app cannot say what happened")
        } catch let CmmError.endedWithoutSummary(status, _) {
            XCTAssertEqual(status, 0)
        }
        XCTAssertEqual(seen.compactMap(\.item).count, 4, "the items before the end were delivered")
    }

    func testEventsWithoutADoneEventAndAFailureStatusCarryStderr() async throws {
        let fake = try makeFakeCmm()
        do {
            _ = try await collect(fake.client(mode: "no-done-fail").apply(selection: try everythingInThePlan()))
            XCTFail("expected a failure")
        } catch let CmmError.applyFailed(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("lost the plan halfway"), stderr)
        }
    }

    func testABadLineBecomesAnUnreadableEventAndTheRunContinues() async throws {
        let fake = try makeFakeCmm()
        let events = try await collect(fake.client(mode: "bad-line").apply(selection: try everythingInThePlan()))

        XCTAssertEqual(events.filter(\.isUnreadable).count, 1)
        XCTAssertEqual(events.compactMap(\.item).count, 4)
        XCTAssertNotNil(events.last?.done)
    }

    func testBigOutputAndHugeStderrDoNotDeadlock() async throws {
        let fake = try makeFakeCmm()
        let events = try await collect(fake.client(mode: "big").apply(selection: try everythingInThePlan()))
        XCTAssertEqual(events.compactMap(\.item).count, 5000)
        XCTAssertEqual(events.last?.done?.deleted, 5000)

        let noisy = try await collect(fake.client(mode: "noisy").apply(selection: try everythingInThePlan()))
        XCTAssertNotNil(noisy.last?.done)
    }

    // MARK: incremental delivery, stop and cancellation

    func testEventsArriveWhileCmmIsStillRunning() async throws {
        let fake = try makeFakeCmm()
        var events: [ApplyEvent] = []
        var firstItemSeenWhileRunning = false

        // In `slow` mode the fake holds still after its first item until the test releases it. If the client only
        // delivered events after the process ended, this loop would see nothing until the fake gave up.
        for try await event in fake.client(mode: "slow").apply(selection: try everythingInThePlan()) {
            events.append(event)
            if event.isItem, !firstItemSeenWhileRunning {
                firstItemSeenWhileRunning = fake.processIsAlive() && !events.contains(where: \.isDone)
                fake.release()
            }
        }
        XCTAssertTrue(firstItemSeenWhileRunning, "the first item must arrive before cmm has finished")
        XCTAssertEqual(events.last?.done?.deleted, 4)
    }

    func testStopSendsSIGINTAndCmmEndsWithDoneStopped() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "slow")
        var events: [ApplyEvent] = []

        for try await event in client.apply(selection: try everythingInThePlan()) {
            events.append(event)
            if event.isItem, events.compactMap(\.item).count == 1 {
                client.stop()
            }
        }

        let done = try XCTUnwrap(events.last?.done)
        XCTAssertTrue(done.stopped)
        XCTAssertEqual(done.deleted, 1, "cmm stops after the item in progress")
        XCTAssertEqual(fake.record("interrupted"), "1")
        XCTAssertFalse(fake.processIsAlive())
        XCTAssertEqual(fake.leftovers(), [])
    }

    func testCancellingTheConsumerInterruptsCmmAndCleansUp() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "slow")
        let selection = try everythingInThePlan()
        let sawItem = Locked(false)

        let task = Task {
            for try await event in client.apply(selection: selection) where event.isItem {
                sawItem.withLock { $0 = true }
            }
        }
        let gotItem = await eventually { sawItem.withLock { $0 } }
        XCTAssertTrue(gotItem)

        task.cancel()

        let ended = await eventually { !fake.processIsAlive() }
        XCTAssertTrue(ended, "cmm must not be left running when the app stops listening")
        XCTAssertEqual(fake.record("interrupted"), "1", "it is asked to stop cleanly (SIGINT), not killed")
        let cleaned = await eventually { fake.leftovers().isEmpty }
        XCTAssertTrue(cleaned)
        _ = await task.result
    }

    func testStopWhenNothingIsRunningIsHarmless() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client()
        client.stop()
        _ = try await client.plan()
        client.stop()  // the process has ended; there is nothing to signal
        _ = try await collect(client.apply(selection: try everythingInThePlan()))
        client.stop()
    }

    func testASecondRunWhileOneIsActiveIsRefused() async throws {
        let fake = try makeFakeCmm()
        let client = fake.client(mode: "slow")
        let selection = try everythingInThePlan()
        let applying = Task { try await collect(client.apply(selection: selection)) }

        let started = await eventually { fake.processIsAlive() }
        XCTAssertTrue(started)
        do {
            _ = try await client.plan()
            XCTFail("one cmm at a time")
        } catch let error as CmmError {
            XCTAssertEqual(error, .busy)
        }

        fake.release()
        let events = try await applying.value
        XCTAssertNotNil(events.last?.done)
        _ = try await client.plan()  // and the client is usable again afterwards
    }
}

final class BinaryResolutionTests: XCTestCase {
    private func executable(named name: String = "cmm", in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func client(
        explicit: URL? = nil,
        appEnvironment: [String: String] = [:],
        resources: URL? = nil
    ) -> ProcessCmmClient {
        var configuration = ProcessCmmClient.Configuration()
        configuration.binaryURL = explicit
        configuration.appEnvironment = appEnvironment
        configuration.resourceDirectory = resources
        return ProcessCmmClient(configuration: configuration)
    }

    func testTheCopyInsideTheBundleIsUsedByDefault() throws {
        let resources = try makeTempDirectory()
        let bundled = try executable(in: resources)
        XCTAssertEqual(try client(resources: resources).resolveBinary().path, bundled.path)
    }

    func testCMM_BINOverridesTheBundledCopy() throws {
        let resources = try makeTempDirectory()
        _ = try executable(in: resources)
        let dev = try executable(named: "cmm-dev", in: try makeTempDirectory())
        let resolved = try client(appEnvironment: ["CMM_BIN": dev.path], resources: resources).resolveBinary()
        XCTAssertEqual(resolved.path, dev.path)
    }

    func testAnExplicitURLBeatsEverything() throws {
        let resources = try makeTempDirectory()
        _ = try executable(in: resources)
        let explicit = try executable(named: "explicit", in: try makeTempDirectory())
        let resolved = try client(explicit: explicit, appEnvironment: ["CMM_BIN": "/nope"], resources: resources).resolveBinary()
        XCTAssertEqual(resolved.path, explicit.path)
    }

    func testACMM_BINThatDoesNotExistIsAnErrorNotASilentFallback() throws {
        let resources = try makeTempDirectory()
        _ = try executable(in: resources)
        XCTAssertThrowsError(try client(appEnvironment: ["CMM_BIN": "/no/such/cmm"], resources: resources).resolveBinary()) {
            XCTAssertEqual($0 as? CmmError, .binaryNotFound(path: "/no/such/cmm"))
        }
    }

    func testAnEmptyCMM_BINIsIgnored() throws {
        let resources = try makeTempDirectory()
        let bundled = try executable(in: resources)
        XCTAssertEqual(try client(appEnvironment: ["CMM_BIN": ""], resources: resources).resolveBinary().path, bundled.path)
    }

    func testNothingToRunIsAnError() throws {
        XCTAssertThrowsError(try client(resources: try makeTempDirectory()).resolveBinary()) {
            guard case .binaryNotFound? = $0 as? CmmError else { return XCTFail("got \($0)") }
        }
        XCTAssertThrowsError(try client(resources: nil).resolveBinary())
    }

    func testAFolderOrAFileWithoutTheExecuteBitIsNotACmm() throws {
        let folder = try makeTempDirectory()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("cmm"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try client(resources: folder).resolveBinary(), "a folder named cmm")

        let plain = try makeTempDirectory()
        try Data("data".utf8).write(to: plain.appendingPathComponent("cmm"))
        XCTAssertThrowsError(try client(resources: plain).resolveBinary(), "a file that is not executable")
    }
}
