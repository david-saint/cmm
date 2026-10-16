import XCTest
@testable import CmmKit

/// "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago." (spec R3, R2 and the board's
/// paragraph): what the last ninety days gave the disk back, never counting what was freed inside Docker's disk image.
final class HistorySentencesTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    private let now = TestTime.utc("2026-10-15T09:00:00Z")

    private func report(_ runs: [String], host: String? = nil) throws -> HistoryReport {
        var json = HistoryJSON()
        json.runs = runs
        if let host { json.host = host }
        return try json.report()
    }

    private func sentence(_ runs: [String], calendar: Calendar? = nil, locale: Locale? = nil) throws -> String? {
        HistorySentences.totalsSentence(report: try report(runs), now: now, calendar: calendar ?? rome, locale: locale ?? british)
    }

    // MARK: the totals

    func testTheGoldenCleaningCountsWhatTheDiskGotBackAndNotDockersFigure() throws {
        let golden = try HistoryReport.parse(Fixture.data("history-v1.json"))
        let sentence = HistorySentences.totalsSentence(report: golden, now: now, calendar: rome, locale: british)
        XCTAssertEqual(sentence, "Freed 4.6 GB in 1 cleaning since 14 Oct.", "4.642 GB: Docker's 6.2 GB inside its disk image is not in it")
        XCTAssertEqual(HistorySentences.freedTotals(report: golden, now: now)?.bytes, 4_642_000_000)
    }

    func testTheBoardsSentence() throws {
        // 5.4 + 2.2 + 36.4 = 44.0 (C-History)
        let runs = [
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4)),
            HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2.2)),
            HistoryJSON.run(finished: "2026-09-29T08:02:00Z", freed: gigabytes(36.4)),
        ]
        XCTAssertEqual(try sentence(runs), "Freed 44.0 GB in 3 cleanings since 29 Sep.")
        let totals = try XCTUnwrap(HistorySentences.freedTotals(report: try report(runs), now: now))
        XCTAssertEqual(totals.cleanings, 3)
        XCTAssertEqual(totals.bytes, gigabytes(44.0))
        XCTAssertEqual(totals.since, TestTime.utc("2026-09-29T08:02:00Z"), "the oldest counted run")
    }

    func testOneCleaningIsSingular() throws {
        XCTAssertEqual(
            try sentence([HistoryJSON.run(finished: "2026-10-12T08:00:00Z", freed: gigabytes(5.4))]),
            "Freed 5.4 GB in 1 cleaning since 12 Oct."
        )
    }

    func testARunThatFreedNothingOnTheDiskIsNotCounted() throws {
        // Docker's prune: 9 GB inside its disk image, 0 on the disk
        let runs = [
            HistoryJSON.run(finished: "2026-10-14T12:20:00Z", freed: 0, inside: gigabytes(9)),
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4)),
            HistoryJSON.run(finished: "2026-10-01T12:06:00Z", freed: 0, inside: gigabytes(3)),
        ]
        XCTAssertEqual(try sentence(runs), "Freed 5.4 GB in 1 cleaning since 14 Oct.", "listed in the rows, not here, and not the date")
        XCTAssertEqual(HistorySentences.freedTotals(report: try report(runs), now: now)?.cleanings, 1)
    }

    func testOneByteCounts() throws {
        let totals = HistorySentences.freedTotals(report: try report([HistoryJSON.run(finished: "2026-10-12T08:00:00Z", freed: 1)]), now: now)
        XCTAssertEqual(totals?.cleanings, 1)
        XCTAssertEqual(totals?.bytes, 1)
    }

    func testNothingIsSaidWithoutACountedCleaning() throws {
        XCTAssertNil(try sentence([]), "no cleaning at all")
        XCTAssertNil(try sentence([HistoryJSON.run(finished: "2026-10-14T12:20:00Z", freed: 0, inside: gigabytes(9))]), "only Docker's")
        XCTAssertNil(try sentence([HistoryJSON.run(finished: "2026-05-01T12:20:00Z", freed: gigabytes(5))]), "only one outside the window")
        XCTAssertNil(HistorySentences.freedTotals(report: try report([]), now: now))
    }

    // MARK: the window

    func testOnlyTheLastNinetyDaysCountAndTheSinceIsTheOldestOneThatCounts() throws {
        let edge = now.addingTimeInterval(-90 * 86_400)
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-86_400)), freed: gigabytes(1)),
            HistoryJSON.run(finished: TestTime.iso(edge), freed: gigabytes(2)),
            HistoryJSON.run(finished: TestTime.iso(edge.addingTimeInterval(-1)), freed: gigabytes(100)),
        ]
        let totals = try XCTUnwrap(HistorySentences.freedTotals(report: try report(runs), now: now))
        XCTAssertEqual(totals.cleanings, 2, "exactly ninety days ago is in, a second older is out")
        XCTAssertEqual(totals.bytes, gigabytes(3))
        XCTAssertEqual(totals.since, edge)
    }

    func testACleaningDatedAfterNowIsNotCounted() throws {
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(1)), freed: gigabytes(50)),
            HistoryJSON.run(finished: TestTime.iso(now), freed: gigabytes(1)),
        ]
        let totals = try XCTUnwrap(HistorySentences.freedTotals(report: try report(runs), now: now))
        XCTAssertEqual(totals.cleanings, 1, "exactly now is in, a second ahead is not")
        XCTAssertEqual(totals.bytes, gigabytes(1))
    }

    // MARK: the date

    func testTheDateIsWrittenInThePersonsTimeAndLocale() throws {
        let runs = [HistoryJSON.run(finished: "2026-09-28T23:30:00Z", freed: gigabytes(1))]
        XCTAssertEqual(try sentence(runs, calendar: rome), "Freed 1.0 GB in 1 cleaning since 29 Sep.", "half past one on the 29th in Rome")
        XCTAssertEqual(try sentence(runs, calendar: TestCalendars.utc), "Freed 1.0 GB in 1 cleaning since 28 Sep.")
        XCTAssertEqual(try sentence(runs, locale: Locale(identifier: "en_US")), "Freed 1.0 GB in 1 cleaning since Sep 29.")
    }

    // MARK: a history that cannot make it crash

    func testTotalsStopAtTheLargestNumberAndDoNotTrap() throws {
        let runs = (0..<10_000).map { _ in HistoryJSON.run(finished: "2026-10-12T08:00:00Z", freed: HistoryLimits.maxBytes, before: 0, after: 0) }
        let totals = try XCTUnwrap(HistorySentences.freedTotals(report: try report(runs), now: now))
        XCTAssertEqual(totals.cleanings, 10_000)
        XCTAssertEqual(totals.bytes, Int64.max)
        let text = try XCTUnwrap(try sentence(runs))
        XCTAssertTrue(text.hasPrefix("Freed "), text)
        XCTAssertFalse(text.contains("-"), "no negative size: \(text)")
    }

    // MARK: the paragraph

    func testTheParagraphIsTheTotalsThenTheChangeOverTheWeekAsTheBoardSetsIt() throws {
        var json = HistoryJSON()
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":24000000000}"#
        json.runs = [
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4)),
            HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2.2)),
            HistoryJSON.run(finished: "2026-09-29T08:02:00Z", freed: gigabytes(36.4)),
        ]
        json.samples = [HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(-7 * 86_400)), free: gigabytes(27.1))]
        let report = try json.report()
        let totals = HistorySentences.totalsSentence(report: report, now: now, calendar: rome, locale: british)
        let week = WeekChange(report: report, now: now)
        XCTAssertEqual(
            HistorySentences.summary(totals: totals, weekChange: week),
            "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago."
        )
    }

    func testTheParagraphHasWhicheverHalfThereIs() {
        let week = WeekChange(report: HistoryReport.stub(host: 24_000_000_000, sampleAWeekAgo: gigabytes(27.1), now: now), now: now)
        XCTAssertNotNil(week)
        XCTAssertEqual(HistorySentences.summary(totals: "Freed 5.4 GB in 1 cleaning since 12 Oct.", weekChange: nil), "Freed 5.4 GB in 1 cleaning since 12 Oct.")
        XCTAssertEqual(HistorySentences.summary(totals: nil, weekChange: week), "Free space is 3.1 GB lower than a week ago.")
        XCTAssertNil(HistorySentences.summary(totals: nil, weekChange: nil))
    }
}

extension HistoryReport {
    /// A report with a known disk now and one note exactly a week before `now`.
    static func stub(host free: Int64, sampleAWeekAgo: Int64, now: Date) -> HistoryReport {
        var json = HistoryJSON()
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":\#(free)}"#
        json.samples = [HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(-7 * 86_400)), free: sampleAWeekAgo)]
        return try! json.report()
    }
}
