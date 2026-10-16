import XCTest
@testable import CmmKit

/// Everything the "at rest" screen says, derived from the plan and from what is ticked.
final class RestCopyTests: XCTestCase {
    private func copy(_ selection: SelectionModel, volume: String = "Macintosh HD") -> RestCopy {
        RestCopy(selection: selection, volumeName: volume)
    }

    private func board() throws -> SelectionModel {
        SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
    }

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    // MARK: the board, exactly

    func testTheBoardsRestScreen() throws {
        let c = copy(try board())
        XCTAssertEqual(c.eyebrow, "Macintosh HD · 19.8 GB free of 228 GB")
        XCTAssertEqual(c.number, SizeText.Parts(value: "8.4", unit: "GB"))
        XCTAssertEqual(c.sentence, "is safe to remove.")
        XCTAssertEqual(c.body, "Caches, the dependencies of three idle lanes and old Homebrew versions. All of it can be regenerated.")
        XCTAssertEqual(c.pillTitle, "Clean 8.4 GB…")
        XCTAssertTrue(c.pillEnabled)
        XCTAssertEqual(c.reviewLink, "Review 9.0 GB more")
        XCTAssertEqual(c.tickedText, "9 items ticked")
        XCTAssertEqual(c.heldLine, "1 held back: unavailable simulators, because Simulator is running")
    }

