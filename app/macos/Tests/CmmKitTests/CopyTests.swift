import XCTest
@testable import CmmKit

/// The sentences of the window, built from the plan. For the board's data they come out exactly as the boards
/// write them; for anything else they stay true and plain.
final class CopyTests: XCTestCase {
    private func selection(_ name: String = "plan-c.json") throws -> SelectionModel {
        SelectionModel(plan: try TestPlans.fixture(name))
    }

    // MARK: labels

    func testALabelSplitsIntoATitleAndItsParentheticalClauses() {
        let lanes = LabelParts("Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)")
        XCTAssertEqual(lanes.title, "Idle lane dependencies")
        XCTAssertEqual(lanes.clauses, ["untouched 5+ days", "rebuild with npm ci / pod install"])

        let plain = LabelParts("Go build cache")
        XCTAssertEqual(plain.title, "Go build cache")
        XCTAssertEqual(plain.clauses, [])

        let brew = LabelParts("Homebrew: old versions of installed formulae (brew cleanup)")
        XCTAssertEqual(brew.title, "Homebrew: old versions of installed formulae")
        XCTAssertEqual(brew.clauses, ["brew cleanup"])
    }

    func testOnlyATrailingParentheticalIsSplitOff() {
        XCTAssertEqual(LabelParts("Docker (the app) tools").title, "Docker (the app) tools")
        XCTAssertEqual(LabelParts("Odd (unclosed").title, "Odd (unclosed")
        XCTAssertEqual(LabelParts("").title, "")
    }

    func testTheFootnoteIsTheSecondClauseAsASentence() {
        XCTAssertEqual(LabelParts("Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)").footnote,
                       "Rebuild with npm ci or pod install.")
        XCTAssertEqual(LabelParts("uv cache (Python packages; downloads again on demand)").footnote, "Downloads again on demand.")
        XCTAssertNil(LabelParts("Homebrew: old versions of installed formulae (brew cleanup)").footnote, "one clause is not a footnote")
        XCTAssertNil(LabelParts("Go build cache").footnote)
    }

    // MARK: titles

    func testKnownRulesGetTheTitlesOfTheBoards() {
        XCTAssertEqual(RuleCatalog.title(rule: "lane-deps", label: "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)"), "Idle lane dependencies")
        XCTAssertEqual(RuleCatalog.title(rule: "uv-cache", label: "uv cache (Python packages; downloads again on demand)"), "uv cache")
        XCTAssertEqual(RuleCatalog.title(rule: "homebrew", label: "Homebrew: old versions of installed formulae (brew cleanup)"), "Homebrew old versions")
        XCTAssertEqual(RuleCatalog.title(rule: "npm-cache", label: "npm download cache"), "npm cache")
        XCTAssertEqual(RuleCatalog.title(rule: "docker", label: "Docker: unused images, stopped containers and build cache (review first)"), "Docker")
        XCTAssertEqual(RuleCatalog.title(rule: "simulators", label: "x"), "Unavailable simulators")
    }

    func testAnUnknownRuleFallsBackToItsLabelWithoutTheParenthetical() {
        XCTAssertEqual(RuleCatalog.title(rule: "brand-new", label: "Brand new cache (regenerates)"), "Brand new cache")
        XCTAssertEqual(RuleCatalog.title(rule: "brand-new", label: ""), "Brand new", "and with no label, its id made readable")
        XCTAssertEqual(RuleCatalog.humanized(rule: "some-new-rule"), "Some new rule")
    }

    func testEveryBuiltInRuleHasATitle() {
        let ids = ["go-build", "npm-cache", "cocoapods", "bun-cache", "uv-cache", "xcode-module-cache", "deriveddata-stale",
                   "lane-local-build", "lane-deps", "lane-build-output", "jest-temp", "maestro-temp", "cursor-update",
                   "claude-versions", "cursor-agent-versions", "simulators", "homebrew", "docker"]
        for id in ids {
            XCTAssertNotNil(RuleCatalog.knownTitle(rule: id), "\(id) has no title in the catalog")
        }
    }

