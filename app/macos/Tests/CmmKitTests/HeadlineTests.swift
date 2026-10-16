import XCTest
@testable import CmmKit

/// What the rest screen's headline says. While everything safe is ticked and nothing for review is, it says how much is safe
/// to remove ("8.4 GB is safe to remove."). With any other selection it follows what is ticked ("3.9 GB will go."), the
/// number the pill carries, and says what else is there: the safe bytes that are not ticked and what is left to review.
final class HeadlineTests: XCTestCase {
    private func board() throws -> SelectionModel {
        SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
    }

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    /// The map board's state: lane-a node_modules (1.4 GB) and uv cache (2.5 GB) ticked, nothing else.
    private func mapBoard() throws -> SelectionModel {
        var selection = try board()
        for item in selection.groups.flatMap(\.items) where item.tier == .safe {
            if item.path != "/Users/test/lane-builds/lane-a/node_modules" && item.path != "/Users/test/.cache/uv" {
                selection.setTicked(false, for: item)
            }
        }
        return selection
    }

    // MARK: while everything safe is ticked and nothing from review is

    func testTheDefaultStateIsTheHeadlineAsItWas() throws {
        let h = Headline(selection: try board())
        XCTAssertFalse(h.followsSelection)
        XCTAssertEqual(h.number, SizeText.Parts(value: "8.4", unit: "GB"))
        XCTAssertEqual(h.sentence, "is safe to remove.")
        XCTAssertEqual(h.body, "Caches, the dependencies of three idle lanes and old Homebrew versions. All of it can be regenerated.")
    }

    func testTheDefaultStateWithNothingForReviewIsTheSameHeadline() throws {
        let h = Headline(selection: SelectionModel(plan: try TestPlans.fixture("plan-v1.json")))
        XCTAssertFalse(h.followsSelection)
        XCTAssertEqual(h.sentence, "is safe to remove.")
    }

    func testAPlanWithOnlyReviewItemsKeepsItsOwnWordsUntilSomethingIsTicked() {
        let plan = TestPlans.plan(
            [TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gb(9), tier: .review, action: .command)],
            freeBytes: gb(19.8), capacityBytes: gb(228))
        var selection = SelectionModel(plan: plan)
        let before = Headline(selection: selection)
        XCTAssertFalse(before.followsSelection, "nothing safe to tick, nothing ticked: as it has always been")
        XCTAssertEqual(before.number.text, "0 GB")
        XCTAssertEqual(before.sentence, "is safe to remove.")
        XCTAssertEqual(before.body, "Nothing regenerable was found. What cmm offers for review is your call.")

