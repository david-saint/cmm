import XCTest
@testable import CmmKit

/// Builders for plans made in code (the decoding tests use the JSON fixtures; these reach the internal initializers).
enum TestPlans {
    static func item(
        _ path: String,
        group: String = "Group",
        rule: String = "rule",
        bytes: Int64 = 1_000,
        tier: Tier = .safe,
        action: ItemAction = .delete,
        note: String? = nil,
        freesInside: String? = nil
    ) -> PlanItem {
        PlanItem(rule: rule, group: group, path: path, bytes: bytes, tier: tier, action: action, note: note, freesInside: freesInside)
    }

    static func plan(
        _ items: [PlanItem],
        skipped: [Skip] = [],
        freeBytes: Int64 = 20_000_000_000,
        capacityBytes: Int64? = nil,
        volume: String = "/System/Volumes/Data"
    ) -> Plan {
        Plan(
            schemaVersion: 1,
            generatedAt: nil,
            host: Host(volume: volume, freeBytes: freeBytes, capacityBytes: capacityBytes),
            items: items,
            skipped: skipped,
            totalBytes: items.reduce(0) { $0 + $1.bytes }
        )
    }

    static func fixture(_ name: String) throws -> Plan {
        try Plan.parse(Fixture.data(name))
    }
}

final class SelectionModelTests: XCTestCase {
    // MARK: groups

    func testGroupsAreSortedBySizeLargestFirst() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        XCTAssertEqual(selection.groups.map(\.bytes), [1_450_455_040, 927_080_448, 704_000_000])
        XCTAssertEqual(selection.groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(selection.groups[0].name, "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)")
    }

