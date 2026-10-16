import XCTest
@testable import CmmKit

/// Space that a cleaning frees *inside* another program's own storage (Docker's disk image) is not space the disk gets
/// back, so no number that promises free space may include it: the rest caption, the card's "afterwards", the band's
/// green slice and the cleaning and done screens all count the disk's share only, and say the rest apart, once.
///
/// What is removed is still what is removed: the pill and the card's "Delete N items (X GB)?" count everything.
@MainActor
final class InsideTests: XCTestCase {
    private let docker = "Docker's disk image"

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }
    private func inside(_ place: String, _ value: Double) -> InsideBytes { InsideBytes(place: place, bytes: gb(value)) }

    private func board() throws -> SelectionModel {
        SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
    }

    private func rest(_ selection: SelectionModel) -> RestCopy {
        RestCopy(selection: selection, volumeName: "Macintosh HD")
    }

    // MARK: decoding

    func testAPlanItemMayNameWhereItsSpaceGoes() throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let dockerItems = plan.items.filter { $0.rule == "docker" }
        XCTAssertEqual(dockerItems.count, 3)
        XCTAssertTrue(dockerItems.allSatisfy { $0.freesInside == docker })
        XCTAssertTrue(plan.items.filter { $0.rule != "docker" }.allSatisfy { $0.freesInside == nil }, "the disk gets the rest")
    }

    func testOlderPlansSimplyLackTheField() throws {
        XCTAssertTrue(try TestPlans.fixture("plan-v1.json").items.allSatisfy { $0.freesInside == nil })
        XCTAssertTrue(try TestPlans.fixture("plan-mixed-tiers.json").items.allSatisfy { $0.freesInside == nil })
    }

    func testAnItemEventRepeatsItAndTheDoneEventSplitsWhatWasFreed() throws {
        var parser = NDJSONParser()
        let events = parser.feed(try Fixture.data("apply-events-inside.ndjson")) + parser.finish()
        XCTAssertEqual(events.count, 4)

        guard case .item(let goBuild) = events[1], case .item(let images) = events[2], case .done(let done) = events[3] else {
            return XCTFail("start, item, item, done: \(events)")
        }
        XCTAssertNil(goBuild.freesInside)
        XCTAssertEqual(images.freesInside, docker)
        XCTAssertEqual(images.freedBytes, gb(6.2))
        XCTAssertEqual(done.freedBytes, gb(1.2), "only what the volume got back")
        XCTAssertEqual(done.freedInsideBytes, gb(6.2))
        XCTAssertEqual(done.freeAfter, gb(21.0))
    }

    func testAnOlderDoneEventHasNothingInside() throws {
        var parser = NDJSONParser()
        let events = parser.feed(try Fixture.data("apply-events.ndjson")) + parser.finish()
        guard case .done(let done) = events.last, case .item(let first) = events[1] else { return XCTFail("\(events)") }
        XCTAssertEqual(done.freedInsideBytes, 0)
        XCTAssertNil(first.freesInside)
    }

    // MARK: the words

    func testTheRestLineSaysItOnceAndQuietly() {
        XCTAssertEqual(Inside.restLine([inside(docker, 6.2)]), "+ 6.2 GB inside Docker's disk image, not counted above.")
        XCTAssertNil(Inside.restLine([]))
        XCTAssertNil(Inside.restLine([inside(docker, 0)]), "nothing inside, nothing to say")
    }

    func testTheCleaningLineIsShorter() {
        XCTAssertEqual(Inside.cleaningLine([inside(docker, 2.1)]), "+ 2.1 GB inside Docker's disk image")
        XCTAssertNil(Inside.cleaningLine([]))
    }

    func testTheCardSentence() {
        XCTAssertEqual(
            Inside.cardSentence([inside(docker, 6.2)]),
            "6.2 GB is freed inside Docker's disk image.\nThe disk shows it later, if at all."
        )
        XCTAssertNil(Inside.cardSentence([]))
    }

    func testTheDoneSentence() {
        XCTAssertEqual(
            Inside.doneSentence([inside(docker, 6.2)]),
            "6.2 GB was freed inside Docker's disk image; the disk shows it when that space is given back."
        )
        XCTAssertNil(Inside.doneSentence([]))
    }

    func testTwoPlacesAreJoinedInTheOrderTheyAppear() {
        let places = [inside(docker, 6.2), inside("Foo's cache", 1.0)]
        XCTAssertEqual(
            Inside.restLine(places), "+ 6.2 GB inside Docker's disk image and 1.0 GB inside Foo's cache, not counted above."
        )
        XCTAssertEqual(
            Inside.cardSentence(places),
            "6.2 GB is freed inside Docker's disk image and 1.0 GB inside Foo's cache.\nThe disk shows it later, if at all."
        )
        XCTAssertEqual(Inside.total(places), gb(7.2))
    }

    func testNoPlaceIsEverHardCoded() {
        let other = [inside("Some VM's disk file", 3.0)]
        XCTAssertEqual(Inside.restLine(other), "+ 3.0 GB inside Some VM's disk file, not counted above.")
        XCTAssertFalse(Inside.cardSentence(other)?.contains("Docker") ?? true)
        XCTAssertFalse(Inside.doneSentence(other)?.contains("Docker") ?? true)
    }

    func testTheSameNameAddsUpAndTheEmptyNameFallsBackToAGenericOne() {
        var list: [InsideBytes] = []
        Inside.add(gb(1), to: docker, in: &list)
        Inside.add(gb(2), to: "Other", in: &list)
        Inside.add(gb(3), to: docker, in: &list)
        XCTAssertEqual(list, [inside(docker, 4), inside("Other", 2)])
        XCTAssertEqual(Inside.fallbackPlace, "another program's own storage")
    }

    // MARK: the selection

    func testTheSelectionSplitsWhatTheDiskGetsFromWhatStaysInside() throws {
        var selection = try board()
        XCTAssertEqual(selection.selectedBytes, gb(8.4))
        XCTAssertEqual(selection.selectedVolumeBytes, gb(8.4))
        XCTAssertTrue(selection.selectedInside.isEmpty)

        let images = try XCTUnwrap(selection.groups.first { $0.section == .review }?.items.first)  // 6.2 GB
        selection.toggle(images)
        XCTAssertEqual(selection.selectedBytes, gb(14.6), "everything that will be removed")
        XCTAssertEqual(selection.selectedVolumeBytes, gb(8.4), "but the disk gets only the rest")
        XCTAssertEqual(selection.selectedInside, [inside(docker, 6.2)])
        XCTAssertEqual(selection.selectedInsideBytes, gb(6.2))
    }

    func testTheDottedBandKeepsTickedInsideItems() throws {
        var selection = try board()
        XCTAssertEqual(selection.reviewDottedBytes, gb(9.0))
        let group = try XCTUnwrap(selection.groups.first { $0.section == .review })
        selection.toggle(group.items[0])
        XCTAssertEqual(selection.reviewDottedBytes, gb(9.0), "a ticked item that frees space inside stays dotted")

        // A review item the disk does get back turns green as soon as it is ticked.
        let plan = TestPlans.plan([
            TestPlans.item("/a", rule: "go-build", bytes: gb(1)),
            TestPlans.item("/r", group: "Review", rule: "other", bytes: gb(4), tier: .review),
            TestPlans.item("docker: x", group: "Review", rule: "docker", bytes: gb(2), tier: .review, action: .command, freesInside: docker),
        ], capacityBytes: gb(100))
        var mixed = SelectionModel(plan: plan)
        XCTAssertEqual(mixed.reviewDottedBytes, gb(6))
        mixed.toggle(try XCTUnwrap(mixed.groups.first { $0.section == .review }?.items.first { $0.path == "/r" }))
        XCTAssertEqual(mixed.reviewDottedBytes, gb(2), "only the inside one is left dotted")
        XCTAssertEqual(mixed.selectedVolumeBytes, gb(5))
    }

    func testTheConfirmedSelectionRemembersTheSplit() throws {
        var selection = try board()
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }))
        let apply = selection.applySelection
        XCTAssertEqual(apply.bytes, gb(17.4))
        XCTAssertEqual(apply.volumeBytes, gb(8.4))
        XCTAssertEqual(apply.inside, [inside(docker, 9.0)])
        XCTAssertEqual(apply.insideBytes, gb(9.0))
        XCTAssertEqual(ApplySelection(unchecked: ["/a"], bytes: 10).volumeBytes, 10, "unknown means the disk gets it")
    }

    // MARK: the rest screen

    func testTickingDockerAddsToThePillButNotToTheAfterFigureOrTheGreenSlice() throws {
        var selection = try board()
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }))

        let c = rest(selection)
        XCTAssertEqual(c.number.text, "17.4 GB", "will go: Docker's 9.0 GB counts here like on the pill")
        XCTAssertEqual(c.sentence, "will go.")
        XCTAssertEqual(c.pillTitle, "Clean 17.4 GB…", "the pill says what will be removed")
        XCTAssertEqual(c.tickedText, "12 items ticked")
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now → 28.2 GB after", "28.2, not 37.2: the disk does not get Docker's")
        XCTAssertEqual(c.band?.segments.map(\.kind), [.used, .review, .selected, .free])
        XCTAssertEqual(c.band?.segments.map(\.bytes), [gb(190.8), gb(9), gb(8.4), gb(19.8)], "Docker stays dotted, not green")
        XCTAssertEqual(c.insideLine, "+ 9.0 GB inside Docker's disk image, not counted above.")
        XCTAssertEqual(
            c.bandSentence,
            "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB selected inside Docker's disk image, not counted as free space"
        )
    }

    func testTickingOneDockerItemLeavesTheRestToReviewAndNamesOnlyThatOneInside() throws {
        var selection = try board()
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }?.items.first))  // 6.2 GB

        let c = rest(selection)
        XCTAssertEqual(c.pillTitle, "Clean 14.6 GB…")
        XCTAssertEqual(c.reviewLink, "Review 2.8 GB more")
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now → 28.2 GB after")
        XCTAssertEqual(c.band?.segments.first { $0.kind == .review }?.bytes, gb(9.0), "2.8 to review and 6.2 ticked, all dotted")
        XCTAssertEqual(c.insideLine, "+ 6.2 GB inside Docker's disk image, not counted above.")
        XCTAssertEqual(
            c.bandSentence,
            "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 2.8 GB needs your review, 6.2 GB selected inside Docker's disk image, not counted as free space"
        )
    }

    func testOnlyDockerTickedPromisesNothingAboutFreeSpace() throws {
        var selection = try board()
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }))

        let c = rest(selection)
        XCTAssertEqual(c.pillTitle, "Clean 9.0 GB…")
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now", "no arrow: the disk gets nothing")
        XCTAssertEqual(c.band?.segments.map(\.kind), [.used, .review, .free], "no green slice")
        XCTAssertNotNil(c.insideLine)
    }

    func testNothingInsideNoLine() throws {
        XCTAssertNil(rest(try board()).insideLine, "Docker is not ticked")
        XCTAssertNil(rest(SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))).insideLine)
    }

    // MARK: the card

    private func readyModel(ticking docker: Bool) async throws -> AppModel {
        let model = AppModel(client: FakeCmmClient(plan: try TestPlans.fixture("plan-c.json")))
        await model.scan()
        if docker { model.toggle(try XCTUnwrap(model.selection?.groups.first { $0.section == .review })) }
        return model
    }

    func testTheCardCountsEverythingButPromisesOnlyWhatTheDiskGets() async throws {
        let model = try await readyModel(ticking: true)
        model.requestClean()
        let card = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(card.prompt, "Delete 12 items (17.4 GB)?", "what is removed")
        XCTAssertEqual(card.afterText, "Free space afterwards: about 28.2 GB.")
        XCTAssertEqual(card.insideText, "9.0 GB is freed inside Docker's disk image.\nThe disk shows it later, if at all.")
    }

    func testWithoutDockerTheCardHasNothingInsideToSay() async throws {
        let model = try await readyModel(ticking: false)
        model.requestClean()
        let card = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(card.prompt, "Delete 9 items (8.4 GB)?")
        XCTAssertEqual(card.afterText, "Free space afterwards: about 28.2 GB.")
        XCTAssertNil(card.insideText)
    }

    // MARK: while it cleans

    private func cleaningQueue(withDocker: Bool) throws -> [PlanItem] {
        let plan = try TestPlans.fixture("plan-c.json")
        let images = plan.items.first { $0.path == "docker: unused images" }
        return plan.items.filter { $0.tier == .safe } + (withDocker ? [images].compactMap { $0 } : [])
    }

    private func event(_ item: PlanItem, _ status: ItemStatus = .deleted) -> ItemEvent {
        ItemEvent(
            rule: item.rule, group: item.group, path: item.path, status: status, reason: "", bytes: item.bytes,
            freedBytes: status == .deleted ? item.bytes : 0, freesInside: item.freesInside
        )
    }

    /// Nine safe items and Docker's 6.2 GB images confirmed; go-build (volume) and the images (inside) are reported.
    private func progress(imagesReported: Bool) throws -> CleanProgress {
        let queue = try cleaningQueue(withDocker: true)
        var progress = CleanProgress(
            expected: 10, queue: queue, selectedBytes: gb(14.6), reviewHeld: gb(2.8), startFree: gb(19.8),
            selectedInsideBytes: gb(6.2)
        )
        progress.selected = 10
        progress.items = [event(try XCTUnwrap(queue.first { $0.path.hasSuffix("go-build") }))]
        if imagesReported { progress.items.append(event(try XCTUnwrap(queue.first { $0.path == "docker: unused images" }))) }
        return progress
    }

    func testFreedSoFarIsWhatTheDiskGotAndTheInsideBytesAreCountedApart() throws {
        let p = try progress(imagesReported: true)
        XCTAssertEqual(p.freedBytes, gb(1.2))
        XCTAssertEqual(p.insideFreed, [inside(docker, 6.2)])
        XCTAssertEqual(p.freeNow, gb(21.0), "19.8 + 1.2: never + 6.2")
        XCTAssertEqual(p.toGoBytes, gb(7.2), "8.4 for the disk minus the 1.2 reported; Docker's 6.2 was never the disk's")
    }

    func testTheCleaningScreenLeavesInsideBytesOutOfFreedSoFarAndFreeNow() throws {
        let c = CleaningPresentation(progress: try progress(imagesReported: true), capacity: gb(228), home: "/Users/test")
        XCTAssertEqual(c.number.text, "1.2 GB")
        XCTAssertEqual(c.caption.trailingText, "21.0 GB free now · 7.2 GB still to go")
        XCTAssertEqual(c.insideLine, "+ 6.2 GB inside Docker's disk image")
        let band = try XCTUnwrap(c.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .selected, .freed, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gb(228 - 19.8 - 2.8 - 7.2 - 1.2), gb(2.8), gb(7.2), gb(1.2), gb(19.8)])
    }

    func testAnInsideItemStillToGoIsDottedNotGreen() throws {
        let p = try progress(imagesReported: false)
        XCTAssertEqual(p.insideToGoReviewBytes, gb(6.2))
        let band = try XCTUnwrap(CleaningPresentation(progress: p, capacity: gb(228), home: "/Users/test").band)
        XCTAssertEqual(band.segments.first { $0.kind == .review }?.bytes, gb(9.0), "2.8 held and 6.2 not yet done, both dotted")
        XCTAssertEqual(band.segments.first { $0.kind == .selected }?.bytes, gb(7.2))
        XCTAssertNil(CleaningPresentation(progress: p, capacity: gb(228), home: "/Users/test").insideLine, "nothing inside yet")
    }

    func testWithoutInsideBytesTheCleaningScreenIsTheBoards() throws {
        var p = CleanProgress(expected: 1, queue: [], selectedBytes: gb(1), startFree: gb(19.8))
        p.items = [ItemEvent(rule: "", group: "", path: "/x", status: .deleted, reason: "", bytes: gb(1), freedBytes: gb(1))]
        let c = CleaningPresentation(progress: p, capacity: nil, home: "/Users/test")
        XCTAssertNil(c.insideLine)
        XCTAssertEqual(c.number.text, "1.0 GB")
    }

    // MARK: done

    private func summary(
        freedInside: Int64, items: [ItemEvent], freed: Int64 = 1_200_000_000
    ) -> CleanSummary {
        CleanSummary(
            done: DoneEvent(
                deleted: items.count, skipped: 0, failed: 0, freedBytes: freed, freedInsideBytes: freedInside,
                freeBefore: gb(19.8), freeAfter: gb(19.8) + freed, stopped: false, warnings: [], log: nil
            ),
            items: items, unreadableLines: 0, reviewHeld: gb(2.8), finishedAt: Date(timeIntervalSince1970: 1_792_065_780)
        )
    }

    private func done(_ summary: CleanSummary) -> DonePresentation {
        DonePresentation(summary: summary, capacity: gb(228), volumeName: "Macintosh HD", home: "/Users/test", now: Date(timeIntervalSince1970: 1_792_070_000))
    }

    func testTheDoneScreenSaysWhatTheDiskGotAndThenWhatWentInside() throws {
        let queue = try cleaningQueue(withDocker: true)
        let items = [
            event(try XCTUnwrap(queue.first { $0.path.hasSuffix("go-build") })),
            event(try XCTUnwrap(queue.first { $0.path == "docker: unused images" })),
        ]
        let p = done(summary(freedInside: gb(6.2), items: items))
        XCTAssertEqual(p.number.text, "21.0 GB", "the hero stays done.free_after")
        XCTAssertEqual(p.comparison.map(\.text).joined(), "Up from 19.8 GB. 1.2 GB freed.", "done.freed_bytes: the disk's share")
        XCTAssertEqual(p.insideSentence, "6.2 GB was freed inside Docker's disk image; the disk shows it when that space is given back.")
        XCTAssertEqual(p.band?.segments.first { $0.kind == .freed }?.bytes, gb(1.2))
        XCTAssertEqual(p.bandSentence, "Disk 228 GB: 21.0 GB free, 1.2 GB freed")
    }

    func testWithNothingInsideTheDoneScreenHasNoExtraSentence() throws {
        XCTAssertNil(done(summary(freedInside: 0, items: [])).insideSentence)
    }

    func testTheTotalComesFromTheDoneEventAndTheNameFromTheItems() throws {
        // done says 6.2 GB went inside; the items name Docker's disk image (and one of them was skipped).
        let queue = try cleaningQueue(withDocker: true)
        let images = try XCTUnwrap(queue.first { $0.path == "docker: unused images" })
        let p = done(summary(freedInside: gb(6.2), items: [event(images), event(images, .skipped)]))
        XCTAssertEqual(p.insideSentence, "6.2 GB was freed inside Docker's disk image; the disk shows it when that space is given back.")
    }

    func testManySkippedOrFailedItemsAreNamedThreeAtATimeSoTheScreenKeepsItsRoom() {
        let events = (1...7).map { n in
            ItemEvent(rule: "r", group: "g", path: "/Users/test/p\(n)", status: n.isMultiple(of: 2) ? .failed : .skipped,
                      reason: "busy", bytes: 1_000, freedBytes: 0)
        }
        let p = done(summary(freedInside: 0, items: events, freed: 0))
        XCTAssertEqual(p.issues.count, 3)
        XCTAssertEqual(p.issues.map(\.path), ["~/p1", "~/p2", "~/p3"])
        XCTAssertEqual(p.notes.first, "and 4 more skipped or failed.")
        XCTAssertEqual(p.deletedText, "7 deleted", "the counters are cmm's and count every item")
    }

    func testThreeIssuesNeedNoSummaryLine() {
        let events = (1...3).map { n in
            ItemEvent(rule: "r", group: "g", path: "/Users/test/p\(n)", status: .skipped, reason: "busy", bytes: 1, freedBytes: 0)
        }
        let p = done(summary(freedInside: 0, items: events, freed: 0))
        XCTAssertEqual(p.issues.count, 3)
        XCTAssertFalse(p.notes.contains { $0.hasPrefix("and ") })
    }

    func testAnInsideTotalWithNoNamedItemUsesAGenericPlace() {
        let p = done(summary(freedInside: gb(1.5), items: []))
        XCTAssertEqual(
            p.insideSentence,
            "1.5 GB was freed inside another program's own storage; the disk shows it when that space is given back."
        )
    }
}
