import XCTest
@testable import CmmKit

/// The state machine behind the window: idle -> scanning -> ready | empty | failed, and ready -> cleaning ->
/// done | failed. A fake client stands in for cmm.
@MainActor
final class AppModelTests: XCTestCase {
    private var plan: Plan!

    override func setUp() async throws {
        plan = try TestPlans.fixture("plan-v1.json")
    }

    private func readyModel(
        fake: FakeCmmClient? = nil
    ) async -> (AppModel, FakeCmmClient) {
        let fake = fake ?? FakeCmmClient(plan: plan)
        let model = AppModel(client: fake)
        await model.scan()
        return (model, fake)
    }

    private var allPaths: [String] { plan.items.map(\.path) }

    // MARK: scanning

    func testStartsIdleWithNothingInIt() {
        let model = AppModel(client: FakeCmmClient(plan: plan))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.confirmation)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.failure)
    }

    func testScanGoesFromScanningToReadyWithTheSafeItemsTicked() async throws {
        let fake = FakeCmmClient(plan: plan)
        let gate = fake.holdPlans()
        let model = AppModel(client: fake)

        let scanning = Task { await model.scan() }
        await eventuallyOnMain { model.phase == .scanning }
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertNil(model.plan, "nothing to show or clean until the plan is in")

        gate.open()
        await scanning.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.plan, plan)
        XCTAssertEqual(model.selection?.selectedCount, 4)
        XCTAssertEqual(fake.planCalls, 1)
        XCTAssertTrue(fake.applyCalls.isEmpty, "scanning never starts a cleanup")
    }

    func testAPlanWithoutItemsIsTheEmptyStateAndKeepsTheSkipReasons() async throws {
        let (model, _) = await readyModel(fake: FakeCmmClient(plan: try TestPlans.fixture("plan-empty.json")))
        XCTAssertEqual(model.phase, .empty)
        XCTAssertEqual(model.plan?.skipped.map(\.reason), ["go is running", "brew was not found"])
        model.requestClean()
        XCTAssertNil(model.confirmation, "there is nothing to clean")
    }

    func testAFailedScanIsTheErrorStateAndRetryRecovers() async throws {
        let fake = FakeCmmClient(plans: [.failure(.planFailed(status: 2, stderr: "cannot read")), .success(plan)])
        let model = AppModel(client: fake)

        await model.scan()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure?.stage, .scan)
        XCTAssertEqual(model.failure?.title, "cmm could not make a plan")
        XCTAssertTrue(model.failure?.detail.contains("cannot read") == true)
        XCTAssertNil(model.plan)

        await model.scan()  // Retry
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.failure)
    }

    func testCmmNotFoundIsExplainedPlainly() async throws {
        let fake = FakeCmmClient(plans: [.failure(.binaryNotFound(path: "/Applications/Cmm.app/Contents/Resources/cmm"))])
        let model = AppModel(client: fake)
        await model.scan()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure?.title, "cmm was not found")
        XCTAssertTrue(model.failure?.detail.contains("CMM_BIN") == true)
    }

    func testASchemaMismatchTellsThePersonWhatTheAppReads() async throws {
        let model = AppModel(client: FakeCmmClient(plans: [.failure(.unsupportedSchema(found: 2))]))
        await model.scan()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.failure?.detail.contains("this app reads schema 1") == true, model.failure?.detail ?? "")
    }

    func testAnErrorThatIsNotACmmErrorStillGetsAMessage() async throws {
        struct Odd: LocalizedError { var errorDescription: String? { "odd failure" } }
        final class Throwing: CmmClient {
            func plan() async throws -> Plan { throw Odd() }
            func history() async throws -> HistoryReport { throw Odd() }
            func sample() async throws -> SampleResult { throw Odd() }
            func apply(selection: ApplySelection) -> AsyncThrowingStream<ApplyEvent, any Error> { .init { $0.finish() } }
            func stop() {}
        }
        let model = AppModel(client: Throwing())
        await model.scan()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.failure?.detail.contains("odd failure") == true)
    }

    func testRescanReplacesThePlanAndResetsTheTicksToTheDefaults() async throws {
        let (model, fake) = await readyModel()
        let group = try XCTUnwrap(model.selection?.groups.first)
        model.toggle(group)
        XCTAssertEqual(model.selection?.selectedCount, 2)

        await model.scan()

        XCTAssertEqual(fake.planCalls, 2)
        XCTAssertEqual(model.selection?.selectedCount, 4, "a rescan starts from the defaults again")
    }

    func testNoOldPlanSurvivesARescan() async throws {
        let fake = FakeCmmClient(plan: plan)
        let (model, _) = await readyModel(fake: fake)
        XCTAssertNotNil(model.plan)

        let gate = fake.holdPlans()
        let scanning = Task { await model.scan() }
        await eventuallyOnMain { model.phase == .scanning }

        XCTAssertNil(model.plan, "while rescanning, the previous plan is gone")
        XCTAssertNil(model.selection)
        model.requestClean()
        XCTAssertNil(model.confirmation)

        gate.open()
        await scanning.value
    }

    func testAFailedRescanLeavesNoPlanToClean() async throws {
        let fake = FakeCmmClient(plans: [.success(plan), .failure(.planFailed(status: 1, stderr: ""))])
        let (model, _) = await readyModel(fake: fake)
        await model.scan()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.selection)
    }

    func testAScanIsIgnoredWhileOneIsRunning() async throws {
        let fake = FakeCmmClient(plan: plan)
        let gate = fake.holdPlans()
        let model = AppModel(client: fake)
        let first = Task { await model.scan() }
        await eventuallyOnMain { model.phase == .scanning }

        await model.scan()
        XCTAssertEqual(fake.planCalls, 1)

        gate.open()
        await first.value
    }

    // MARK: selecting

    func testTickingChangesTheSelectionWhenReady() async throws {
        let (model, _) = await readyModel()
        let item = try XCTUnwrap(model.selection?.groups.flatMap(\.items).first)
        model.toggle(item)
        XCTAssertEqual(model.selection?.selectedCount, 3)
        XCTAssertEqual(model.selection?.isTicked(item), false)
        let group = try XCTUnwrap(model.selection?.groups.first)
        model.toggle(group)
        XCTAssertEqual(model.selection?.state(of: group), .on)
    }

    func testTickingIsIgnoredWhileTheConfirmationIsOpen() async throws {
        let (model, _) = await readyModel()
        model.requestClean()
        let before = model.selection
        let group = try XCTUnwrap(model.selection?.groups.first)
        model.toggle(group)
        XCTAssertEqual(model.selection, before, "what the sheet names is what will be cleaned")
    }

    // MARK: asking to clean (the sheet)

    func testRequestCleanNamesTheCountAndTheSizeAndStartsNothing() async throws {
        let (model, fake) = await readyModel()
        model.requestClean()

        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.itemCount, 4)
        XCTAssertEqual(confirmation.bytes, 3_081_535_488)
        XCTAssertEqual(confirmation.prompt, "Delete 4 items (3.1 GB)?")
        XCTAssertEqual(confirmation.detail, "Each item is checked again right before it is removed.")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(fake.applyCalls.isEmpty, "asking is not cleaning")
    }

    func testTheSheetSaysItemInTheSingular() async throws {
        let (model, _) = await readyModel()
        for group in model.selection?.groups ?? [] { model.toggle(group) }          // all off
        let single = try XCTUnwrap(model.selection?.groups.first?.items.first)
        model.toggle(single)
        model.requestClean()
        XCTAssertEqual(model.confirmation?.prompt, "Delete 1 item (0.8 GB)?")
    }

    func testRequestCleanWithNothingTickedDoesNothing() async throws {
        let (model, fake) = await readyModel()
        for group in model.selection?.groups ?? [] { model.toggle(group) }
        XCTAssertEqual(model.selection?.selectedCount, 0)
        model.requestClean()
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(fake.applyCalls.isEmpty)
    }

    func testRequestCleanOnlyWorksInTheReadyState() async throws {
        let fake = FakeCmmClient(plans: [.failure(.planFailed(status: 1, stderr: "")), .success(plan)])
        let model = AppModel(client: fake)

        model.requestClean()  // idle
        XCTAssertNil(model.confirmation)

        await model.scan()  // failed
        model.requestClean()
        XCTAssertNil(model.confirmation)

        let gate = fake.holdPlans()
        let scanning = Task { await model.scan() }
        await eventuallyOnMain { model.phase == .scanning }
        model.requestClean()  // scanning
        XCTAssertNil(model.confirmation)
        gate.open()
        await scanning.value
        XCTAssertEqual(model.phase, .ready)
        model.requestClean()
        XCTAssertNotNil(model.confirmation)
    }

    func testRequestCleanDoesNothingWhileCleaningAndAfterwards() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()

        model.requestClean()
        XCTAssertNil(model.confirmation, "no second sheet while cmm is cleaning")

        fake.send(Events.done(deleted: 4))
        fake.finish()
        await cleaning.value
        XCTAssertEqual(model.phase, .done)

        model.requestClean()
        XCTAssertNil(model.confirmation, "and none after it, until a rescan has made a new plan")
        XCTAssertEqual(fake.applyCalls.count, 1)
    }

    func testCancelRunsNothingAndKeepsTheTicks() async throws {
        let (model, fake) = await readyModel()
        let before = model.selection
        model.requestClean()
        model.cancelClean()

        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.selection, before)
        XCTAssertTrue(fake.applyCalls.isEmpty)
    }

    // MARK: confirming

    func testConfirmStartsApplyWithExactlyTheTickedPaths() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.start(selected: 3), Events.done(deleted: 3)], error: nil))
        let (model, _) = await readyModel(fake: fake)
        let brew = try XCTUnwrap(model.selection?.groups.flatMap(\.items).first { $0.action == .command })
        model.toggle(brew)  // untick the Homebrew item

        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(fake.applyCalls.count, 0, "still nothing before the person confirms")
        await model.confirmClean(confirmation)

        XCTAssertEqual(fake.applyCalls.count, 1)
        XCTAssertEqual(fake.applyCalls[0].paths, [
            "/Users/test/Library/Caches/go-build",
            "/Users/test/lane-builds/ios27-scene-cloud-mobile/node_modules",
            "/Users/test/lane-builds/android-widgets/node_modules",
        ])
        XCTAssertEqual(fake.applyCalls[0], confirmation.selection, "what ran is what the sheet named")
        XCTAssertNil(model.confirmation)
    }

    func testAConfirmationIsUsableOnce() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.done(deleted: 4)], error: nil))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)

        await model.confirmClean(confirmation)
        await model.confirmClean(confirmation)  // a replay of the same sheet

        XCTAssertEqual(fake.applyCalls.count, 1)
    }

    func testConfirmWithoutARequestRunsNothing() async throws {
        let (model, fake) = await readyModel()
        let forged = CleanConfirmation(selection: ApplySelection(unchecked: ["/Users/test/Documents"]), generation: 1)
        await model.confirmClean(forged)
        XCTAssertTrue(fake.applyCalls.isEmpty)
        XCTAssertEqual(model.phase, .ready)
    }

    func testAConfirmationThatIsNotTheOneOnScreenRunsNothing() async throws {
        let (model, fake) = await readyModel()
        model.requestClean()
        let genuine = try XCTUnwrap(model.confirmation)
        // Same selection and generation, but not the confirmation the person was shown.
        let lookalike = CleanConfirmation(selection: genuine.selection, generation: genuine.generation)
        await model.confirmClean(lookalike)
        XCTAssertTrue(fake.applyCalls.isEmpty)
        XCTAssertEqual(model.confirmation, genuine, "the real sheet is still waiting for its answer")
    }

    func testAConfirmationFromBeforeARescanRunsNothing() async throws {
        let fake = FakeCmmClient(plan: plan)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let stale = try XCTUnwrap(model.confirmation)

        await model.scan()  // a rescan happened after the sheet was opened
        XCTAssertNil(model.confirmation, "the sheet goes away with the old plan")
        await model.confirmClean(stale)
        XCTAssertTrue(fake.applyCalls.isEmpty)

        model.requestClean()
        let fresh = try XCTUnwrap(model.confirmation)
        XCTAssertNotEqual(fresh, stale)
        await model.confirmClean(stale)  // still refused, even with a new sheet open
        XCTAssertTrue(fake.applyCalls.isEmpty)
    }

    func testTheGenerationOfAConfirmationMustMatchTheCurrentPlan() async throws {
        let (model, fake) = await readyModel()
        model.requestClean()
        let genuine = try XCTUnwrap(model.confirmation)
        model.planGeneration += 1  // as if a plan arrived without the sheet being cleared
        await model.confirmClean(genuine)
        XCTAssertTrue(fake.applyCalls.isEmpty)
    }

    // MARK: cleaning

    func testLiveItemsAndTalliesWhileCleaning() async throws {
        let fake = FakeCmmClient(plan: plan)  // script is .live
        fake.script(.live)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)

        let cleaning = Task { await model.confirmClean(confirmation) }
        let called = await fake.waitForApply()
        XCTAssertTrue(called)
        XCTAssertEqual(model.phase, .cleaning)
        XCTAssertEqual(model.progress.expected, 4)
        XCTAssertTrue(model.progress.items.isEmpty)

        fake.send(Events.start(selected: 4, bytes: 3_081_535_488))
        fake.send(Events.item("/Users/test/Library/Caches/go-build", .deleted, bytes: 927_080_448))
        await eventuallyOnMain { model.progress.items.count == 1 }
        XCTAssertEqual(model.progress.deleted, 1)
        XCTAssertEqual(model.progress.freedBytes, 927_080_448)
        XCTAssertEqual(model.progress.fraction, 0.25, accuracy: 0.0001)

        fake.send(Events.item("/Users/test/a", .skipped, reason: "in use: node (pid 1) has files open"))
        fake.send(Events.item("/Users/test/b", .failed, reason: "permission denied"))
        await eventuallyOnMain { model.progress.items.count == 3 }
        XCTAssertEqual(model.progress.skipped, 1)
        XCTAssertEqual(model.progress.failed, 1)
        XCTAssertEqual(model.progress.items.map(\.status), [.deleted, .skipped, .failed])
        XCTAssertEqual(model.phase, .cleaning, "still running until cmm says done")

        fake.send(Events.done(deleted: 1, skipped: 1, failed: 1, freed: 927_080_448))
        fake.finish()
        await cleaning.value
        XCTAssertEqual(model.phase, .done)
    }

    func testTheConfirmedQueueAndTheStartingNumbersAreKeptForTheCleaningScreen() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()

        XCTAssertEqual(model.progress.queue.map(\.path), confirmation.selection.paths, "the items the person confirmed, in order")
        XCTAssertEqual(model.progress.selectedBytes, 3_081_535_488)
        XCTAssertEqual(model.progress.startFree, 27_633_246_208, "the plan's free space until cmm says its own")

        fake.send(Events.start(selected: 4, bytes: 3_081_535_488, free: 27_000_000_000))
        await eventuallyOnMain { model.progress.selected == 4 }
        XCTAssertEqual(model.progress.startFree, 27_000_000_000)
        XCTAssertEqual(model.progress.inFlight?.path, confirmation.selection.paths.first)

        fake.send(Events.done())
        fake.finish()
        await cleaning.value
    }

    func testReviewBytesThatAreNotTickedStayDottedOnTheBand() async throws {
        let board = try TestPlans.fixture("plan-c.json")
        let fake = FakeCmmClient(plan: board)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        XCTAssertEqual(model.progress.reviewHeld, 9_000_000_000, "Docker was not ticked")
        XCTAssertEqual(model.summary?.reviewHeld, 9_000_000_000)

        let fake2 = FakeCmmClient(plan: board)
        let (model2, _) = await readyModel(fake: fake2)
        model2.toggle(try XCTUnwrap(model2.selection?.groups.first { $0.section == .review }))
        model2.requestClean()
        await model2.confirmClean(try XCTUnwrap(model2.confirmation))
        XCTAssertEqual(model2.progress.reviewHeld, 0, "Docker was ticked, so nothing is held back for review")
        XCTAssertEqual(fake2.applyCalls.first?.count, 12)
    }

    func testTheSummaryRemembersWhenItFinished() async throws {
        let moment = Date(timeIntervalSince1970: 1_792_065_780)
        let fake = FakeCmmClient(plan: plan)
        let model = AppModel(client: fake, now: { moment })
        await model.scan()
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        XCTAssertEqual(model.summary?.finishedAt, moment)
    }

    func testTheConfirmationRemembersTheFreeSpaceItWasAskedAbout() async throws {
        let (model, _) = await readyModel()
        model.requestClean()
        XCTAssertEqual(model.confirmation?.freeBefore, 27_633_246_208)
        XCTAssertEqual(model.confirmation?.afterText, "Free space afterwards: about 30.7 GB.")
    }

    func testTheDoneEventBecomesTheSummary() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([
            Events.start(selected: 4, matched: 4, bytes: 3_081_535_488),
            Events.item("/Users/test/Library/Caches/go-build", .deleted, bytes: 927_080_448),
            Events.item("/Users/test/lane-builds/x/node_modules", .skipped, reason: "in use"),
            Events.done(deleted: 1, skipped: 1, freed: 927_080_448, before: 27_633_246_208,
                        warnings: ["could not write the log"], log: "/Users/test/.local/state/cmm/cleanup.log"),
        ], error: nil))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        XCTAssertEqual(model.phase, .done)
        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.done.deleted, 1)
        XCTAssertEqual(summary.done.skipped, 1)
        XCTAssertEqual(summary.done.failed, 0)
        XCTAssertEqual(summary.done.freedBytes, 927_080_448)
        XCTAssertEqual(summary.done.freeBefore, 27_633_246_208)
        XCTAssertEqual(summary.done.freeAfter, 27_633_246_208 + 927_080_448)
        XCTAssertEqual(summary.done.warnings, ["could not write the log"])
        XCTAssertEqual(summary.done.log, "/Users/test/.local/state/cmm/cleanup.log")
        XCTAssertFalse(summary.stopped)
        XCTAssertEqual(summary.items.count, 2)
        XCTAssertEqual(summary.unreadableLines, 0)
    }

    func testStopAsksTheClientOnceAndTheStoppedSummaryIsShown() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        fake.onStop { fake in
            fake.send(Events.done(deleted: 1, freed: 1_000, stopped: true))
            fake.finish()
        }
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()
        fake.send(Events.item("/Users/test/Library/Caches/go-build"))
        await eventuallyOnMain { model.progress.items.count == 1 }

        model.stop()
        model.stop()  // a second click changes nothing
        XCTAssertEqual(fake.stopCalls, 1)
        XCTAssertTrue(model.progress.stopRequested)

        await cleaning.value
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.summary?.stopped, true)
    }

    func testStopOutsideCleaningDoesNothing() async throws {
        let (model, fake) = await readyModel()
        model.stop()
        XCTAssertEqual(fake.stopCalls, 0)
        XCTAssertFalse(model.progress.stopRequested)
    }

    func testAStreamErrorIsTheErrorStateWithWhatWasSeen() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([
            Events.start(selected: 4),
            Events.item("/Users/test/Library/Caches/go-build", .deleted),
            Events.item("/Users/test/a", .skipped, reason: "in use"),
        ], error: .applyFailed(status: 1, stderr: "cmm: volume went away")))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        XCTAssertEqual(model.phase, .failed)
        let failure = try XCTUnwrap(model.failure)
        XCTAssertEqual(failure.stage, .clean)
        XCTAssertEqual(failure.title, "cmm stopped with an error")
        XCTAssertTrue(failure.detail.contains("volume went away"), failure.detail)
        XCTAssertTrue(failure.detail.contains("1 deleted"), "what was seen so far is said: \(failure.detail)")
        XCTAssertTrue(failure.detail.contains("1 skipped"), failure.detail)
        XCTAssertEqual(model.progress.items.count, 2, "the items seen stay available")
        XCTAssertNil(model.summary)
    }

    func testAStreamThatEndsWithoutADoneEventIsAnError() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.start(selected: 4), Events.item("/Users/test/a")], error: nil))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        XCTAssertEqual(model.phase, .failed, "without cmm's own summary the app does not claim success")
        XCTAssertEqual(model.failure?.title, "cmm ended without a summary")
        XCTAssertNil(model.summary)
    }

    func testStoppingThenLosingTheSummaryIsExplained() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        fake.onStop { fake in fake.finish(throwing: .applyFailed(status: 2, stderr: "cmm was ended by signal 2 (SIGINT).")) }
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()
        model.stop()
        await cleaning.value

        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.failure?.detail.contains("You stopped the cleanup") == true, model.failure?.detail ?? "")
    }

    func testUnreadableLinesAreCountedAndCarriedIntoTheSummary() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([
            Events.start(selected: 1),
            .unreadable("garbage {"),
            Events.item("/Users/test/a", .deleted),
            .unreadable("more garbage"),
            Events.done(deleted: 1),
        ], error: nil))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.summary?.unreadableLines, 2)
    }

    func testTheProgressBarNeverLeavesItsRange() {
        var progress = CleanProgress(expected: 0)
        XCTAssertEqual(progress.fraction, 0, "nothing expected means an empty bar, not a division by zero")

        progress = CleanProgress(expected: 2)
        progress.selected = 2
        for n in 1...5 {  // unmatched paths come back as extra skipped items
            progress.items.append(ItemEvent(
                rule: "", group: "", path: "/p\(n)", status: .skipped, reason: "", bytes: 0, freedBytes: 0
            ))
        }
        XCTAssertEqual(progress.fraction, 1)
    }

    func testAnItemCanArriveBeforeTheStartEvent() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.item("/Users/test/a"), Events.done(deleted: 1)], error: nil))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.summary?.items.count, 1)
    }

    // MARK: after cleaning

    func testRescanAfterDoneStartsOver() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.done(deleted: 4)], error: nil))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        XCTAssertEqual(model.phase, .done)

        await model.scan()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.summary)
        XCTAssertTrue(model.progress.items.isEmpty)
        XCTAssertEqual(fake.planCalls, 2)
    }

    func testRescanAfterAFailedCleanClearsTheError() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([], error: .applyFailed(status: 1, stderr: "x")))
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))
        XCTAssertEqual(model.phase, .failed)
        await model.scan()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.failure)
    }

    func testAScanIsIgnoredWhileCleaning() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()

        await model.scan()
        XCTAssertEqual(fake.planCalls, 1)
        XCTAssertEqual(model.phase, .cleaning)

        fake.send(Events.done(deleted: 4))
        fake.finish()
        await cleaning.value
    }

    func testTickingIsIgnoredWhileCleaning() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()

        let before = model.selection
        model.toggle(try XCTUnwrap(model.selection?.groups.first))
        XCTAssertEqual(model.selection, before)

        fake.send(Events.done())
        fake.finish()
        await cleaning.value
    }

    // MARK: leaving the app

    func testQuittingDuringACleanAsksCmmToStop() async throws {
        let fake = FakeCmmClient(plan: plan)
        fake.script(.live)
        let (model, _) = await readyModel(fake: fake)
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        let cleaning = Task { await model.confirmClean(confirmation) }
        _ = await fake.waitForApply()

        model.shutdown()
        XCTAssertEqual(fake.stopCalls, 1)

        fake.send(Events.done(stopped: true))
        fake.finish()
        await cleaning.value
    }

    func testQuittingWhenIdleDoesNotTouchCmm() async throws {
        let (model, fake) = await readyModel()
        model.shutdown()
        XCTAssertEqual(fake.stopCalls, 0)
    }
}
