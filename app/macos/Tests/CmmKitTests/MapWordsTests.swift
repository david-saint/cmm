import XCTest
@testable import CmmKit

/// What is written on the map's tiles (by the tile's size), under the map (the caption, which follows the keyboard focus
/// and is only previewed by the pointer), and what VoiceOver says for a tile.
final class TileLabelTests: XCTestCase {
    private func level(_ w: Double, _ h: Double) -> TileLabels.Level { TileLabels.level(for: CGSize(width: w, height: h)) }

    func testNameAndSizeFromNinetySixByFiftySix() {
        XCTAssertEqual(level(96, 56), .nameAndSize)
        XCTAssertEqual(level(410, 263), .nameAndSize)
        XCTAssertEqual(level(95.9, 56), .sizeOnly)
        XCTAssertEqual(level(96, 55.9), .sizeOnly)
    }

    func testSizeOnlyFromFortyFourByTwentyEight() {
        XCTAssertEqual(level(44, 28), .sizeOnly)
        XCTAssertEqual(level(79, 38), .sizeOnly)
        XCTAssertEqual(level(43.9, 28), .badgeOnly)
        XCTAssertEqual(level(44, 27.9), .fillOnly, "too low even for a badge")
    }

    func testABadgeFromTwentyEightByTwentyEight() {
        XCTAssertEqual(level(28, 28), .badgeOnly)
        XCTAssertEqual(level(37, 149), .badgeOnly)
        XCTAssertEqual(level(27.9, 28), .fillOnly)
        XCTAssertEqual(level(28, 27.9), .fillOnly)
    }

    func testASizeThatWouldBeCutShortIsLeftOff() {
        // the size starts 30 pt in, clear of the badge: "54 MB" (37 pt wide) needs about 68 pt, "0.4 GB" (40 pt) about 70
        func level(_ width: Double, _ text: String) -> TileLabels.Level {
            TileLabels.level(for: CGSize(width: width, height: 88), sizeText: text)
        }
        XCTAssertEqual(level(46, "54 MB"), .badgeOnly, "the narrow tile that read an ellipsis on the live window")
        XCTAssertEqual(level(48, "67 MB"), .badgeOnly)
        XCTAssertEqual(level(67, "54 MB"), .badgeOnly)
        XCTAssertEqual(level(68, "54 MB"), .sizeOnly)
        XCTAssertEqual(level(71, "53 MB"), .sizeOnly)
        XCTAssertEqual(level(69, "0.4 GB"), .badgeOnly)
        XCTAssertEqual(level(72, "0.4 GB"), .sizeOnly)
        XCTAssertEqual(TileLabels.level(for: CGSize(width: 46, height: 20), sizeText: "54 MB"), .fillOnly, "the height still decides first")
        XCTAssertEqual(TileLabels.level(for: CGSize(width: 120, height: 88), sizeText: "999.9 GB"), .nameAndSize, "a tile with room for the name always has it for the size")
    }

    func testTheWidthOfASizeIsAHairOverTheRealGlyphs() {
        // measured with the system font at 12 pt medium and tabular figures
        let measured: [(String, Double)] = [
            ("55 MB", 37.43), ("0.1 GB", 39.61), ("10.0 GB", 47.35), ("999.9 GB", 55.09),
            ("250 KB", 42.67), ("12 B", 26.80), ("1.4 TB", 38.31),
        ]
        for (text, real) in measured {
            let estimate = TileLabels.sizeWidth(text)
            XCTAssertGreaterThanOrEqual(estimate, real, "never under: a size cut short is the failure (\(text))")
            XCTAssertLessThan(estimate - real, 1.0, "and not far over, or a tile loses a size that would have fit (\(text))")
        }
    }

    func testSmallerThanThatIsFillOnly() {
        XCTAssertEqual(level(22, 38), .fillOnly)
        XCTAssertEqual(level(0, 0), .fillOnly)
    }

    func testLevelsAreOrderedSoWhatFitsAtALevelFitsAtTheLargerOnes() {
        XCTAssertLessThan(TileLabels.Level.fillOnly, .badgeOnly)
        XCTAssertLessThan(TileLabels.Level.badgeOnly, .sizeOnly)
        XCTAssertLessThan(TileLabels.Level.sizeOnly, .nameAndSize)
        XCTAssertTrue(TileLabels.level(for: CGSize(width: 79, height: 38)).showsSize)
        XCTAssertTrue(TileLabels.level(for: CGSize(width: 79, height: 38)).showsBadge)
        XCTAssertFalse(TileLabels.level(for: CGSize(width: 79, height: 38)).showsName)
        XCTAssertFalse(TileLabels.level(for: CGSize(width: 22, height: 38)).showsBadge)
    }