    func testTheMidSentenceFormLowercasesOnlyPlainFirstWords() {
        XCTAssertEqual(RuleCatalog.midSentence("Unavailable simulators"), "unavailable simulators")
        XCTAssertEqual(RuleCatalog.midSentence("Idle lane dependencies"), "idle lane dependencies")
        XCTAssertEqual(RuleCatalog.midSentence("Go build cache"), "Go build cache", "a name keeps its capital")
        XCTAssertEqual(RuleCatalog.midSentence("CocoaPods cache"), "CocoaPods cache")
        XCTAssertEqual(RuleCatalog.midSentence("uv cache"), "uv cache")
    }

    // MARK: held back

    func testAHeldRowDropsTheRulesLabelFromItsReasonAndSaysWhenItReturns() throws {
        let plan = try TestPlans.fixture("plan-c.json")
        let row = HeldRow.make(skip: plan.skipped[0], index: 0, labelsInPlan: [])
        XCTAssertEqual(row.title, "Unavailable simulators")
        XCTAssertEqual(row.reason, "Simulator is running")
        XCTAssertEqual(row.detail, "Simulator is running · offered again next scan")
    }

    func testAReasonIsCapitalizedForTheRowButNotAltered() {
        let skip = Skip(rule: "go-build", reason: "Go build cache: a go command is running")
        let row = HeldRow.make(skip: skip, index: 0, labelsInPlan: [])
        XCTAssertEqual(row.reason, "a go command is running")
        XCTAssertEqual(row.detail, "A go command is running · offered again next scan")
    }

    func testTheLabelPrefixIsRecognisedFromTheRulesOwnLabelOrTheOneInThePlan() {
        let long = Skip(rule: "uv-cache", reason: "uv cache (Python packages; downloads again on demand): uv is running")
        XCTAssertEqual(HeldRow.make(skip: long, index: 0, labelsInPlan: []).reason, "uv is running")

        let custom = Skip(rule: "brand-new", reason: "Brand new cache (regenerates): it is busy")
        XCTAssertEqual(HeldRow.make(skip: custom, index: 0, labelsInPlan: []).reason, "Brand new cache (regenerates): it is busy",
                       "an unknown label is not guessed at")
        XCTAssertEqual(HeldRow.make(skip: custom, index: 0, labelsInPlan: ["Brand new cache (regenerates)"]).reason, "it is busy")
    }

    func testASimpleReasonIsLeftAlone() {
        let skip = Skip(rule: "uv-cache", reason: "uv is running")
        XCTAssertEqual(HeldRow.make(skip: skip, index: 0, labelsInPlan: []).reason, "uv is running")
    }

    func testTheHeldLineUnderTheBand() throws {
        let plan = try TestPlans.fixture("plan-c.json")
        XCTAssertEqual(HeldBack.line(for: [HeldRow.make(skip: plan.skipped[0], index: 0, labelsInPlan: [])]),
                       "1 held back: unavailable simulators, because Simulator is running")
        XCTAssertNil(HeldBack.line(for: []))

        let two = [
            HeldRow.make(skip: Skip(rule: "simulators", reason: "Simulator is running"), index: 0, labelsInPlan: []),
            HeldRow.make(skip: Skip(rule: "uv-cache", reason: "uv is running"), index: 1, labelsInPlan: []),
        ]
        XCTAssertEqual(HeldBack.line(for: two), "2 held back: unavailable simulators and uv cache")

        let many = (0..<5).map { HeldRow.make(skip: Skip(rule: "go-build", reason: "r\($0)"), index: $0, labelsInPlan: []) }
        XCTAssertEqual(HeldBack.line(for: many), "5 held back: Go build cache, Go build cache, Go build cache and 2 more")
    }

