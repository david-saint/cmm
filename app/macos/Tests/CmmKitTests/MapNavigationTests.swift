import XCTest
@testable import CmmKit

/// Keys on the map: the arrows move the focus to the neighbouring tile in the direction pressed, Space (and Return) ticks
/// it, Home and End jump to the first and last. Pure, so it is tested on the board's layout without a window.
final class MapNavigationTests: XCTestCase {
    private let home = "/Users/test"

    private func map() throws -> MapModel {
        MapModel(selection: SelectionModel(plan: try TestPlans.fixture("plan-c.json")), size: CGSize(width: 416, height: 520), home: home)
    }

    private func id(_ map: MapModel, _ title: String, _ subtitle: String? = nil) throws -> String {
        try XCTUnwrap(map.tiles.first { $0.title == title && $0.subtitle == subtitle }, "\(title) \(subtitle ?? "")").id
    }

    private func move(_ key: MapNavigation.Key, from id: String?, in map: MapModel) -> String? {
        if case .focus(let target) = MapNavigation.handle(key, focused: id, in: map) { return target }
        return nil
    }

    // MARK: the arrows

    func testDownFromDockerIsTheTileBelowItsCentre() throws {
        let map = try map()
        // Docker spans the width; its centre is under uv cache, which is nearer than the lane tile
        XCTAssertEqual(move(.down, from: try id(map, "Docker"), in: map), try id(map, "uv cache", "~/.cache/uv"))
    }

    func testRightAndLeftBetweenTheLaneTilesAndUv() throws {
        let map = try map()
        let laneA = try id(map, "lane-a", "node_modules")
        let uv = try id(map, "uv cache", "~/.cache/uv")
        XCTAssertEqual(move(.right, from: laneA, in: map), uv)
        XCTAssertEqual(move(.left, from: uv, in: map), laneA, "the lane tile level with uv's middle, not the tall thin one below")
    }

    func testDownInsideAGroupGoesToTheNeighbourWhoseCentreIsNearest() throws {
        let map = try map()
        XCTAssertEqual(move(.down, from: try id(map, "lane-a", "node_modules"), in: map), try id(map, "lane-a", "ios/Pods"))
        XCTAssertEqual(move(.down, from: try id(map, "lane-a", "ios/Pods"), in: map), try id(map, "lane-b", "node_modules"))
        XCTAssertEqual(move(.right, from: try id(map, "lane-a", "ios/Pods"), in: map), try id(map, "lane-c", "node_modules"))
    }

    func testUpFromTheLastTileIsTheOneAboveIt() throws {
        let map = try map()
        XCTAssertEqual(move(.left, from: try id(map, "bun cache", "~/.bun/install/cache"), in: map), try id(map, "npm cache", "~/.npm/_cacache"))
        XCTAssertEqual(move(.up, from: try id(map, "bun cache", "~/.bun/install/cache"), in: map), try id(map, "Homebrew"))
    }

    func testThereIsNothingBeyondTheEdges() throws {
        let map = try map()
        let docker = try id(map, "Docker")
        XCTAssertEqual(MapNavigation.handle(.up, focused: docker, in: map), .none)
        XCTAssertEqual(MapNavigation.handle(.left, focused: docker, in: map), .none)
        let bun = try id(map, "bun cache", "~/.bun/install/cache")
        XCTAssertEqual(MapNavigation.handle(.down, focused: bun, in: map), .none)
        XCTAssertEqual(MapNavigation.handle(.right, focused: bun, in: map), .none)
    }

    func testEveryTileCanBeReachedByTheArrowsFromTheFirst() throws {
        let map = try map()
        var seen: Set<String> = [try XCTUnwrap(map.tiles.first?.id)]
        var frontier = [try XCTUnwrap(map.tiles.first?.id)]
        while let current = frontier.popLast() {
            for key in [MapNavigation.Key.up, .down, .left, .right] {
                if let next = move(key, from: current, in: map), seen.insert(next).inserted { frontier.append(next) }
            }
        }
        XCTAssertEqual(seen.count, map.tiles.count, "no tile is out of the arrows' reach, however small")
    }

    func testAnArrowMovesToADifferentTileEveryTime() throws {
        let map = try map()
        for tile in map.tiles {
            for key in [MapNavigation.Key.up, .down, .left, .right] {
                XCTAssertNotEqual(move(key, from: tile.id, in: map), tile.id)
            }
        }
    }

    // MARK: with no focus yet

    func testAnyArrowWithNoFocusFocusesTheFirstTile() throws {
        let map = try map()
        let first = try XCTUnwrap(map.tiles.first?.id)
        for key in [MapNavigation.Key.up, .down, .left, .right] {
            XCTAssertEqual(move(key, from: nil, in: map), first)
        }
        XCTAssertEqual(move(.down, from: "item:/gone", in: map), first, "a focus on a tile that is gone is no focus")
    }

    func testHomeAndEnd() throws {
        let map = try map()
        XCTAssertEqual(move(.home, from: try id(map, "uv cache", "~/.cache/uv"), in: map), map.tiles.first?.id)
        XCTAssertEqual(move(.end, from: try id(map, "uv cache", "~/.cache/uv"), in: map), map.tiles.last?.id)
        XCTAssertEqual(move(.end, from: nil, in: map), map.tiles.last?.id)
    }

    // MARK: ticking

    func testSpaceAndReturnTickTheFocusedTileAndNothingElse() throws {
        let map = try map()
        let uv = try id(map, "uv cache", "~/.cache/uv")
        XCTAssertEqual(MapNavigation.handle(.space, focused: uv, in: map), .toggle(uv))
        XCTAssertEqual(MapNavigation.handle(.return, focused: uv, in: map), .toggle(uv))
        XCTAssertEqual(MapNavigation.handle(.space, focused: nil, in: map), .none, "nothing is focused: nothing is ticked")
        XCTAssertEqual(MapNavigation.handle(.space, focused: "item:/gone", in: map), .none)
    }

    func testAnEmptyMapHasNothingToDo() throws {
        let empty = MapModel(selection: SelectionModel(plan: try TestPlans.fixture("plan-empty.json")), size: CGSize(width: 416, height: 520), home: home)
        for key in [MapNavigation.Key.up, .down, .left, .right, .home, .end, .space, .return] {
            XCTAssertEqual(MapNavigation.handle(key, focused: nil, in: empty), .none)
        }
    }

    func testTheFocusIsValidOnlyWhileItsTileExists() throws {
        let map = try map()
        let docker = try id(map, "Docker")
        XCTAssertEqual(MapNavigation.validFocus(docker, in: map), docker)
        XCTAssertNil(MapNavigation.validFocus("item:/gone", in: map))
        XCTAssertNil(MapNavigation.validFocus(nil, in: map))
    }
}