    func testRadiusIsEightAndFiveWhenASideIsUnderThirty() {
        XCTAssertEqual(TileLabels.cornerRadius(for: CGSize(width: 410, height: 263)), 8)
        XCTAssertEqual(TileLabels.cornerRadius(for: CGSize(width: 30, height: 30)), 8)
        XCTAssertEqual(TileLabels.cornerRadius(for: CGSize(width: 22, height: 38)), 5)
        XCTAssertEqual(TileLabels.cornerRadius(for: CGSize(width: 100, height: 29.9)), 5)
    }

    func testTheBadgeSitsEightPointsFromTheCornerAndCentresInATileTooNarrowOrLowForTheMargin() {
        XCTAssertEqual(TileLabels.badgeOrigin(for: CGSize(width: 172, height: 93)), CGPoint(x: 8, y: 8))
        XCTAssertEqual(TileLabels.badgeOrigin(for: CGSize(width: 37, height: 149)), CGPoint(x: 10, y: 8), "the board: left 10 in a 37 wide tile")
        XCTAssertEqual(TileLabels.badgeOrigin(for: CGSize(width: 79, height: 38)), CGPoint(x: 8, y: 11), "the board: top 11 in a 38 high tile")
        XCTAssertEqual(TileLabels.badgeOrigin(for: CGSize(width: 28, height: 28)), CGPoint(x: 6, y: 6))
    }

    func testABadgeAloneInATileTooNarrowForItsSizeIsCentredLikeTheBoardsNarrowTiles() {
        let size = CGSize(width: 46, height: 88)
        XCTAssertEqual(TileLabels.badgeOrigin(for: size), CGPoint(x: 8, y: 8), "beside a size it keeps its margin")
        XCTAssertEqual(TileLabels.badgeOrigin(for: size, level: .sizeOnly), CGPoint(x: 8, y: 8))
        XCTAssertEqual(TileLabels.badgeOrigin(for: size, level: .badgeOnly), CGPoint(x: 15, y: 8))
    }

    func testTheSizeIsSetLargerInLargerTiles() {
        XCTAssertEqual(TileLabels.sizeStyle(for: CGSize(width: 410, height: 263)), .hero)
        XCTAssertEqual(TileLabels.sizeStyle(for: CGSize(width: 232, height: 125)), .large)
        XCTAssertEqual(TileLabels.sizeStyle(for: CGSize(width: 172, height: 93)), .regular)
        XCTAssertEqual(TileLabels.sizeStyle(for: CGSize(width: 118, height: 114)), .regular)
        XCTAssertEqual(TileLabels.sizeStyle(for: CGSize(width: 79, height: 38)), .regular)
    }
}

final class MapCaptionTests: XCTestCase {
    private let home = "/Users/test"
    private let size = CGSize(width: 416, height: 520)

    private func map(_ name: String = "plan-c.json", ticking: (inout SelectionModel) -> Void = { _ in }) throws -> MapModel {
        var selection = SelectionModel(plan: try TestPlans.fixture(name))
        ticking(&selection)
        return MapModel(selection: selection, size: size, home: home)
    }

    private func tile(_ map: MapModel, _ title: String, _ subtitle: String? = nil) throws -> MapTile {
        try XCTUnwrap(map.tiles.first { $0.title == title && $0.subtitle == subtitle }, title)
    }

    // MARK: what the caption says

    func testTheBoardsCaptionForDocker() throws {
        let docker = try tile(try map(), "Docker")
        XCTAssertEqual(docker.caption.title, "Docker")
        XCTAssertEqual(docker.caption.sizeText, "9.0 GB")
        XCTAssertEqual(docker.caption.status, "Review · not ticked")
        XCTAssertTrue(docker.caption.isReview)
        XCTAssertEqual(docker.caption.note, "3 cleanups, inside Docker's disk image, volumes are never offered")
    }

    func testAFileTilesCaptionIsItsNameSizeStateAndTheEnginesNote() throws {
        let lane = try tile(try map(), "lane-a", "node_modules")
        XCTAssertEqual(lane.caption.title, "lane-a node_modules")
        XCTAssertEqual(lane.caption.sizeText, "1.4 GB")
        XCTAssertEqual(lane.caption.status, "Safe · ticked")
        XCTAssertFalse(lane.caption.isReview)
        XCTAssertEqual(lane.caption.note, "lane lane-a: untouched for 12 days")
    }

    func testWithoutANoteTheCaptionShowsThePath() throws {
        let uv = try tile(try map(), "uv cache", "~/.cache/uv")
        XCTAssertEqual(uv.caption.title, "uv cache")
        XCTAssertEqual(uv.caption.note, "~/.cache/uv")
    }

    func testACommandTileShowsItsNote() throws {
        let brew = try tile(try map(), "Homebrew")
        XCTAssertEqual(brew.caption.note, "boost 1.85.0, 0.5 GB; python@3.14 3.14.7, 81 MB")
    }