    func testTheBoardsBand() throws {
        let c = copy(try board())
        let band = try XCTUnwrap(c.band)
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .selected, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [gb(190.8), gb(9), gb(8.4), gb(19.8)])
        XCTAssertEqual(c.caption.leading, "228 GB")
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now → 28.2 GB after")
        XCTAssertEqual(c.bandSentence, "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB needs your review")
    }

    // MARK: what the ticks change, and what they do not

    func testUntickingChangesTheHeadlineThePillTheBandAndTheAfterFigure() throws {
        var selection = try board()
        let lane = try XCTUnwrap(selection.groups.first { $0.name.hasPrefix("Idle lane") }?.items.first)  // 1.4 GB
        selection.toggle(lane)

        let c = copy(selection)
        XCTAssertEqual(c.number.text, "7.0 GB", "with a selection that is not the default the headline is what will go: the pill's number")
        XCTAssertEqual(c.sentence, "will go.")
        XCTAssertEqual(c.body, "1.4 GB more is safe to remove. Docker's 9.0 GB is yours to review.")
        XCTAssertEqual(c.pillTitle, "Clean 7.0 GB…")
        XCTAssertEqual(c.tickedText, "8 items ticked")
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now → 26.8 GB after")
        XCTAssertEqual(c.band?.segments.first { $0.kind == .selected }?.bytes, gb(7.0))
        XCTAssertEqual(c.band?.segments.first { $0.kind == .used }?.bytes, gb(228 - 19.8 - 9 - 7.0), "what is unticked stays used")
        XCTAssertEqual(c.bandSentence, "Disk 228 GB: 19.8 GB free, 7.0 GB selected to remove, 9.0 GB needs your review")
    }

    func testTickingTheReviewTierAddsItToThePillAndTheBandAndNamesItInTheLink() throws {
        var selection = try board()
        let docker = try XCTUnwrap(selection.groups.first { $0.section == .review })
        selection.toggle(docker)

        let c = copy(selection)
        XCTAssertEqual(c.number.text, "17.4 GB", "what will go, as the pill says it, Docker's 9.0 GB included")
        XCTAssertEqual(c.sentence, "will go.")
        XCTAssertNil(c.body, "nothing safe is left unticked and nothing is left to review")
        XCTAssertEqual(c.pillTitle, "Clean 17.4 GB…")
        XCTAssertEqual(c.tickedText, "12 items ticked")
        XCTAssertEqual(c.reviewLink, "Includes 9.0 GB you reviewed")
        // Docker's prunes free space inside Docker's own disk image: the disk does not get it, so it is not "after"
        // and not green (see InsideTests for the whole story).
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now → 28.2 GB after")
        XCTAssertEqual(c.band?.segments.map(\.kind), [.used, .review, .selected, .free], "stays dotted: the disk does not get it")
        XCTAssertEqual(
            c.bandSentence,
            "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB selected inside Docker's disk image, not counted as free space"
        )
    }

    func testTickingPartOfTheReviewTierLeavesTheRestToReview() throws {
        var selection = try board()
        let docker = try XCTUnwrap(selection.groups.first { $0.section == .review })
        let images = try XCTUnwrap(docker.items.first)  // the biggest: 6.2 GB
        selection.toggle(images)

        let c = copy(selection)
        XCTAssertEqual(c.number.text, "14.6 GB")
        XCTAssertEqual(c.body, "Docker's 2.8 GB is yours to review.")
        XCTAssertEqual(c.pillTitle, "Clean 14.6 GB…")
        XCTAssertEqual(c.reviewLink, "Review 2.8 GB more")
        XCTAssertEqual(
            c.band?.segments.first { $0.kind == .review }?.bytes, gb(9.0),
            "the 2.8 GB left to review and the 6.2 GB ticked, which the disk does not get, are both dotted"
        )
    }

    func testNothingTickedDisablesThePill() throws {
        var selection = try board()
        for group in selection.groups where group.section == .safe { selection.toggle(group) }

        let c = copy(selection)
        XCTAssertEqual(c.number, SizeText.Parts(value: "0", unit: "GB"))
        XCTAssertEqual(c.sentence, "will go.")
        XCTAssertEqual(c.body, "8.4 GB more is safe to remove. Docker's 9.0 GB is yours to review.")
        XCTAssertEqual(c.pillTitle, "Nothing ticked")
        XCTAssertFalse(c.pillEnabled)
        XCTAssertEqual(c.tickedText, "0 items ticked")
        XCTAssertEqual(c.caption.trailingText, "19.8 GB free now", "nothing selected, nothing after")
    }

    func testOneItemIsSaidInTheSingular() throws {
        var selection = try board()
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        let uv = try XCTUnwrap(selection.groups.first { $0.rule == "uv-cache" }?.items.first)
        selection.toggle(uv)
        XCTAssertEqual(copy(selection).tickedText, "1 item ticked")
        XCTAssertEqual(copy(selection).pillTitle, "Clean 2.5 GB…")
        XCTAssertEqual(copy(selection).number.text, "2.5 GB")
    }

    // MARK: what is not there

    func testNoReviewNoLinkAndNoDottedSegment() throws {
        let c = copy(SelectionModel(plan: try TestPlans.fixture("plan-v1.json")))
        XCTAssertNil(c.reviewLink)

        let withCapacity = TestPlans.plan(
            [TestPlans.item("/a", rule: "go-build", bytes: 2_000_000_000)], freeBytes: 10_000_000_000, capacityBytes: 100_000_000_000)
        XCTAssertEqual(copy(SelectionModel(plan: withCapacity)).band?.segments.map(\.kind), [.used, .selected, .free])
    }

    func testNoCapacityNoBandButTheCaptionStays() throws {
        let c = copy(SelectionModel(plan: try TestPlans.fixture("plan-v1.json")))
        XCTAssertNil(c.band)
        XCTAssertNil(c.caption.leading)
        XCTAssertEqual(c.eyebrow, "Macintosh HD · 27.6 GB free")
        XCTAssertEqual(c.caption.trailingText, "27.6 GB free now → 30.7 GB after")
        XCTAssertEqual(c.bandSentence, "27.6 GB free, 3.1 GB safe to remove")
    }

    func testNoHeldRulesNoHeldLine() {
        let plan = TestPlans.plan([TestPlans.item("/a", rule: "go-build", bytes: 5_000_000_000)])
        XCTAssertNil(copy(SelectionModel(plan: plan)).heldLine)
        XCTAssertTrue(copy(SelectionModel(plan: plan)).held.isEmpty)
    }

    func testAnUnnamedVolumeLeavesTheNameOut() throws {
        XCTAssertEqual(copy(try board(), volume: "").eyebrow, "19.8 GB free of 228 GB")
    }

    func testOnlyReviewItemsMeansNothingIsSafe() {
        let plan = TestPlans.plan(
            [TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: 9_000_000_000, tier: .review, action: .command)],
            freeBytes: 19_800_000_000, capacityBytes: 228_000_000_000)
        let c = copy(SelectionModel(plan: plan))
        XCTAssertEqual(c.number.text, "0 GB")
        XCTAssertEqual(c.sentence, "is safe to remove.")
        XCTAssertEqual(c.body, "Nothing regenerable was found. What cmm offers for review is your call.")
        XCTAssertEqual(c.pillTitle, "Nothing ticked")
        XCTAssertEqual(c.reviewLink, "Review 9.0 GB more")
    }
}
