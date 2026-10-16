import XCTest
@testable import CmmKit

/// The tiles of the map face: one per tickable item, except that the prunes of one group of commands (Docker's three)
/// are a single tile that ticks them all; their sizes, names, states, the words on them by size, and the words under
/// the map.
final class MapModelTests: XCTestCase {
    private let home = "/Users/test"
    private let boardSize = CGSize(width: 416, height: 520)

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    private func selection(_ name: String = "plan-c.json") throws -> SelectionModel {
        SelectionModel(plan: try TestPlans.fixture(name))
    }

    private func model(_ selection: SelectionModel, size: CGSize? = nil) -> MapModel {
        MapModel(selection: selection, size: size ?? boardSize, home: home)
    }

    private func tile(_ model: MapModel, _ title: String, _ subtitle: String? = nil) throws -> MapTile {
        try XCTUnwrap(model.tiles.first { $0.title == title && $0.subtitle == subtitle }, "\(title) \(subtitle ?? "")")
    }

    // MARK: which tiles

    func testOneTilePerItemExceptThatDockersThreePrunesAreOne() throws {
        let map = model(try selection())
        XCTAssertEqual(map.tiles.count, 10, "nine safe items and Docker's group")
        let docker = try tile(map, "Docker")
        guard case .group(let group) = docker.target else { return XCTFail("Docker is a group tile") }
        XCTAssertEqual(group.count, 3)
        XCTAssertEqual(docker.itemCount, 3)
        XCTAssertEqual(docker.bytes, gb(9.0))
    }

    func testTheOtherTilesAreItemTiles() throws {
        let map = model(try selection())
        for tile in map.tiles where tile.title != "Docker" {
            guard case .item(let item) = tile.target else { return XCTFail("\(tile.title) is an item tile") }
            XCTAssertEqual(tile.bytes, item.bytes)
            XCTAssertEqual(tile.itemCount, 1)
        }
    }

    func testOnlyTheTickableTiersAreOnTheMap() throws {
        let map = model(try selection("plan-mixed-tiers.json"))
        let paths = map.tiles.compactMap { tile -> String? in
            if case .item(let item) = tile.target { return item.path }
            return nil
        }
        XCTAssertEqual(Set(paths), [
            "/Users/test/Library/Caches/go-build", "/Users/test/Library/Caches/cursor-updater/pending",
            "/Users/test/Library/Caches/cursor-updater/old",
        ], "no manual item, no unknown tier")
        XCTAssertEqual(map.tiles.count, 3)
    }

    func testAGroupOfOneCommandIsItsOwnItemTile() throws {
        let map = model(try selection())
        let brew = try tile(map, "Homebrew")
        guard case .item(let item) = brew.target else { return XCTFail("one command is an item tile") }
        XCTAssertEqual(item.path, "homebrew: cleanup")
    }

    func testACommandNextToFilesInOneGroupStaysAnItemTile() {
        let plan = TestPlans.plan([
            TestPlans.item("/a/one", group: "Mixed", rule: "x", bytes: gb(2)),
            TestPlans.item("x: prune", group: "Mixed", rule: "x", bytes: gb(1), action: .command),
        ], capacityBytes: gb(100))
        let map = model(SelectionModel(plan: plan))
        XCTAssertEqual(map.tiles.count, 2)
        XCTAssertTrue(map.tiles.allSatisfy { if case .item = $0.target { true } else { false } })
    }

    func testAnEmptyPlanHasNoTiles() throws {
        let map = model(SelectionModel(plan: try TestPlans.fixture("plan-empty.json")))
        XCTAssertTrue(map.tiles.isEmpty)
        XCTAssertNil(map.reviewTileID)
    }

    // MARK: where

    func testTheTilesAreInLayoutOrderLargestFirstAndLandOnTheBoard() throws {
        let map = model(try selection())
        XCTAssertEqual(map.tiles.map(\.title), [
            "Docker", "lane-a", "lane-a", "lane-b", "lane-c", "uv cache", "Go build cache", "Homebrew", "npm cache", "bun cache",
        ])
        let board: [(String, String?, Double, Double, Double, Double)] = [
            ("Docker", nil, 3, 3, 410, 263), ("lane-a", "node_modules", 3, 272, 172, 93), ("lane-a", "ios/Pods", 3, 368, 132, 77),
            ("lane-b", "node_modules", 3, 449, 132, 68), ("lane-c", "node_modules", 138, 368, 37, 149),
            ("uv cache", "~/.cache/uv", 181, 272, 232, 125), ("Go build cache", "~/Library/Caches/go-build", 181, 403, 118, 114),
            ("Homebrew", nil, 305, 403, 108, 71), ("npm cache", "~/.npm/_cacache", 305, 479, 79, 38),
            ("bun cache", "~/.bun/install/cache", 391, 479, 22, 38),
        ]
        for (title, sub, x, y, w, h) in board {
            let rect = try tile(map, title, sub).rect
            XCTAssertEqual(rect.minX, x, accuracy: 0.6, title)
            XCTAssertEqual(rect.minY, y, accuracy: 0.6, title)
            XCTAssertEqual(rect.width, w, accuracy: 0.6, title)
            XCTAssertEqual(rect.height, h, accuracy: 0.6, title)
        }
    }

    func testTheLayoutDoesNotDependOnWhatIsTicked() throws {
        var selection = try selection()
        let before = model(selection).tiles.map(\.rect)
        selection.toggle(try XCTUnwrap(selection.groups.first { $0.section == .review }))
        XCTAssertEqual(model(selection).tiles.map(\.rect), before, "ticking never moves a tile")
    }