    func testItemsInsideAGroupAreSortedBySizeLargestFirst() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        XCTAssertEqual(selection.groups[0].items.map(\.bytes), [838_086_656, 612_368_384])
    }

    func testEqualSizesAreOrderedByNameSoTheListDoesNotJump() {
        let plan = TestPlans.plan([
            TestPlans.item("/b", group: "Beta", bytes: 10),
            TestPlans.item("/a", group: "Alpha", bytes: 10),
            TestPlans.item("/d", group: "Alpha", bytes: 5),
            TestPlans.item("/c", group: "Alpha", bytes: 5),
        ])
        let selection = SelectionModel(plan: plan)
        XCTAssertEqual(selection.groups.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(selection.groups[0].items.map(\.path), ["/a", "/c", "/d"])
    }

    func testAPlanWithNoItemsHasNoGroupsAndNothingSelected() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-empty.json"))
        XCTAssertTrue(selection.groups.isEmpty)
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertEqual(selection.selectedBytes, 0)
        XCTAssertEqual(selection.applySelection.paths, [])
    }

    func testTheSamePathTwiceIsOneItem() {
        let plan = TestPlans.plan([
            TestPlans.item("/same", bytes: 10),
            TestPlans.item("/same", bytes: 10),
            TestPlans.item("/other", bytes: 3),
        ])
        let selection = SelectionModel(plan: plan)
        XCTAssertEqual(selection.groups.flatMap(\.items).count, 2)
        XCTAssertEqual(selection.selectedCount, 2)
        XCTAssertEqual(selection.selectedBytes, 13)
        XCTAssertEqual(selection.applySelection.paths, ["/same", "/other"])
    }

    // MARK: default selection by tier

    func testOnlySafeItemsStartTicked() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-mixed-tiers.json"))
        XCTAssertEqual(
            selection.ticked,
            [
                "/Users/test/Library/Caches/go-build",
                "/Users/test/Library/Caches/cursor-updater/old",
            ]
        )
        XCTAssertEqual(selection.selectedCount, 2)
        XCTAssertEqual(selection.selectedBytes, 1_000_000_000)
    }

    func testReviewManualAndUnknownTiersAreNeverPreselected() throws {
        let plan = try TestPlans.fixture("plan-mixed-tiers.json")
        let selection = SelectionModel(plan: plan)
        for item in plan.items where item.tier != .safe {
            XCTAssertFalse(selection.isTicked(item), "\(item.path) is tier \(item.tier.rawValue)")
        }
    }

    func testEverythingInTheSpecSampleStartsTicked() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        XCTAssertEqual(selection.selectedCount, 4)
        XCTAssertEqual(selection.selectedBytes, 3_081_535_488)
        XCTAssertEqual(selection.plannedBytes, 3_081_535_488)
    }

    func testPlannedBytesCountsOnlySafeItems() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-mixed-tiers.json"))
        XCTAssertEqual(selection.plannedBytes, 1_000_000_000, "the 'Safe to remove' figure must not include review items")
        XCTAssertEqual(selection.safeCount, 2)
    }

    // MARK: tri-state

    func testGroupStateIsOnOffOrMixed() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.name.hasPrefix("Idle lane dependencies") })
        XCTAssertEqual(selection.state(of: lanes), .on)

        selection.toggle(lanes.items[0])
        XCTAssertEqual(selection.state(of: lanes), .mixed, "one of four items unticked")

        let docker = try XCTUnwrap(selection.groups.first { $0.section == .review })
        XCTAssertEqual(selection.state(of: docker), .off, "review items are not ticked until someone ticks them")
    }

    func testClickingAMixedGroupTicksEverything() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.name.hasPrefix("Idle lane dependencies") })
        selection.toggle(lanes.items[0])
        XCTAssertEqual(selection.state(of: lanes), .mixed)

        selection.toggle(lanes)

        XCTAssertEqual(selection.state(of: lanes), .on)
        XCTAssertTrue(lanes.items.allSatisfy(selection.isTicked))
    }

    func testClickingAnOnGroupClearsEverything() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let group = selection.groups[0]
        selection.toggle(group)
        XCTAssertEqual(selection.state(of: group), .off)
        XCTAssertTrue(group.items.allSatisfy { !selection.isTicked($0) })
        XCTAssertEqual(selection.selectedCount, 2, "the other groups are untouched")
    }

    func testClickingAnOffGroupTicksEverything() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let group = selection.groups[0]
        selection.toggle(group)
        XCTAssertEqual(selection.state(of: group), .off)
        selection.toggle(group)
        XCTAssertEqual(selection.state(of: group), .on)
    }

    // MARK: tiers: safe is ticked for you, review only by you, the rest never

    func testGroupsAreSplitBySectionSoATierNeverHidesInsideAnother() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-mixed-tiers.json"))
        // "Cursor update leftovers" has a safe and a review item: each tier gets its own group.
        XCTAssertEqual(selection.groups.map { "\($0.section.rawValue)/\($0.name)" }, [
            "safe/Go build cache",
            "safe/Cursor update leftovers",
            "review/Cursor update leftovers",
            "other/Needs a person",
        ])
        XCTAssertEqual(selection.groups.map(\.bytes), [900_000_000, 100_000_000, 300_000_000, 4_050_000_000])
    }

    func testTheBoardPlanHasNineSafeItemsAndThreeReviewItems() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        XCTAssertEqual(selection.safeCount, 9)
        XCTAssertEqual(selection.plannedBytes, 8_400_000_000)
        XCTAssertEqual(selection.reviewCount, 3)
        XCTAssertEqual(selection.reviewBytes, 9_000_000_000)
        XCTAssertEqual(selection.selectedCount, 9, "only the safe items start ticked")
        XCTAssertEqual(selection.selectedBytes, 8_400_000_000)
        XCTAssertEqual(selection.selectedReviewBytes, 0)
    }

    func testReviewItemsAreTakenOnlyByAnExplicitTickOnThemOrTheirGroup() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let docker = try XCTUnwrap(selection.groups.first { $0.section == .review })
        XCTAssertEqual(docker.items.count, 3)
        XCTAssertFalse(docker.items.contains(where: selection.isTicked))

        // Clearing and re-ticking every safe group never reaches the review items.
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        for group in selection.groups where group.section == .safe { selection.toggle(group) }
        XCTAssertEqual(selection.selectedReviewBytes, 0)
        XCTAssertEqual(selection.selectedCount, 9)

        // One explicit tick takes one item.
        selection.toggle(docker.items[0])
        XCTAssertEqual(selection.selectedCount, 10)
        XCTAssertEqual(selection.selectedReviewBytes, docker.items[0].bytes)
        XCTAssertEqual(selection.state(of: docker), .mixed)

        // Ticking the group takes all three, and only those.
        selection.toggle(docker)
        XCTAssertEqual(selection.state(of: docker), .on)
        XCTAssertEqual(selection.selectedCount, 12)
        XCTAssertEqual(selection.selectedReviewBytes, 9_000_000_000)
        XCTAssertEqual(selection.selectedBytes, 17_400_000_000)
        XCTAssertEqual(selection.plannedBytes, 8_400_000_000, "the safe figure does not move with review ticks")
    }

    func testManualAndUnknownTiersCannotBeTickedByAnything() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-mixed-tiers.json"))
        let other = try XCTUnwrap(selection.groups.first { $0.section == .other })
        XCTAssertEqual(other.items.count, 2)
        XCTAssertTrue(other.items.allSatisfy { !selection.isTickable($0) })

        selection.toggle(other)
        for item in other.items {
            selection.setTicked(true, for: item)
            selection.toggle(item)
        }

        XCTAssertFalse(other.items.contains(where: selection.isTicked))
        XCTAssertEqual(selection.state(of: other), .off)
        XCTAssertEqual(selection.selectedCount, 2, "still only the two safe items")
    }

    func testAForgedTickOnAManualItemNeverReachesCmm() throws {
        let plan = try TestPlans.fixture("plan-mixed-tiers.json")
        let manual = try XCTUnwrap(plan.items.first { $0.tier == .manual })
        let unknown = try XCTUnwrap(plan.items.first { $0.tier == .other("experimental") })
        let review = try XCTUnwrap(plan.items.first { $0.tier == .review })

        let apply = ApplySelection(plan: plan, ticked: [manual.path, unknown.path, review.path])

        XCTAssertEqual(apply.paths, [review.path], "review may be ticked on purpose; manual and unknown never")
    }

    func testTogglingItemsMovesTheGroupThroughAllThreeStates() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let group = selection.groups[0]
        XCTAssertEqual(selection.state(of: group), .on)

        selection.toggle(group.items[0])
        XCTAssertEqual(selection.state(of: group), .mixed)

        selection.toggle(group.items[1])
        XCTAssertEqual(selection.state(of: group), .off)

        selection.toggle(group.items[0])
        selection.toggle(group.items[1])
        XCTAssertEqual(selection.state(of: group), .on)
    }

    // MARK: totals

    func testTotalsFollowTheTicks() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let brew = try XCTUnwrap(selection.groups.last?.items.first)
        XCTAssertEqual(brew.action, .command)

        selection.setTicked(false, for: brew)
        XCTAssertEqual(selection.selectedCount, 3)
        XCTAssertEqual(selection.selectedBytes, 2_377_535_488)
        XCTAssertEqual(selection.plannedBytes, 3_081_535_488, "the planned total does not move with the ticks")

        selection.setTicked(true, for: brew)
        XCTAssertEqual(selection.selectedCount, 4)
        XCTAssertEqual(selection.selectedBytes, 3_081_535_488)
    }

    func testTickingTheSameItemTwiceCountsItOnce() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-mixed-tiers.json"))
        let review = try XCTUnwrap(selection.groups.flatMap(\.items).first { $0.tier == .review })
        selection.setTicked(true, for: review)
        selection.setTicked(true, for: review)
        XCTAssertEqual(selection.selectedCount, 3)
    }

    func testNothingSelectedMeansAnEmptyApplySelection() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        for group in selection.groups { selection.toggle(group) }
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertEqual(selection.applySelection.paths, [])
        XCTAssertEqual(selection.applySelection.count, 0)
    }

    // MARK: what is handed to cmm (safety rule 2)

    func testApplySelectionHoldsTheTickedPathsInPlanOrder() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let goBuild = try XCTUnwrap(selection.groups.flatMap(\.items).first { $0.rule == "go-build" })
        selection.setTicked(false, for: goBuild)

        let apply = selection.applySelection
        XCTAssertEqual(apply.paths, [
            "/Users/test/lane-builds/ios27-scene-cloud-mobile/node_modules",
            "/Users/test/lane-builds/android-widgets/node_modules",
            "homebrew: cleanup",
        ])
        XCTAssertEqual(apply.count, 3)
        XCTAssertEqual(apply.bytes, 838_086_656 + 612_368_384 + 704_000_000)
    }

    func testApplySelectionDropsEveryPathThatIsNotInThePlan() throws {
        let plan = try TestPlans.fixture("plan-v1.json")
        let apply = ApplySelection(
            plan: plan,
            ticked: [
                "/Users/test/Library/Caches/go-build",
                "/Users/test/Documents",          // typed by hand
                "/Users/test/Library/Caches/go-build/../..", // constructed
                "",
            ]
        )
        XCTAssertEqual(apply.paths, ["/Users/test/Library/Caches/go-build"])
        XCTAssertEqual(apply.bytes, 927_080_448)
    }

    func testAnItemOfAnotherPlanCannotBeTicked() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let stranger = TestPlans.item("/Users/test/not-in-this-plan", bytes: 99)

        selection.setTicked(true, for: stranger)
        XCTAssertFalse(selection.ticked.contains(stranger.path), "ticking a stranger does nothing")
        XCTAssertEqual(selection.selectedCount, 4)

        selection.toggle(stranger)  // checked separately: a tick followed by a toggle would cancel out
        XCTAssertFalse(selection.ticked.contains(stranger.path), "toggling a stranger does nothing either")
        XCTAssertEqual(selection.selectedCount, 4)
        XCTAssertEqual(selection.selectedBytes, 3_081_535_488)
        XCTAssertFalse(selection.applySelection.paths.contains(stranger.path))
    }

    func testApplySelectionCountsAreIndependentOfHowManyTimesAPathIsTicked() throws {
        let plan = try TestPlans.fixture("plan-v1.json")
        let apply = ApplySelection(plan: plan, ticked: ["homebrew: cleanup"])
        XCTAssertEqual(apply.paths, ["homebrew: cleanup"])
        XCTAssertEqual(apply.count, 1)
    }

    func testAnApplySelectionIsAValueThatDoesNotChangeWhenTheTicksDo() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        let frozen = selection.applySelection
        selection.toggle(selection.groups[0])
        XCTAssertEqual(frozen.count, 4)
        XCTAssertNotEqual(frozen, selection.applySelection)
    }
}