    func testTheEmptyScreenSaysWhatWasHeldBack() {
        let uv = [HeldRow.make(skip: Skip(rule: "uv-cache", reason: "uv is running"), index: 0, labelsInPlan: [])]
        XCTAssertEqual(HeldBack.sentence(for: uv), "The uv cache was held back because uv is running. cmm looks again on the next scan.")

        let sims = [HeldRow.make(skip: Skip(rule: "simulators", reason: "Simulator is running"), index: 0, labelsInPlan: [])]
        XCTAssertEqual(HeldBack.sentence(for: sims),
                       "The unavailable simulators were held back because Simulator is running. cmm looks again on the next scan.")

        let two = uv + sims
        XCTAssertEqual(HeldBack.sentence(for: two), "2 things were held back: uv cache and unavailable simulators. cmm looks again on the next scan.")
        XCTAssertNil(HeldBack.sentence(for: []))
    }

    // MARK: the sentence under the number

    func testTheBoardsSentence() throws {
        XCTAssertEqual(
            HeroBody.text(for: try selection()),
            "Caches, the dependencies of three idle lanes and old Homebrew versions. All of it can be regenerated."
        )
    }

    func testTheSentenceCountsDistinctLanesFromTheNotes() throws {
        // lane-a has two items, lane-b and lane-c one each: three lanes, not four items.
        let text = try XCTUnwrap(HeroBody.text(for: try selection()))
        XCTAssertTrue(text.contains("three idle lanes"), text)
    }

    func testOneLaneIsSaidInTheSingular() {
        let plan = TestPlans.plan([
            TestPlans.item("/Users/test/lane-builds/x/node_modules", group: "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)",
                           rule: "lane-deps", bytes: 500_000_000, note: "lane x: untouched for 7 days"),
        ])
        XCTAssertEqual(HeroBody.text(for: SelectionModel(plan: plan)),
                       "The dependencies of one idle lane. All of it can be regenerated.")
    }

    func testWhenTheLanesCannotBeCountedTheSentenceDoesNotInventANumber() {
        let plan = TestPlans.plan([
            TestPlans.item("/p/a", group: "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)", rule: "lane-deps"),
        ])
        XCTAssertEqual(HeroBody.text(for: SelectionModel(plan: plan)),
                       "The dependencies of idle lanes. All of it can be regenerated.")
    }

    func testBiggerGroupsComeFirstAndCachesAreOneKind() throws {
        let text = try XCTUnwrap(HeroBody.text(for: try selection()))
        XCTAssertTrue(text.hasPrefix("Caches, "), "caches (4.1 GB together) outweigh the lanes (3.6 GB): \(text)")
    }

    func testLongListsAreCutAtThreeKinds() {
        let plan = TestPlans.plan([
            TestPlans.item("/a", group: "Go build cache", rule: "go-build", bytes: 500),
            TestPlans.item("/b", group: "Homebrew: old versions of installed formulae (brew cleanup)", rule: "homebrew", bytes: 400, action: .command),
            TestPlans.item("/c", group: "Simulators whose runtime was removed", rule: "simulators", bytes: 300),
            TestPlans.item("/d", group: "Maestro test output (older than 1 hour)", rule: "maestro-temp", bytes: 200),
            TestPlans.item("/e", group: "Stale Xcode build output (DerivedData)", rule: "deriveddata-stale", bytes: 100),
        ])
        XCTAssertEqual(HeroBody.text(for: SelectionModel(plan: plan)),
                       "Caches, old Homebrew versions, unavailable simulators and more. All of it can be regenerated.")
    }

    func testAnUnknownRuleIsNamedByItsTitle() {
        let plan = TestPlans.plan([TestPlans.item("/a", group: "Old widgets (regenerate)", rule: "widgets", bytes: 5)])
        XCTAssertEqual(HeroBody.text(for: SelectionModel(plan: plan)), "Old widgets. All of it can be regenerated.")
    }

    func testNoSafeItemsNoSentence() throws {
        let plan = TestPlans.plan([TestPlans.item("/d", group: "Docker", rule: "docker", bytes: 9, tier: .review, action: .command)])
        XCTAssertNil(HeroBody.text(for: SelectionModel(plan: plan)))
    }

    func testNumberWordsGoToTenThenDigits() {
        XCTAssertEqual(HeroBody.number(1), "one")
        XCTAssertEqual(HeroBody.number(3), "three")
        XCTAssertEqual(HeroBody.number(10), "ten")
        XCTAssertEqual(HeroBody.number(11), "11")
    }
}
