import XCTest
@testable import CmmKit

/// The squarified treemap under the map face: rectangles for weights, then tiles for items in groups, with the gaps of
/// the board (6 pt between groups, 3 pt inside one). The expected numbers of the board were worked out with a separate
/// implementation of the same algorithm (and agree with the board's own rectangles to half a point).
final class TreemapTests: XCTestCase {
    private func area(_ r: CGRect) -> Double { r.width * r.height }

    private func assertRect(_ r: CGRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, accuracy: Double = 0.06,
                            _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: accuracy, "y \(message)", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: accuracy, "w \(message)", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: accuracy, "h \(message)", file: file, line: line)
    }

    // MARK: squarify

    func testOneWeightFillsTheContainer() {
        let rects = Treemap.squarify(weights: [5], in: CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(rects, [CGRect(x: 10, y: 20, width: 300, height: 200)])
    }

    func testNothingToLayOutIsNothing() {
        XCTAssertEqual(Treemap.squarify(weights: [], in: CGRect(x: 0, y: 0, width: 100, height: 100)), [])
    }

    func testAnEmptyContainerGivesEmptyRectsInTheSameNumber() {
        let rects = Treemap.squarify(weights: [3, 2, 1], in: .zero)
        XCTAssertEqual(rects.count, 3)
        XCTAssertTrue(rects.allSatisfy { $0.width == 0 || $0.height == 0 })
    }

    func testAreasAreProportionalToTheWeights() {
        // The example of the squarified-treemaps paper: 6 6 4 3 2 2 1 in 600 x 400.
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let container = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = Treemap.squarify(weights: weights, in: container)
        XCTAssertEqual(rects.count, 7)
        for (index, rect) in rects.enumerated() {
            XCTAssertEqual(area(rect), weights[index] / 24 * area(container), accuracy: 1e-6, "weight \(weights[index])")
        }
        // and, as in the paper, the first row is a column of the two sixes and the four down the left side
        XCTAssertEqual(rects[0].minX, 0, accuracy: 1e-9)
        XCTAssertEqual(rects[0].width, rects[1].width, accuracy: 1e-9)
        XCTAssertEqual(rects[0].width, 300, accuracy: 1e-6)
    }

    func testTheRectsFillTheContainerAndNeverOverlap() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let count = Int.random(in: 1...60, using: &generator)
            let weights = (0..<count).map { _ in Double.random(in: 0.05...50, using: &generator) }.sorted(by: >)
            let container = CGRect(x: Double.random(in: 0...20), y: Double.random(in: 0...20),
                                   width: Double.random(in: 80...900), height: Double.random(in: 80...900))
            let rects = Treemap.squarify(weights: weights, in: container)
            XCTAssertEqual(rects.count, count)
            XCTAssertEqual(rects.reduce(0) { $0 + area($1) }, area(container), accuracy: 1e-6 * area(container))
            for rect in rects {
                XCTAssertGreaterThanOrEqual(rect.minX, container.minX - 1e-6)
                XCTAssertGreaterThanOrEqual(rect.minY, container.minY - 1e-6)
                XCTAssertLessThanOrEqual(rect.maxX, container.maxX + 1e-6)
                XCTAssertLessThanOrEqual(rect.maxY, container.maxY + 1e-6)
            }
            for i in 0..<count {
                for j in (i + 1)..<max(count, i + 1) {
                    let overlap = rects[i].intersection(rects[j])
                    XCTAssertLessThan(overlap.isNull ? 0 : area(overlap), 1e-6, "\(i) and \(j) overlap")
                }
            }
        }
    }

    func testTheSameInputGivesTheSameRects() {
        let weights: [Double] = [9, 3.6, 2.5, 1.2, 0.7, 0.3, 0.1]
        let container = CGRect(x: 0, y: 0, width: 416, height: 520)
        XCTAssertEqual(Treemap.squarify(weights: weights, in: container), Treemap.squarify(weights: weights, in: container))
    }

    func testTheBoardsGroupsLandWhereTheBoardPutsThem() {
        let rects = Treemap.squarify(weights: [9.0, 3.6, 2.5, 1.2, 0.7, 0.3, 0.1], in: CGRect(x: 0, y: 0, width: 416, height: 520))
        assertRect(rects[0], 0, 0, 416.0, 269.0, "Docker")
        assertRect(rects[1], 0, 269.0, 178.3, 251.0, "lane dependencies")
        assertRect(rects[2], 178.3, 269.0, 237.7, 130.7, "uv cache")
        assertRect(rects[3], 178.3, 399.7, 124.0, 120.3, "Go build cache")
        assertRect(rects[4], 302.3, 399.7, 113.7, 76.5, "Homebrew")
        assertRect(rects[5], 302.3, 476.3, 85.3, 43.7, "npm cache")
        assertRect(rects[6], 387.6, 476.3, 28.4, 43.7, "bun cache")
    }

    func testZeroWeightsDoNotBreakIt() {
        let rects = Treemap.squarify(weights: [0, 0, 0], in: CGRect(x: 0, y: 0, width: 90, height: 30))
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects.reduce(0) { $0 + area($1) }, 2700, accuracy: 1e-6, "split evenly rather than vanish")
    }

    // MARK: the map's tiles

    private typealias Group = MapLayout.Group
    private typealias Entry = MapLayout.Entry

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    /// The board's data: Docker (one tile), four lane items, and five single-item groups.
    private func boardGroups() -> [Group] {
        [
            Group(id: "docker", entries: [Entry(id: "docker", bytes: gb(9.0))]),
            Group(id: "lanes", entries: [
                Entry(id: "lane-a nm", bytes: gb(1.4)), Entry(id: "lane-a pods", bytes: gb(0.9)),
                Entry(id: "lane-b", bytes: gb(0.8)), Entry(id: "lane-c", bytes: gb(0.5)),
            ]),
            Group(id: "uv", entries: [Entry(id: "uv", bytes: gb(2.5))]),
            Group(id: "go", entries: [Entry(id: "go", bytes: gb(1.2))]),
            Group(id: "brew", entries: [Entry(id: "brew", bytes: gb(0.7))]),
            Group(id: "npm", entries: [Entry(id: "npm", bytes: gb(0.3))]),
            Group(id: "bun", entries: [Entry(id: "bun", bytes: gb(0.1))]),
        ]
    }

    func testTheBoardsTilesLandWithinHalfAPointOfTheBoard() throws {
        let layout = MapLayout(groups: boardGroups(), size: CGSize(width: 416, height: 520))
        let board: [(String, Double, Double, Double, Double)] = [
            ("docker", 3, 3, 410, 263), ("lane-a nm", 3, 272, 172, 93), ("lane-a pods", 3, 368, 132, 77),
            ("lane-b", 3, 449, 132, 68), ("lane-c", 138, 368, 37, 149), ("uv", 181, 272, 232, 125),
            ("go", 181, 403, 118, 114), ("brew", 305, 403, 108, 71), ("npm", 305, 479, 79, 38), ("bun", 391, 479, 22, 38),
        ]
        for (id, x, y, w, h) in board {
            assertRect(try XCTUnwrap(layout.frames[id], id), x, y, w, h, accuracy: 0.6, id)
        }
    }

    func testTheOrderIsLargestGroupFirstThenLargestItemFirst() {
        let layout = MapLayout(groups: boardGroups().reversed(), size: CGSize(width: 416, height: 520))
        XCTAssertEqual(layout.order, ["docker", "lane-a nm", "lane-a pods", "lane-b", "lane-c", "uv", "go", "brew", "npm", "bun"])
    }

    func testGapsAreSixBetweenGroupsAndThreeInsideOne() throws {
        let layout = MapLayout(groups: boardGroups(), size: CGSize(width: 416, height: 520))
        func frame(_ id: String) throws -> CGRect { try XCTUnwrap(layout.frames[id], id) }
        let (docker, laneA, pods, laneC, uv, go) = (
            try frame("docker"), try frame("lane-a nm"), try frame("lane-a pods"), try frame("lane-c"), try frame("uv"), try frame("go")
        )
        // inside the lane group
        XCTAssertEqual(pods.minY - laneA.maxY, 3, accuracy: 1e-6)
        XCTAssertEqual(laneC.minX - pods.maxX, 3, accuracy: 1e-6)
        // between groups
        XCTAssertEqual(uv.minX - laneA.maxX, 6, accuracy: 1e-6)
        XCTAssertEqual(laneA.minY - docker.maxY, 6, accuracy: 1e-6)
        XCTAssertEqual(go.minY - uv.maxY, 6, accuracy: 1e-6)
        // and half a gap to the container's edge
        XCTAssertEqual(docker.minX, 3, accuracy: 1e-6)
        XCTAssertEqual(docker.minY, 3, accuracy: 1e-6)
        XCTAssertEqual(uv.maxX, 413, accuracy: 1e-6)
    }

    func testTilesStayInsideTheContainerAndNeverOverlap() {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<30 {
            let groups = (0..<Int.random(in: 1...12, using: &generator)).map { g in
                Group(id: "g\(g)", entries: (0..<Int.random(in: 1...8, using: &generator)).map { i in
                    Entry(id: "g\(g)-\(i)", bytes: Int64.random(in: 1_000...9_000_000_000, using: &generator))
                })
            }
            let size = CGSize(width: Double.random(in: 200...520, using: &generator), height: Double.random(in: 200...700, using: &generator))
            let layout = MapLayout(groups: groups, size: size)
            let rects = layout.order.compactMap { layout.frames[$0] }
            XCTAssertEqual(rects.count, groups.reduce(0) { $0 + $1.entries.count }, "round \(round)")
            for rect in rects {
                XCTAssertGreaterThanOrEqual(rect.minX, -1e-6)
                XCTAssertGreaterThanOrEqual(rect.minY, -1e-6)
                XCTAssertLessThanOrEqual(rect.maxX, size.width + 1e-6)
                XCTAssertLessThanOrEqual(rect.maxY, size.height + 1e-6)
            }
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let overlap = rects[i].intersection(rects[j])
                    XCTAssertLessThan(overlap.isNull ? 0 : overlap.width * overlap.height, 1e-6, "round \(round): \(i) and \(j)")
                }
            }
        }
    }

    func testAreaIsProportionalToBytesAmongTilesThatAreBigEnoughToMeasure() throws {
        let layout = MapLayout(groups: boardGroups(), size: CGSize(width: 416, height: 520))
        let docker = try XCTUnwrap(layout.frames["docker"])
        let uv = try XCTUnwrap(layout.frames["uv"])
        let ratio = (docker.width * docker.height) / (uv.width * uv.height)
        XCTAssertEqual(ratio, 9.0 / 2.5, accuracy: 0.25, "the gaps take a sliver, nothing more")
    }

    func testATinyItemStillGetsATileYouCanReach() throws {
        let groups = [
            Group(id: "big", entries: [Entry(id: "big", bytes: 1_000_000_000_000)]),
            Group(id: "tiny", entries: [Entry(id: "tiny", bytes: 1)]),
        ]
        let layout = MapLayout(groups: groups, size: CGSize(width: 416, height: 520))
        let tiny = try XCTUnwrap(layout.frames["tiny"])
        XCTAssertGreaterThanOrEqual(min(tiny.width, tiny.height), MapLayout.minimumSide - 0.01)
        let big = try XCTUnwrap(layout.frames["big"])
        XCTAssertGreaterThan(big.width * big.height, 0.85 * 416 * 520)
    }

    func testSeveralTinyItemsAreAllReachable() throws {
        var entries = [Entry(id: "big", bytes: 40_000_000_000)]
        entries += (0..<6).map { Entry(id: "tiny\($0)", bytes: Int64(10_000 + $0)) }
        let layout = MapLayout(groups: [Group(id: "one", entries: entries)], size: CGSize(width: 416, height: 520))
        for id in layout.order {
            let rect = try XCTUnwrap(layout.frames[id])
            XCTAssertGreaterThanOrEqual(min(rect.width, rect.height), MapLayout.minimumSide - 0.01, id)
        }
    }

    func testEveryItemOfAHugePlanStillHasATile() {
        let groups = (0..<40).map { g in
            Group(id: "g\(g)", entries: (0..<25).map { Entry(id: "g\(g)-\($0)", bytes: Int64(1_000_000 * (g + 1) + $0)) })
        }
        let layout = MapLayout(groups: groups, size: CGSize(width: 416, height: 520))
        XCTAssertEqual(layout.order.count, 1000)
        XCTAssertTrue(layout.order.allSatisfy { layout.frames[$0] != nil })
    }

    func testZeroByteItemsAndAnEmptyPlanDoNotBreakIt() {
        XCTAssertTrue(MapLayout(groups: [], size: CGSize(width: 416, height: 520)).order.isEmpty)
        let layout = MapLayout(
            groups: [Group(id: "z", entries: [Entry(id: "a", bytes: 0), Entry(id: "b", bytes: 0)])], size: CGSize(width: 416, height: 520)
        )
        XCTAssertEqual(layout.order.count, 2)
        XCTAssertNotNil(layout.frames["a"])
    }

    func testAContainerTooSmallToHoldTheGapsStillGivesFrames() {
        let layout = MapLayout(groups: boardGroups(), size: CGSize(width: 20, height: 20))
        XCTAssertEqual(layout.order.count, 10)
        XCTAssertTrue(layout.frames.values.allSatisfy { $0.width >= 0 && $0.height >= 0 })
    }
}
