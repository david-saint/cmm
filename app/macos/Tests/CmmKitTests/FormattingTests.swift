import XCTest
@testable import CmmKit

/// Text the window shows. These helpers are plain functions so the strings can be tested without a window; byte
/// sizes use the app's own formatter (decimal units, like the Finder and cmm) instead of `ByteCountFormatter`,
/// whose output depends on the locale.
final class FormattingTests: XCTestCase {
    func testByteSizes() {
        let cases: [(Int64, String)] = [
            (0, "0 B"), (1, "1 B"), (999, "999 B"),
            (1_000, "1.0 KB"), (1_500, "1.5 KB"), (999_949, "999.9 KB"),
            (999_950, "1.0 MB"),  // rounding must carry into the next unit, never "1000.0 KB"
            (81_000_000, "81.0 MB"), (704_000_000, "704.0 MB"), (927_080_448, "927.1 MB"),
            (999_950_000, "1.0 GB"),
            (1_000_000_000, "1.0 GB"), (3_081_535_488, "3.1 GB"), (27_633_246_208, "27.6 GB"),
            (1_500_000_000_000, "1.5 TB"),
            (-5, "0 B"),
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(ByteFormat.string(bytes), expected, "\(bytes) bytes")
        }
    }

    func testTheLargestPossibleSizeDoesNotCrash() {
        XCTAssertEqual(ByteFormat.string(Int64.max), "9223.4 PB")
    }

    func testItemCounts() {
        XCTAssertEqual(Plural.items(0), "0 items")
        XCTAssertEqual(Plural.items(1), "1 item")
        XCTAssertEqual(Plural.items(2), "2 items")
    }

    // MARK: paths

    func testThePathOfTheHomeFolderIsShortenedToATilde() {
        let home = "/Users/saint"
        XCTAssertEqual(PathFormat.shorten("/Users/saint/Library/Caches/go-build", home: home), "~/Library/Caches/go-build")
        XCTAssertEqual(PathFormat.shorten("/Users/saint", home: home), "~")
        XCTAssertEqual(PathFormat.shorten("/Users/saint/", home: home), "~/")
    }

    func testShorteningRespectsPathComponentBoundaries() {
        let home = "/Users/test"
        XCTAssertEqual(PathFormat.shorten("/Users/test2/Library", home: home), "/Users/test2/Library", "not ~2/Library")
        XCTAssertEqual(PathFormat.shorten("/Users/tes/x", home: home), "/Users/tes/x")
        XCTAssertEqual(PathFormat.shorten("/Volumes/Backup/Users/test/x", home: home), "/Volumes/Backup/Users/test/x")
        XCTAssertEqual(PathFormat.shorten("/private/var/folders/xx/T/jest", home: home), "/private/var/folders/xx/T/jest")
    }

    func testAHomeWithATrailingSlashOrNoMeaningChangesNothingSurprising() {
        XCTAssertEqual(PathFormat.shorten("/Users/test/x", home: "/Users/test/"), "~/x")
        XCTAssertEqual(PathFormat.shorten("/Users/test/x", home: ""), "/Users/test/x")
        XCTAssertEqual(PathFormat.shorten("/Users/test/x", home: "/"), "/Users/test/x", "a root 'home' must not turn every path into ~")
    }

    func testLabelsThatAreNotPathsAreLeftAlone() {
        XCTAssertEqual(PathFormat.shorten("homebrew: cleanup", home: "/Users/test"), "homebrew: cleanup")
    }

    // MARK: how an item is titled

    func testAFileItemIsTitledByItsShortenedPathWithTheNoteBeneath() throws {
        let plan = try TestPlans.fixture("plan-v1.json")
        let lane = plan.items[1]
        XCTAssertEqual(lane.displayTitle(home: "/Users/test"), "~/lane-builds/ios27-scene-cloud-mobile/node_modules")
        XCTAssertEqual(lane.displayDetail, "lane ios27-scene-cloud-mobile: untouched for 5+ days")
        XCTAssertNil(plan.items[0].displayDetail)
    }

    func testACommandItemIsTitledByItsNoteBecauseItsPathIsNotAPath() throws {
        let brew = try TestPlans.fixture("plan-v1.json").items[3]
        XCTAssertEqual(brew.displayTitle(home: "/Users/test"), "boost 1.85.0, 0.5 GB; python@3.14 3.14.7, 81 MB")
        XCTAssertNil(brew.displayDetail, "the note is the title; it is not repeated underneath")
    }

    func testACommandItemWithoutANoteFallsBackToItsLabel() {
        let bare = TestPlans.item("homebrew: cleanup", action: .command)
        XCTAssertEqual(bare.displayTitle(home: "/Users/test"), "homebrew: cleanup")
        XCTAssertNil(bare.displayDetail)
    }

    func testAnEmptyNoteIsNoNote() {
        let item = TestPlans.item("/Users/test/a", note: "")
        XCTAssertNil(item.displayDetail)
    }

    func testASkipReadsAsRuleAndReason() {
        XCTAssertEqual(Skip(rule: "uv-cache", reason: "uv is running").summary, "uv-cache: uv is running")
    }

    // MARK: sentences

    func testTheFooterTotals() throws {
        let selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        XCTAssertEqual(selection.summaryText, "Selected: 4 items, 3.1 GB")
        XCTAssertEqual(selection.cleanButtonTitle, "Clean 4 items…")
    }

    func testTheFooterTotalsInTheSingular() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        for group in selection.groups { selection.toggle(group) }
        selection.toggle(selection.groups[2].items[0])
        XCTAssertEqual(selection.summaryText, "Selected: 1 item, 704.0 MB")
        XCTAssertEqual(selection.cleanButtonTitle, "Clean 1 item…")
    }

    func testTheFooterWhenNothingIsTicked() throws {
        var selection = SelectionModel(plan: try TestPlans.fixture("plan-v1.json"))
        for group in selection.groups { selection.toggle(group) }
        XCTAssertEqual(selection.summaryText, "Selected: 0 items, 0 B")
        XCTAssertEqual(selection.cleanButtonTitle, "Clean 0 items…")
    }
}
