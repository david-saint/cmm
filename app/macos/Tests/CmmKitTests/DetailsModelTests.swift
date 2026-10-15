import XCTest
@testable import CmmKit

/// The rows of the Details pane: three sections, sorted, with the titles and sublines of the boards.
final class DetailsModelTests: XCTestCase {
    private let home = "/Users/test"

    private func model(
        _ name: String = "plan-c.json", expanded: Set<String> = [], ticking: (inout SelectionModel) -> Void = { _ in }
    ) throws -> DetailsModel {
        var selection = SelectionModel(plan: try TestPlans.fixture(name))
        ticking(&selection)
        return DetailsModel(selection: selection, expanded: expanded, home: home)
    }

    private func groups(_ section: DetailsModel.Section) -> [DetailsModel.GroupRow] {
        section.rows.compactMap { if case .group(let g) = $0 { g } else { nil } }
    }

    // MARK: sections

    func testThreeSectionsInTheOrderOfTheBoard() throws {
        let details = try model()
        XCTAssertEqual(details.sections.map(\.kind), [.safe, .review, .held])
        XCTAssertEqual(details.sections.map(\.title), ["Safe to remove", "Review first", "Held back"])
        XCTAssertEqual(details.sections.map(\.total), ["8.4 GB", "9.0 GB", nil])
    }

    func testASectionThatHasNothingIsLeftOut() throws {
        let noReviewNoHeld = TestPlans.plan([TestPlans.item("/a", rule: "go-build", bytes: 5_000_000_000)])
        let details = DetailsModel(selection: SelectionModel(plan: noReviewNoHeld), expanded: [], home: home)
        XCTAssertEqual(details.sections.map(\.kind), [.safe])
    }

    func testSafeGroupsAreSortedBySize() throws {
        let safe = try XCTUnwrap(try model().sections.first { $0.kind == .safe })
        XCTAssertEqual(groups(safe).map(\.title), [
            "Idle lane dependencies", "uv cache", "Go build cache", "Homebrew old versions", "npm cache", "bun cache",
        ])
        XCTAssertEqual(groups(safe).map(\.sizeText), ["3.6 GB", "2.5 GB", "1.2 GB", "0.7 GB", "0.3 GB", "0.1 GB"])
    }

    // MARK: group rows

    func testGroupSublinesAreTheBoardsCopy() throws {
        let safe = try XCTUnwrap(try model().sections.first { $0.kind == .safe })
        let rows = groups(safe)
        XCTAssertEqual(rows[0].subtitle, "4 items · untouched 5+ days")
        XCTAssertFalse(rows[0].subtitleIsMonospaced)
        XCTAssertEqual(rows[1].subtitle, "~/.cache/uv")
        XCTAssertTrue(rows[1].subtitleIsMonospaced, "a single path is shown as a path")
        XCTAssertEqual(rows[2].subtitle, "~/Library/Caches/go-build")
        XCTAssertEqual(rows[3].subtitle, "brew cleanup", "a command item shows what runs, not its label")
        XCTAssertEqual(rows[4].subtitle, "~/.npm/_cacache")
        XCTAssertEqual(rows[5].subtitle, "~/.bun/install/cache")
    }

    func testTheDockerRowSaysWhatItIsAndThatVolumesAreNeverOffered() throws {
        let review = try XCTUnwrap(try model().sections.first { $0.kind == .review })
        let docker = try XCTUnwrap(groups(review).first)
        XCTAssertEqual(docker.title, "Docker")
        XCTAssertEqual(docker.subtitle, "Unused images, stopped containers, build cache. Volumes are never offered.")
        XCTAssertFalse(docker.subtitleIsMonospaced)
        XCTAssertEqual(docker.sizeText, "9.0 GB")
        XCTAssertEqual(docker.state, .off, "review is never ticked for you")
    }