        selection.toggle(selection.groups[0])
        let after = Headline(selection: selection)
        XCTAssertTrue(after.followsSelection)
        XCTAssertEqual(after.number.text, "9.0 GB")
        XCTAssertEqual(after.sentence, "will go.")
        XCTAssertNil(after.body, "nothing safe is left unticked and nothing is left to review")
    }

    // MARK: any other state: the number is the pill's

    func testTheMapBoardsHeadline() throws {
        let h = Headline(selection: try mapBoard())
        XCTAssertTrue(h.followsSelection)
        XCTAssertEqual(h.number, SizeText.Parts(value: "3.9", unit: "GB"))
        XCTAssertEqual(h.sentence, "will go.")
        XCTAssertEqual(h.body, "4.5 GB more is safe to remove. Docker's 9.0 GB is yours to review.")
    }

    func testTheNumberIsAlwaysTheNumberOnThePill() throws {
        var selection = try board()
        var ticks: [(String, (inout SelectionModel) -> Void)] = []
        ticks.append(("one safe item off", { $0.toggle($0.groups.first { $0.rule == "uv-cache" }!.items[0]) }))
        ticks.append(("docker on", { $0.toggle($0.groups.first { $0.section == .review }!) }))
        ticks.append(("one prune off", { $0.toggle($0.groups.first { $0.section == .review }!.items[0]) }))
        for (what, change) in ticks {
            change(&selection)
            let copy = RestCopy(selection: selection, volumeName: "Macintosh HD")
            let h = Headline(selection: selection)
            if h.followsSelection {
                XCTAssertEqual(h.number.text, SizeText.string(selection.selectedBytes), what)
                if selection.selectedCount > 0 { XCTAssertEqual(copy.pillTitle, "Clean \(h.number.text)…", what) }
            }
        }
    }

    func testTickingOneSafeItemOffTakesItFromTheNumberAndSaysItIsStillThere() throws {
        var selection = try board()
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.rule == "uv-cache" }?.items.first))  // 2.5 GB off
        let h = Headline(selection: selection)
        XCTAssertTrue(h.followsSelection)
        XCTAssertEqual(h.number.text, "5.9 GB")
        XCTAssertEqual(h.sentence, "will go.")
        XCTAssertEqual(h.body, "2.5 GB more is safe to remove. Docker's 9.0 GB is yours to review.")
    }

    func testTickingDockerAddsItToTheNumberAndLeavesNothingToSayAboutIt() throws {
        var selection = try board()
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }))
        let h = Headline(selection: selection)
        XCTAssertTrue(h.followsSelection)
        XCTAssertEqual(h.number.text, "17.4 GB", "what will go, as the pill says: Docker's 9.0 GB included")
        XCTAssertEqual(h.sentence, "will go.")
        XCTAssertNil(h.body, "every clause is zero: there is nothing more to say")
    }

    func testPartOfDockerTickedLeavesTheRestToReview() throws {
        var selection = try board()
        let docker = try XCTUnwrap(selection.groups.first { $0.section == .review })
        selection.toggle(try XCTUnwrap(docker.items.first))  // 6.2 GB of the 9.0
        let h = Headline(selection: selection)
        XCTAssertEqual(h.number.text, "14.6 GB")
        XCTAssertEqual(h.body, "Docker's 2.8 GB is yours to review.", "the safe clause is left out when it is zero")
    }

    func testNothingTickedIsZeroGBAndSaysEverythingThatIsThere() throws {
        var selection = try board()
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        XCTAssertEqual(selection.selectedCount, 0)
        let h = Headline(selection: selection)
        XCTAssertTrue(h.followsSelection)
        XCTAssertEqual(h.number, SizeText.Parts(value: "0", unit: "GB"))
        XCTAssertEqual(h.sentence, "will go.")
        XCTAssertEqual(h.body, "8.4 GB more is safe to remove. Docker's 9.0 GB is yours to review.")
        XCTAssertFalse(RestCopy(selection: selection, volumeName: "Macintosh HD").pillEnabled, "the pill stays disabled")
    }

    // MARK: the clauses

    func testSeveralGroupsToReviewAreOneUnnamedClause() {
        let plan = TestPlans.plan([
            TestPlans.item("/s", group: "Safe", rule: "go-build", bytes: gb(2)),
            TestPlans.item("docker: images", group: "Docker", rule: "docker", bytes: gb(3), tier: .review, action: .command),
            TestPlans.item("/Users/test/old", group: "Old downloads", rule: "old-downloads", bytes: gb(1.5), tier: .review),
        ])
        var selection = SelectionModel(plan: plan)
        selection.toggle(selection.groups.first { $0.rule == "go-build" }!)
        let h = Headline(selection: selection)
        XCTAssertEqual(h.body, "2.0 GB more is safe to remove. 4.5 GB is yours to review.", "no name: there are two groups left")

        // one of them reviewed: the other is named again
        selection.toggle(selection.groups.first { $0.rule == "docker" }!)
        XCTAssertEqual(Headline(selection: selection).body, "2.0 GB more is safe to remove. Old downloads' 1.5 GB is yours to review.")
    }

    func testTheReviewGroupsNameIsTheMapTilesNameFromThePlanNeverAWiredInWord() {
        let plan = TestPlans.plan([
            TestPlans.item("/Users/test/Library/Foo", group: "Foo caches", rule: "brand-new", bytes: gb(2), tier: .review),
            TestPlans.item("/s", group: "Safe", rule: "go-build", bytes: gb(1)),
        ])
        var selection = SelectionModel(plan: plan)
        selection.toggle(selection.groups.first { $0.rule == "go-build" }!)
        XCTAssertEqual(Headline(selection: selection).body, "1.0 GB more is safe to remove. Foo caches' 2.0 GB is yours to review.")
    }

    func testThePossessiveFollowsEnglish() {
        XCTAssertEqual(Headline.possessive("Docker"), "Docker's")
        XCTAssertEqual(Headline.possessive("Homebrew"), "Homebrew's")
        XCTAssertEqual(Headline.possessive("Old downloads"), "Old downloads'")
        XCTAssertEqual(Headline.possessive("Xcode"), "Xcode's")
        XCTAssertEqual(Headline.possessive("npm caches"), "npm caches'")
    }

    func testSmallSizesAreSaidInTheirOwnUnits() {
        let plan = TestPlans.plan([
            TestPlans.item("/a", group: "A", rule: "go-build", bytes: 40_000_000),
            TestPlans.item("/b", group: "B", rule: "npm-cache", bytes: gb(1)),
        ])
        var selection = SelectionModel(plan: plan)
        selection.toggle(selection.groups.first { $0.rule == "go-build" }!)
        let h = Headline(selection: selection)
        XCTAssertEqual(h.number.text, "1.0 GB")
        XCTAssertEqual(h.body, "40 MB more is safe to remove.")
    }

    // MARK: the honest rule

    func testBytesFreedInsideAnotherProgramCountInWillGoButNeverInAfter() throws {
        var selection = try board()
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }))
        let copy = RestCopy(selection: selection, volumeName: "Macintosh HD")
        XCTAssertEqual(copy.number.text, "17.4 GB", "will go, like the pill")
        XCTAssertEqual(copy.pillTitle, "Clean 17.4 GB…")
        XCTAssertEqual(copy.caption.trailingText, "19.8 GB free now → 28.2 GB after", "after counts what the disk gets back: 19.8 + 8.4")
        XCTAssertNotNil(copy.insideLine, "and the 9.0 GB inside Docker's disk image is said, once, under the band")
    }

    func testTheRestCopyUsesTheHeadline() throws {
        let selection = try mapBoard()
        let copy = RestCopy(selection: selection, volumeName: "Macintosh HD")
        let h = Headline(selection: selection)
        XCTAssertEqual(copy.number, h.number)
        XCTAssertEqual(copy.sentence, h.sentence)
        XCTAssertEqual(copy.body, h.body)
        XCTAssertEqual(copy.pillTitle, "Clean 3.9 GB…")
        XCTAssertEqual(copy.tickedText, "2 items ticked")
    }

    func testNothingButSafeAndReviewItemsEverCounts() throws {
        // a held-back item is not in the plan's items; the totals are of what can be ticked
        var selection = try board()
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        XCTAssertEqual(Headline(selection: selection).number.text, "0 GB")
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        XCTAssertFalse(Headline(selection: selection).followsSelection, "ticked again: back to the safe total")
    }
}
