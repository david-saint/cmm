import XCTest
@testable import CmmKit

/// "Free space is 3.1 GB lower than a week ago." (spec R2): the free space now against the note nearest to exactly a week
/// ago, within a day of it, and nothing at all when there is none.
final class HistoryWeekChangeTests: XCTestCase {
    private let now = TestTime.utc("2026-10-15T09:00:00Z")
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private var weekAgo: Date { now.addingTimeInterval(-7 * day) }

    /// A report whose host has `now` free and whose samples are given as (seconds before the moment a week ago, free GB):
    /// a negative number is later than that moment.
    private func report(
        now free: Int64? = 24_000_000_000, aroundAWeekAgo notes: [(offset: TimeInterval, gb: Double)] = [], extra: [String] = []
    ) throws -> HistoryReport {
        var json = HistoryJSON()
        json.host = free.map { #"{"volume":"/System/Volumes/Data","free_bytes":\#($0)}"# } ?? #"{"volume":"","free_bytes":0}"#
        json.samples = notes.map { HistoryJSON.sample(TestTime.iso(weekAgo.addingTimeInterval(-$0.offset)), free: gigabytes($0.gb)) } + extra
        return try json.report()
    }

    private func compare(_ notes: [(offset: TimeInterval, gb: Double)], now free: Int64? = 24_000_000_000) throws -> WeekChange? {
        WeekChange(report: try report(now: free, aroundAWeekAgo: notes), now: now)
    }

    // MARK: the words

    func testLower() throws {
        let change = try XCTUnwrap(try compare([(0, 27.1)]))
        XCTAssertEqual(change.text, "Free space is 3.1 GB lower than a week ago.")
        XCTAssertEqual(change.direction, .lower)
        XCTAssertEqual(change.difference, gigabytes(3.1))
    }

    func testHigher() throws {
        let change = try XCTUnwrap(try compare([(0, 19.8)]))
        XCTAssertEqual(change.text, "Free space is 4.2 GB higher than a week ago.")
        XCTAssertEqual(change.direction, .higher)
        XCTAssertEqual(change.difference, gigabytes(4.2))
    }

    func testAboutTheSameIsUnderHalfAGigabyteEitherWay() throws {
        for gb in [24.0, 24.49, 23.51, 23.600001] {
            let change = try XCTUnwrap(try compare([(0, gb)]), "\(gb)")
            XCTAssertEqual(change.text, "Free space is about the same as a week ago.", "\(gb)")
            XCTAssertEqual(change.direction, .aboutTheSame)
        }
        XCTAssertEqual(WeekChange.sameBelowBytes, 500_000_000)
    }

    func testHalfAGigabyteExactlyIsAChangeNotTheSame() throws {
        let lower = try XCTUnwrap(try compare([(0, 24.5)]))
        XCTAssertEqual(lower.text, "Free space is 0.5 GB lower than a week ago.")
        let higher = try XCTUnwrap(try compare([(0, 23.5)]))
        XCTAssertEqual(higher.text, "Free space is 0.5 GB higher than a week ago.")
        // 499 999 999 bytes is still under half a gigabyte, though it is written 0.5 GB
        let almost = try XCTUnwrap(try WeekChange(report: report(now: 24_000_000_000, extra: [
            HistoryJSON.sample(TestTime.iso(weekAgo), free: 24_499_999_999),
        ]), now: now))
        XCTAssertEqual(almost.direction, .aboutTheSame)
    }

    func testSizesAreWrittenTheWayTheRestOfTheAppWritesThem() throws {
        let small = try XCTUnwrap(try compare([(0, 24.9)], now: 24_000_000_000))
        XCTAssertEqual(small.text, "Free space is 0.9 GB lower than a week ago.")
        let big = try XCTUnwrap(try compare([(0, 300)], now: 24_000_000_000))
        XCTAssertEqual(big.text, "Free space is 276.0 GB lower than a week ago.")
    }

    // MARK: which note

    func testNothingIsSaidWithoutANoteNearAWeekAgo() throws {
        XCTAssertNil(try compare([]), "no notes at all")
        XCTAssertNil(try compare([(3 * day, 20)]), "the nearest note is three days off: that is not a week ago")
        XCTAssertNil(try compare([(-3 * day, 20)]), "nor is one from four days ago")
        XCTAssertNil(try compare([(30 * day, 20)]), "never extrapolated from a month ago")
    }

    func testWithinADayExactlyIsNearEnoughAndOneSecondMoreIsNot() throws {
        XCTAssertNotNil(try compare([(24 * hour, 20)]), "a day before: in")
        XCTAssertNotNil(try compare([(-24 * hour, 20)]), "a day after: in")
        XCTAssertNil(try compare([(24 * hour + 1, 20)]), "a second more before: out")
        XCTAssertNil(try compare([(-24 * hour - 1, 20)]), "a second more after: out")
        XCTAssertEqual(WeekChange.reach, 24 * 3_600)
    }

    func testTheNoteNearestToExactlyAWeekAgoIsTheOneUsed() throws {
        let change = try XCTUnwrap(try compare([(10 * hour, 30), (3 * hour, 27.1), (-5 * hour, 10), (-20 * hour, 11)]))
        XCTAssertEqual(change.comparedWith.freeBytes, gigabytes(27.1))
        XCTAssertEqual(change.comparedWith.t, weekAgo.addingTimeInterval(-3 * hour))
        XCTAssertEqual(change.text, "Free space is 3.1 GB lower than a week ago.")
    }

    func testTheNearestIsFoundWhicheverSideItIsOn() throws {
        let after = try XCTUnwrap(try compare([(10 * hour, 30), (-3 * hour, 27.1)]))
        XCTAssertEqual(after.comparedWith.freeBytes, gigabytes(27.1))
        let before = try XCTUnwrap(try compare([(-10 * hour, 30), (3 * hour, 27.1)]))
        XCTAssertEqual(before.comparedWith.freeBytes, gigabytes(27.1))
    }

    func testTwoNotesEquallyNearAreResolvedToTheEarlierOne() throws {
        let change = try XCTUnwrap(try compare([(-3 * hour, 29), (3 * hour, 27.1)]))
        XCTAssertEqual(change.comparedWith.freeBytes, gigabytes(27.1), "three hours before, not three hours after")
        let swapped = try XCTUnwrap(try self.compare([(3 * hour, 27.1), (-3 * hour, 29)]))
        XCTAssertEqual(swapped.comparedWith.freeBytes, gigabytes(27.1), "whatever order they came in")
    }

    func testTheEndsOfACleanupAreNotesLikeAnyOther() throws {
        // the report's samples already hold the two ends of every cleanup
        var json = HistoryJSON()
        json.host = #"{"volume":"/","free_bytes":24000000000}"#
        json.samples = [HistoryJSON.sample(TestTime.iso(weekAgo), free: gigabytes(19.8))]
        json.runs = [HistoryJSON.run(finished: TestTime.iso(weekAgo), freed: gigabytes(5))]
        let change = try XCTUnwrap(WeekChange(report: try json.report(), now: now))
        XCTAssertEqual(change.direction, .higher)
    }

    // MARK: when the free space now is not known

    func testNothingIsSaidWhenCmmCouldNotReadTheDiskNow() throws {
        XCTAssertNil(try compare([(0, 27.1)], now: nil))
    }

    func testAFullDiskIsKnownAndComparesLikeAnyOther() throws {
        let change = try XCTUnwrap(try compare([(0, 4.2)], now: 0))
        XCTAssertEqual(change.text, "Free space is 4.2 GB lower than a week ago.")
    }

    // MARK: what is not believed

    func testNotesFromTheFutureAreNotUsed() throws {
        // a note dated a week from now is not a note from a week ago
        var json = HistoryJSON()
        json.host = #"{"volume":"/","free_bytes":24000000000}"#
        json.samples = [HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(7 * day)), free: gigabytes(27.1))]
        XCTAssertNil(WeekChange(report: try json.report(), now: now))
    }

    func testTheComparisonUsesTheClockItIsGiven() throws {
        // the same report, looked at a week later, has no note near a week before that
        XCTAssertNil(WeekChange(report: try report(aroundAWeekAgo: [(0, 27.1)]), now: now.addingTimeInterval(7 * day)))
    }
}