    func testGroupStateFollowsTheTicks() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.rule == "lane-deps" })
        selection.toggle(lanes.items[0])
        let details = DetailsModel(selection: selection, expanded: [], home: home)
        XCTAssertEqual(groups(try XCTUnwrap(details.sections.first)).first?.state, .mixed)
    }

    // MARK: expansion

    func testCollapsedGroupsShowNoItems() throws {
        let safe = try XCTUnwrap(try model().sections.first { $0.kind == .safe })
        XCTAssertTrue(safe.rows.allSatisfy { if case .group = $0 { true } else { false } })
        XCTAssertTrue(groups(safe).allSatisfy { !$0.isExpanded })
    }

    func testAnExpandedGroupListsItsItemsLargestFirstThenItsFootnote() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.rule == "lane-deps" })
        let details = DetailsModel(selection: selection, expanded: [lanes.id], home: home)
        let safe = try XCTUnwrap(details.sections.first)

        guard case .group(let head) = safe.rows[0] else { return XCTFail("first row is the group") }
        XCTAssertTrue(head.isExpanded)

        let items = safe.rows.compactMap { if case .item(let i) = $0 { i } else { nil } }
        XCTAssertEqual(items.map(\.title), [
            "~/lane-builds/lane-a/node_modules", "~/lane-builds/lane-a/ios/Pods",
            "~/lane-builds/lane-b/node_modules", "~/lane-builds/lane-c/node_modules",
        ])
        XCTAssertEqual(items.map(\.sizeText), ["1.4 GB", "0.9 GB", "0.8 GB", "0.5 GB"])
        XCTAssertEqual(items.map(\.isTicked), [true, true, true, true])
        XCTAssertEqual(items.first?.detail, "lane lane-a: untouched for 12 days", "the engine's note rides along")

        guard case .footnote(let note) = safe.rows[5] else { return XCTFail("the footnote closes the group: \(safe.rows[5])") }
        XCTAssertEqual(note.text, "Rebuild with npm ci or pod install.")
        guard case .group(let next) = safe.rows[6] else { return XCTFail("the next group follows") }
        XCTAssertEqual(next.title, "uv cache")
    }

    func testTheGroupAfterAnOpenOneGetsAirAboveIt() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.rule == "lane-deps" })
        let open = DetailsModel(selection: selection, expanded: [lanes.id], home: home)
        let closed = DetailsModel(selection: selection, expanded: [], home: home)

        let after = groups(try XCTUnwrap(open.sections.first)).map(\.followsOpenGroup)
        XCTAssertEqual(after, [false, true, false, false, false, false], "only uv cache follows the open lane group")
        XCTAssertTrue(closed.sections.flatMap { groups($0) }.allSatisfy { !$0.followsOpenGroup })
        XCTAssertFalse(groups(try XCTUnwrap(open.sections.first { $0.kind == .review })).first?.followsOpenGroup ?? true,
                       "a new section has its own header and spacing")
    }

    func testFileRowsStayOnOneLineButACommandsNoteIsAlwaysWritten() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let ids = Set(selection.groups.filter { $0.rule == "lane-deps" || $0.rule == "homebrew" || $0.section == .review }.map(\.id))
        let details = DetailsModel(selection: selection, expanded: ids, home: home)
        let items = details.sections.flatMap(\.rows).compactMap { row -> DetailsModel.ItemRow? in
            if case .item(let item) = row { item } else { nil }
        }

        let files = items.filter { $0.item.action == .delete }
        XCTAssertEqual(files.count, 4)
        XCTAssertTrue(files.allSatisfy { !$0.showsDetail }, "the board's lane rows are one line")
        XCTAssertTrue(files.allSatisfy { $0.detail != nil }, "but the note is still there for the tooltip and VoiceOver")

        let commands = items.filter { $0.item.action == .command }
        XCTAssertEqual(commands.count, 4, "homebrew and three docker items")
        XCTAssertTrue(commands.allSatisfy(\.showsDetail))
    }

    func testOnlyTheExpandedGroupOpens() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let uv = try XCTUnwrap(selection.groups.first { $0.rule == "uv-cache" })
        let details = DetailsModel(selection: selection, expanded: [uv.id], home: home)
        let items = details.sections.flatMap(\.rows).compactMap { if case .item(let i) = $0 { i } else { nil } }
        XCTAssertEqual(items.map(\.title), ["~/.cache/uv"])
    }

    func testACommandItemKeepsItsLabelAsTitleAndItsNoteAsDetail() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let docker = try XCTUnwrap(selection.groups.first { $0.section == .review })
        let details = DetailsModel(selection: selection, expanded: [docker.id], home: home)
        let items = details.sections.flatMap(\.rows).compactMap { if case .item(let i) = $0 { i } else { nil } }
        XCTAssertEqual(items.map(\.title), ["docker: unused images", "docker: build cache", "docker: stopped containers"])
        XCTAssertEqual(items.map(\.sizeText), ["6.2 GB", "2.0 GB", "0.8 GB"])
        XCTAssertTrue(items.allSatisfy { !$0.isTicked })
        XCTAssertTrue(try XCTUnwrap(items.first?.detail).contains("frees space inside Docker's disk image"))
    }

    // MARK: held back

    func testHeldRowsComeFromTheGuardsSkips() throws {
        let held = try XCTUnwrap(try model().sections.first { $0.kind == .held })
        XCTAssertEqual(held.rows.count, 1)
        guard case .held(let row) = held.rows[0] else { return XCTFail("a held row") }
        XCTAssertEqual(row.title, "Unavailable simulators")
        XCTAssertEqual(row.detail, "Simulator is running · offered again next scan")
    }

    func testManualAndUnknownTiersAreListedAsHeldAndCannotBeTicked() throws {
        let details = try model("plan-mixed-tiers.json")
        let held = try XCTUnwrap(details.sections.first { $0.kind == .held })
        guard case .held(let row) = held.rows[0] else { return XCTFail("a held row") }
        XCTAssertEqual(row.title, "Needs a person")
        XCTAssertEqual(row.sizeText, "4.1 GB")
        XCTAssertTrue(row.detail.hasPrefix("Not offered here"), row.detail)
        XCTAssertFalse(details.focusableIDs.contains { $0.contains("Needs a person") }, "nothing to tick, nothing to focus")
    }

    // MARK: accessibility strings

    func testGroupAndItemRowsReadAsOneSentence() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.rule == "lane-deps" })
        let details = DetailsModel(selection: selection, expanded: [lanes.id], home: home)
        let safe = try XCTUnwrap(details.sections.first)

        guard case .group(let group) = safe.rows[0], case .item(let item) = safe.rows[1] else { return XCTFail("rows") }
        XCTAssertEqual(group.accessibilityLabel, "Idle lane dependencies, 4 items, 3.6 GB")
        XCTAssertEqual(group.accessibilityValue, "selected, expanded")
        XCTAssertEqual(item.accessibilityLabel, "~/lane-builds/lane-a/node_modules")
        XCTAssertEqual(item.accessibilityValue, "selected, 1.4 GB, lane lane-a: untouched for 12 days")
    }

    func testStatesAreSpokenInWords() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.rule == "lane-deps" })
        selection.toggle(lanes.items[0])
        let details = DetailsModel(selection: selection, expanded: [], home: home)
        let rows = groups(try XCTUnwrap(details.sections.first))
        XCTAssertEqual(rows[0].accessibilityValue, "partly selected, collapsed")

        let docker = groups(try XCTUnwrap(details.sections.first { $0.kind == .review }))[0]
        XCTAssertEqual(docker.accessibilityValue, "not selected, collapsed")
        XCTAssertEqual(docker.accessibilityLabel, "Docker, 3 items, 9.0 GB, needs your review")
    }

    // MARK: focus order

    func testFocusableRowsAreTheTickableGroupsAndItemsInVisualOrder() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        let lanes = try XCTUnwrap(selection.groups.first { $0.rule == "lane-deps" })
        let details = DetailsModel(selection: selection, expanded: [lanes.id], home: home)
        let ids = details.focusableIDs

        XCTAssertEqual(ids.first, "group:\(lanes.id)")
        XCTAssertEqual(ids.prefix(5).dropFirst().map { $0.hasPrefix("item:") }, [true, true, true, true])
        XCTAssertEqual(ids.filter { $0.hasPrefix("group:") }.count, 7, "six safe groups and Docker")
        XCTAssertFalse(ids.contains { $0.hasPrefix("held:") || $0.hasPrefix("footnote:") })
    }
}
