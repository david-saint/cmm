import XCTest
@testable import CmmKit

/// The disk band as the doorway to the map: hovered, or while the map is open, its reclaimable end is magnified five
/// times, one slice per tile, under a bracket that always says "enlarged", so the band never misleads.
final class BandMagnifierTests: XCTestCase {
    private let home = "/Users/test"

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    private func map(ticking: (inout SelectionModel) -> Void = { _ in }) throws -> MapModel {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-c.json"))
        ticking(&selection)
        return MapModel(selection: selection, size: CGSize(width: 416, height: 520), home: home)
    }

    private func magnifier(_ map: MapModel, capacity: Int64? = 228_000_000_000, free: Int64 = 19_800_000_000, width: Double = 520) throws -> BandMagnifier {
        try XCTUnwrap(BandMagnifier(capacity: capacity, free: free, tiles: map.tiles, width: width))
    }

    // MARK: the board's numbers

    func testTheBoardsBand() throws {
        let m = try magnifier(try map())
        // used 273, the magnified end 198, free 45, with a 2 pt gap between them: 520 in all
        XCTAssertEqual(m.usedWidth, 272.4, accuracy: 0.6)
        XCTAssertEqual(m.reclaimable.x, 274.4, accuracy: 0.6)
        XCTAssertEqual(m.reclaimable.width, 198.4, accuracy: 0.6)
        XCTAssertEqual(m.free.width, 45.2, accuracy: 0.6, "free keeps its true width: the band does not lie about it")
        XCTAssertEqual(m.free.x + m.free.width, 520, accuracy: 1e-9)
        XCTAssertEqual(m.usedWidth + 2 + m.reclaimable.width + 2 + m.free.width, 520, accuracy: 1e-9)
    }

    func testTheReclaimableEndIsFiveTimesItsTrueWidth() throws {
        let m = try magnifier(try map())
        let trueWidth = 17.4 / 228 * 520
        XCTAssertEqual(m.factor, 5, accuracy: 1e-9)
        XCTAssertEqual(m.reclaimable.width, 5 * trueWidth, accuracy: 1e-9)
        XCTAssertTrue(m.isEnlarged)
    }

    func testTheBracketAndCaptionAlwaysSayItIsEnlarged() throws {
        XCTAssertEqual(try magnifier(try map()).caption, "17.4 GB reclaimable, enlarged ×5")
    }

    // MARK: slices

    func testOneSlicePerTileInTileOrderWithTheTilesIds() throws {
        let map = try map()
        let m = try magnifier(map)
        XCTAssertEqual(m.slices.map(\.id), map.tiles.map(\.id))
        XCTAssertEqual(m.slices.count, 10, "Docker is one slice, not three")
    }

    func testSlicesFillTheMagnifiedEndWithOnePointBetweenThem() throws {
        let m = try magnifier(try map())
        XCTAssertEqual(m.slices.first?.x ?? -1, m.reclaimable.x, accuracy: 1e-9)
        let last = try XCTUnwrap(m.slices.last)
        XCTAssertEqual(last.x + last.width, m.reclaimable.x + m.reclaimable.width, accuracy: 1e-9)
        for (a, b) in zip(m.slices, m.slices.dropFirst()) {
            XCTAssertEqual(b.x - (a.x + a.width), 1, accuracy: 1e-9)
        }
    }

    func testSliceWidthsAreInProportionToBytesAndNeverUnderTwoPoints() throws {
        let map = try map()
        let m = try magnifier(map)
        let docker = try XCTUnwrap(m.slices.first)
        let uv = try XCTUnwrap(m.slices.first { $0.id == map.tiles.first { $0.title == "uv cache" }?.id })
        XCTAssertEqual(docker.width / uv.width, 9.0 / 2.5, accuracy: 0.15)
        XCTAssertTrue(m.slices.allSatisfy { $0.width >= 2 - 1e-9 }, "the 0.1 GB item still has a slice to point at")
    }

    func testSliceLooksFollowTheTicksAndTheHonestRule() throws {
        var map = try map()
        var looks = Dictionary(uniqueKeysWithValues: try magnifier(map).slices.map { ($0.id, $0.look) })
        let docker = try XCTUnwrap(map.tiles.first { $0.title == "Docker" })
        let uv = try XCTUnwrap(map.tiles.first { $0.title == "uv cache" })
        XCTAssertEqual(looks[docker.id], .review)
        XCTAssertEqual(looks[uv.id], .ticked)

        map = try self.map { selection in
            selection.toggle(selection.groups.first { $0.rule == "uv-cache" }!.items[0])  // unticked
            selection.toggle(selection.groups.first { $0.section == .review }!)  // Docker ticked
        }
        looks = Dictionary(uniqueKeysWithValues: try magnifier(map).slices.map { ($0.id, $0.look) })
        XCTAssertEqual(looks[uv.id], .unticked)
        XCTAssertEqual(looks[docker.id], .review, "ticked, but its space goes inside Docker's disk image: it stays dotted, not green")
    }

    func testAReviewTileTheDiskDoesGetBackTurnsGreenWhenTicked() throws {
        let plan = TestPlans.plan([
            TestPlans.item("/r", group: "Review", rule: "r", bytes: gb(4), tier: .review),
        ], freeBytes: gb(10), capacityBytes: gb(100))
        var selection = SelectionModel(plan: plan)
        let before = MapModel(selection: selection, size: CGSize(width: 416, height: 520), home: home)
        XCTAssertEqual(try magnifier(before, capacity: gb(100), free: gb(10)).slices.first?.look, .review)
        selection.toggle(selection.groups[0].items[0])
        let after = MapModel(selection: selection, size: CGSize(width: 416, height: 520), home: home)
        XCTAssertEqual(try magnifier(after, capacity: gb(100), free: gb(10)).slices.first?.look, .ticked)
    }