    func testTheGroupsPlaceIsTheOneCmmNamesNotAWordOfOurs() throws {
        let plan = TestPlans.plan([
            TestPlans.item("vm: prune a", group: "VMs", rule: "vms", bytes: 3_000_000_000, tier: .review, action: .command, freesInside: "Some VM's disk file"),
            TestPlans.item("vm: prune b", group: "VMs", rule: "vms", bytes: 1_000_000_000, tier: .review, action: .command, freesInside: "Some VM's disk file"),
        ], capacityBytes: 100_000_000_000)
        let vm = try XCTUnwrap(MapModel(selection: SelectionModel(plan: plan), size: size, home: home).tiles.first)
        XCTAssertEqual(vm.caption.note, "2 cleanups, inside Some VM's disk file")
        XCTAssertFalse(vm.caption.note.contains("Docker"))
    }

    func testAGroupThatFreesNothingInsideSaysOnlyHowManyCleanups() {
        let plan = TestPlans.plan([
            TestPlans.item("p: a", group: "Prunes", rule: "p", bytes: 3_000_000_000, action: .command),
            TestPlans.item("p: b", group: "Prunes", rule: "p", bytes: 1_000_000_000, action: .command),
        ], capacityBytes: 100_000_000_000)
        XCTAssertEqual(MapModel(selection: SelectionModel(plan: plan), size: size, home: home).tiles.first?.caption.note, "2 cleanups")
    }

    func testTheStateWordsFollowTheTicks() throws {
        let all = try map { selection in
            selection.toggle(selection.groups.first { $0.section == .review }!)
        }
        XCTAssertEqual(try tile(all, "Docker").caption.status, "Review · ticked")
        let half = try map { selection in
            selection.toggle(selection.groups.first { $0.section == .review }!.items[0])
        }
        XCTAssertEqual(try tile(half, "Docker").caption.status, "Review · 1 of 3 ticked")
        let unticked = try map { selection in
            selection.toggle(selection.groups.first { $0.rule == "uv-cache" }!.items[0])
        }
        XCTAssertEqual(try tile(unticked, "uv cache", "~/.cache/uv").caption.status, "Safe · not ticked")
    }

    // MARK: whose caption it is

    func testTheCaptionFollowsTheKeyboardFocus() throws {
        let map = try map()
        let docker = try tile(map, "Docker")
        let uv = try tile(map, "uv cache", "~/.cache/uv")
        XCTAssertEqual(MapCaptionRule.subject(focused: docker.id, hovered: uv.id, in: map)?.id, docker.id)
        XCTAssertEqual(MapCaptionRule.subject(focused: docker.id, hovered: nil, in: map)?.id, docker.id)
    }

    func testTheCaptionIsPreviewedByTheHoverOnlyWhenNothingIsFocused() throws {
        let map = try map()
        let uv = try tile(map, "uv cache", "~/.cache/uv")
        XCTAssertEqual(MapCaptionRule.subject(focused: nil, hovered: uv.id, in: map)?.id, uv.id)
        XCTAssertNil(MapCaptionRule.subject(focused: nil, hovered: nil, in: map))
    }

    func testAFocusOnATileThatIsGoneIsNotAFocus() throws {
        let map = try map()
        let uv = try tile(map, "uv cache", "~/.cache/uv")
        XCTAssertEqual(MapCaptionRule.subject(focused: "item:/gone", hovered: uv.id, in: map)?.id, uv.id)
        XCTAssertNil(MapCaptionRule.subject(focused: "item:/gone", hovered: "item:/also-gone", in: map))
    }

    // MARK: what VoiceOver says

    func testATileIsSpokenAsItsNameSizeTierAndState() throws {
        let map = try map()
        XCTAssertEqual(try tile(map, "lane-a", "node_modules").spoken, "lane-a node_modules, 1.4 GB, safe to remove, ticked")
        XCTAssertEqual(try tile(map, "Docker").spoken, "Docker, 9.0 GB, review, not ticked")
        XCTAssertEqual(try tile(map, "uv cache", "~/.cache/uv").accessibilityLabel, "uv cache", "a group of one needs no path to be told apart")
    }

    func testAPartlyTickedGroupIsSaidSo() throws {
        let half = try map { selection in
            selection.toggle(selection.groups.first { $0.section == .review }!.items[0])
        }
        XCTAssertEqual(try tile(half, "Docker").spoken, "Docker, 9.0 GB, review, partly ticked")
    }

    func testAGroupTileSaysHowManyCleanupsItTicks() throws {
        XCTAssertEqual(try tile(try map(), "Docker").accessibilityHint, "Ticks or unticks all 3 cleanups")
        XCTAssertEqual(try tile(try map(), "uv cache", "~/.cache/uv").accessibilityHint, "Ticks or unticks this item")
    }
}