    // MARK: names

    func testTheBoardsNames() throws {
        let map = model(try selection())
        XCTAssertEqual(try tile(map, "lane-a", "node_modules").bytes, gb(1.4))
        XCTAssertEqual(try tile(map, "lane-a", "ios/Pods").bytes, gb(0.9))
        XCTAssertEqual(try tile(map, "lane-b", "node_modules").bytes, gb(0.8))
        XCTAssertEqual(try tile(map, "lane-c", "node_modules").bytes, gb(0.5))
        XCTAssertNil(try tile(map, "Docker").subtitle, "a group of prunes has no path")
        XCTAssertNil(try tile(map, "Homebrew").subtitle, "a command has no path")
        XCTAssertEqual(try tile(map, "uv cache", "~/.cache/uv").sizeText, "2.5 GB")
    }

    func testItemsOfAGroupAreNamedByWhatTheirPathsDoNotShare() {
        let plan = TestPlans.plan([
            TestPlans.item("/Users/test/proj/app-one/build", group: "Builds", rule: "b", bytes: gb(2)),
            TestPlans.item("/Users/test/proj/app-two/build/intermediates", group: "Builds", rule: "b", bytes: gb(1)),
        ], capacityBytes: gb(100))
        let map = model(SelectionModel(plan: plan))
        XCTAssertEqual(map.tiles.map(\.title), ["app-one", "app-two"])
        XCTAssertEqual(map.tiles.map(\.subtitle), ["build", "build/intermediates"])
    }

    func testItemsWithNothingInCommonAreNamedByTheirLastFolderAndShowWhereTheyAre() {
        let plan = TestPlans.plan([
            TestPlans.item("/Users/test/Library/Caches/alpha", group: "Caches", rule: "c", bytes: gb(2)),
            TestPlans.item("/opt/other/beta", group: "Caches", rule: "c", bytes: gb(1)),
        ], capacityBytes: gb(100))
        let map = model(SelectionModel(plan: plan))
        XCTAssertEqual(map.tiles.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(map.tiles.map(\.subtitle), ["~/Library/Caches", "/opt/other"])
    }

    func testAnUnknownRuleIsNamedByItsOwnLabel() {
        let plan = TestPlans.plan([TestPlans.item("/Users/test/x", group: "Some new cache (rebuilds)", rule: "some-new", bytes: gb(1))])
        XCTAssertEqual(model(SelectionModel(plan: plan)).tiles.first?.title, "Some new cache")
    }

    // MARK: state

    func testStateFollowsTheSelection() throws {
        var selection = try selection()
        var map = model(selection)
        XCTAssertEqual(try tile(map, "lane-a", "node_modules").state, .on)
        XCTAssertEqual(try tile(map, "Docker").state, .off, "review is never ticked for you")

        selection.toggle(try XCTUnwrap(selection.groups.first { $0.rule == "uv-cache" }?.items.first))
        map = model(selection)
        XCTAssertEqual(try tile(map, "uv cache", "~/.cache/uv").state, .off)
    }

    func testAGroupTileTicksAndUnticksAllOfItsItemsAndIsMixedInBetween() throws {
        var selection = try selection()
        let group = try XCTUnwrap(selection.groups.first { $0.section == .review })
        selection.toggle(group.items[0])
        XCTAssertEqual(try tile(model(selection), "Docker").state, .mixed)
        selection.toggle(group)  // the group tile's own action
        XCTAssertEqual(try tile(model(selection), "Docker").state, .on, "a half-ticked group becomes fully ticked")
        selection.toggle(group)
        XCTAssertEqual(try tile(model(selection), "Docker").state, .off)
    }

    func testReviewTilesAreMarkedAndAreNeverPreTicked() throws {
        let map = model(try selection())
        XCTAssertEqual(map.tiles.filter(\.isReview).map(\.title), ["Docker"])
        XCTAssertTrue(map.tiles.filter(\.isReview).allSatisfy { $0.state == .off })
    }

    func testTheReviewTileIsTheBiggestReviewOne() throws {
        XCTAssertEqual(model(try selection()).reviewTileID, "group:review/Docker: unused images, stopped containers and build cache (review first)")
        let mixed = model(try selection("plan-mixed-tiers.json"))
        XCTAssertEqual(mixed.reviewTileID, "item:/Users/test/Library/Caches/cursor-updater/pending")
        XCTAssertNil(model(SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))).reviewTileID)
    }

    func testTilesKnowWhereTheirSpaceGoes() throws {
        let map = model(try selection())
        XCTAssertTrue(try tile(map, "Docker").freesInside, "Docker's prunes free space inside its disk image")
        XCTAssertFalse(try tile(map, "uv cache", "~/.cache/uv").freesInside)
    }

    // MARK: finding a tile

    func testFindsATileByIdAndByPoint() throws {
        let map = model(try selection())
        let docker = try tile(map, "Docker")
        XCTAssertEqual(map.tile(id: docker.id)?.title, "Docker")
        XCTAssertNil(map.tile(id: "nope"))
        XCTAssertEqual(map.tile(at: CGPoint(x: 200, y: 100))?.id, docker.id)
        XCTAssertNil(map.tile(at: CGPoint(x: 1, y: 1)), "the half-gap at the edge is no tile")
        XCTAssertNil(map.tile(at: CGPoint(x: 178, y: 300)), "nor is the gap between two")
    }

    func testTheReclaimableTotalIsEveryTilesBytes() throws {
        XCTAssertEqual(model(try selection()).totalBytes, gb(17.4))
    }
}