    // MARK: when it does not fit five times

    func testWhenTheEndIsTooBigForFiveTimesTheFactorIsWhatFitsAndIsSaid() throws {
        let plan = TestPlans.plan([TestPlans.item("/big", rule: "b", bytes: gb(50))], freeBytes: gb(10), capacityBytes: gb(100))
        let map = MapModel(selection: SelectionModel(plan: plan), size: CGSize(width: 416, height: 520), home: home)
        let m = try magnifier(map, capacity: gb(100), free: gb(10))
        XCTAssertLessThan(m.factor, 5)
        XCTAssertGreaterThan(m.factor, 1.5)
        XCTAssertEqual(m.usedWidth, BandMagnifier.minimumUsedWidth, accuracy: 1e-6, "the used track gives all it can")
        XCTAssertEqual(m.caption, "50.0 GB reclaimable, enlarged ×\(String(format: "%.1f", m.factor))")
        XCTAssertEqual(m.usedWidth + 2 + m.reclaimable.width + 2 + m.free.width, 520, accuracy: 1e-9)
    }

    func testWhenThereIsNothingToEnlargeItDoesNotClaimTo() throws {
        let plan = TestPlans.plan([TestPlans.item("/big", rule: "b", bytes: gb(85))], freeBytes: gb(5), capacityBytes: gb(100))
        let map = MapModel(selection: SelectionModel(plan: plan), size: CGSize(width: 416, height: 520), home: home)
        let m = try magnifier(map, capacity: gb(100), free: gb(5))
        XCTAssertFalse(m.isEnlarged)
        XCTAssertEqual(m.caption, "85.0 GB reclaimable")
    }

    func testNoCapacityNoBandToMagnify() throws {
        let map = try map()
        XCTAssertNil(BandMagnifier(capacity: nil, free: gb(19.8), tiles: map.tiles, width: 520))
        XCTAssertNil(BandMagnifier(capacity: gb(10), free: gb(19.8), tiles: map.tiles, width: 520), "a capacity under the free space is not believable")
    }

    func testNothingReclaimableNothingToMagnify() throws {
        XCTAssertNil(BandMagnifier(capacity: gb(228), free: gb(19.8), tiles: [], width: 520))
        XCTAssertNil(BandMagnifier(capacity: gb(228), free: gb(19.8), tiles: try map().tiles, width: 0))
    }

    func testWidthsAlwaysAddUp() throws {
        let map = try map()
        for width in [120.0, 300, 520, 876, 1400] {
            let m = try magnifier(map, width: width)
            XCTAssertEqual(m.usedWidth + 2 + m.reclaimable.width + 2 + m.free.width, width, accuracy: 1e-6, "width \(width)")
            XCTAssertGreaterThanOrEqual(m.usedWidth, 0)
            let last = try XCTUnwrap(m.slices.last)
            XCTAssertLessThanOrEqual(last.x + last.width, m.reclaimable.x + m.reclaimable.width + 1e-6)
        }
    }

    // MARK: pointing at a slice

    func testASliceIsFoundByThePointerAndTheGapsBelongToTheSliceBefore() throws {
        let map = try map()
        let m = try magnifier(map)
        let docker = try XCTUnwrap(m.slices.first)
        let second = m.slices[1]
        XCTAssertEqual(m.sliceID(atX: docker.x + 1), docker.id)
        XCTAssertEqual(m.sliceID(atX: docker.x + docker.width + 0.5), docker.id, "the gap after Docker's slice")
        XCTAssertEqual(m.sliceID(atX: second.x + second.width / 2), second.id)
        XCTAssertNil(m.sliceID(atX: 10), "the used track")
        XCTAssertNil(m.sliceID(atX: m.free.x + 5), "the free space")
        XCTAssertNil(m.sliceID(atX: -4))
    }

    func testFindsASliceByTheTilesId() throws {
        let map = try map()
        let m = try magnifier(map)
        let id = try XCTUnwrap(map.tiles.last?.id)
        XCTAssertEqual(m.slice(for: id)?.id, id)
        XCTAssertNil(m.slice(for: "nope"))
    }

    // MARK: light-up

    func testASliceLightsWhenItsTileIsHoveredAndRingsWhenItsTileIsFocused() {
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: nil, focused: nil), [])
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: "a", focused: nil), [.lit])
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: nil, focused: "a"), [.ringed])
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: "a", focused: "a"), [.lit, .ringed])
        XCTAssertEqual(BandMagnifier.emphasis(of: "a", hovered: "b", focused: "c"), [])
    }

    // MARK: the band's thickness and its bracket

    func testTheBandIsSixPointsThickAndTenWhenMagnified() {
        XCTAssertEqual(BandMagnifier.thickness(magnified: false), 6)
        XCTAssertEqual(BandMagnifier.thickness(magnified: true), 10)
        XCTAssertEqual(BandMagnifier.bracketGap, 6)
        XCTAssertEqual(BandMagnifier.bracketHeight, 5)
        XCTAssertEqual(BandMagnifier.captionGap, 4)
    }
}
