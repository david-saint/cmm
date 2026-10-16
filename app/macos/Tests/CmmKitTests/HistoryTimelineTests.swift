import XCTest
@testable import CmmKit

/// The chart of the History face (the boards `C-History` and `C-History-States`, which refine spec R1): points, segments that
/// break wherever the app was not running, the gaps they leave, a marker per cleanup, the "now" point, the axis from zero to
/// the next 25 GB, and the caption under a line that is still short.
final class HistoryTimelineTests: XCTestCase {
    private let now = TestTime.utc("2026-10-15T09:00:00Z")
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")

    /// A report whose samples are given as (seconds before `now`, free GB), in any order.
    private func report(
        _ samples: [(ago: TimeInterval, gb: Double)] = [],
        runs: [String] = [],
        host: Int64? = 24_000_000_000,
        generatedAt: Date? = nil
    ) throws -> HistoryReport {
        var json = HistoryJSON()
        json.samples = samples.map { HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(-$0.ago)), free: gigabytes($0.gb)) }
        json.runs = runs
        json.host = host.map { #"{"volume":"/System/Volumes/Data","free_bytes":\#($0),"capacity_bytes":245107195904}"# }
            ?? #"{"volume":"","free_bytes":0}"#
        json.generatedAt = TestTime.iso(generatedAt ?? now)
        return try json.report()
    }

    private func timeline(
        _ samples: [(ago: TimeInterval, gb: Double)] = [], runs: [String] = [], host: Int64? = 24_000_000_000, generatedAt: Date? = nil
    ) throws -> HistoryTimeline {
        HistoryTimeline(report: try report(samples, runs: runs, host: host, generatedAt: generatedAt), now: now)
    }

    private func chart(
        _ samples: [(ago: TimeInterval, gb: Double)], runs: [String] = [], host: Int64? = 24_000_000_000, generatedAt: Date? = nil
    ) throws -> HistoryTimeline.Chart {
        try XCTUnwrap(try timeline(samples, runs: runs, host: host, generatedAt: generatedAt).chart, "expected a line")
    }

    /// Hourly samples at 20 GB over the four days that end `endingAgo` seconds before now.
    private func steady(endingAgo: TimeInterval) -> [(ago: TimeInterval, gb: Double)] {
        (0...96).map { (ago: endingAgo + TimeInterval($0) * 3_600, gb: 20.0) }
    }

    private var fourDaysSteady: [(ago: TimeInterval, gb: Double)] { steady(endingAgo: 3_600) }

    // MARK: a history that is still short

    func testTheGoldenReportDrawsItsShortLineAndSaysHowManyDaysThereAre() throws {
        let golden = try HistoryReport.parse(Fixture.data("history-v1.json"))
        let timeline = HistoryTimeline(report: golden, now: TestTime.utc("2026-10-15T09:00:00Z"))
        XCTAssertNotNil(timeline.chart, "the board draws what there is (C-History-States, 2 · Few samples)")
        XCTAssertEqual(timeline.caption, "History fills in as cmm runs: 2 days so far.", "a day and four hours of notes")
    }

    func testNothingToDrawWithoutTwoReadingsAndTheCaptionSaysWhy() throws {
        for samples in [[], [(hour, 20.0)]] as [[(ago: TimeInterval, gb: Double)]] {
            let timeline = try self.timeline(samples)
            XCTAssertNil(timeline.chart, "\(samples.count) notes")
            XCTAssertEqual(timeline.caption, "History fills in as cmm runs.")
        }
        XCTAssertEqual(HistoryTimeline.fillingInMessage, "History fills in as cmm runs")
    }

    func testNotesAllFromOneMomentAreNotALine() throws {
        let timeline = try self.timeline([(hour, 20), (hour, 21), (hour, 22)])
        XCTAssertNil(timeline.chart)
        XCTAssertEqual(timeline.caption, "History fills in as cmm runs.")
    }

    func testTheCaptionCountsWholeDaysRoundedUpAndNeverSaysMoreThanThree() throws {
        func caption(_ span: TimeInterval) throws -> String? {
            try timeline([(span + hour, 20), (hour, 20)]).caption
        }
        XCTAssertEqual(try caption(1), "History fills in as cmm runs: 1 day so far.")
        XCTAssertEqual(try caption(day), "History fills in as cmm runs: 1 day so far.", "exactly a day is one day")
        XCTAssertEqual(try caption(day + 1), "History fills in as cmm runs: 2 days so far.")
        XCTAssertEqual(try caption(2 * day), "History fills in as cmm runs: 2 days so far.")
        XCTAssertEqual(try caption(2 * day + 1), "History fills in as cmm runs: 3 days so far.")
        XCTAssertEqual(try caption(3 * day - 1), "History fills in as cmm runs: 3 days so far.", "the last second before three days")
        XCTAssertNil(try caption(3 * day), "three days is enough: no caption")
        XCTAssertNil(try caption(30 * day))
        XCTAssertEqual(HistoryTimeline.minimumSpan, 3 * 86_400)
    }

    func testThreeDaysOfSamplesAreALineWithoutACaption() throws {
        let timeline = try self.timeline(fourDaysSteady)
        XCTAssertNotNil(timeline.chart)
        XCTAssertNil(timeline.caption)
    }

    func testTheDaysAreCountedBetweenTheSamplesNotUpToNow() throws {
        // two notes a day apart, the second four days ago: the history is old, not long
        let timeline = try self.timeline([(5 * day, 20), (4 * day, 20)], host: nil)
        XCTAssertEqual(timeline.caption, "History fills in as cmm runs: 1 day so far.")
        XCTAssertNotNil(timeline.chart)
    }

    func testTheDiskNowDoesNotCountAsADayOfSamples() throws {
        // notes a day apart, and the disk now two days later: still a day of notes
        let timeline = try self.timeline([(3 * day, 20), (2 * day, 20)], host: 24_000_000_000)
        XCTAssertEqual(timeline.caption, "History fills in as cmm runs: 1 day so far.")
        XCTAssertEqual(timeline.chart?.segments.flatMap(\.points).last?.isNow, true, "though it is on the line")
    }

    // MARK: the window

    func testOnlyTheLastNinetyDaysAreDrawn() throws {
        let edge = TimeInterval(HistoryTimeline.windowDays) * day
        let included = try chart([(edge, 20), (85 * day, 21), (day, 22)])
        XCTAssertEqual(included.segments.flatMap(\.points).first?.t, now.addingTimeInterval(-edge), "exactly ninety days ago is in")
        XCTAssertEqual(included.windowStart, now.addingTimeInterval(-edge))
        XCTAssertEqual(included.windowEnd, now)

        let excluded = try chart([(edge + 1, 20), (85 * day, 21), (day, 22)])
        XCTAssertEqual(excluded.segments.flatMap(\.points).first?.freeBytes, gigabytes(21), "one second older is out")
        XCTAssertEqual(HistoryTimeline.windowDays, 90)
    }

    func testTheLineIsMeasuredOnTheSamplesInTheWindow() throws {
        // two notes, but only the later one is inside the window
        let timeline = try self.timeline([(91 * day, 20), (89 * day + hour, 20)])
        XCTAssertNil(timeline.chart)
        XCTAssertEqual(timeline.caption, "History fills in as cmm runs.")
    }

    func testNothingFromTheFutureIsDrawnOrForecast() throws {
        let chart = try chart(fourDaysSteady + [(-hour, 5), (-day, 1)], host: nil)
        let points = chart.segments.flatMap(\.points)
        XCTAssertEqual(points.count, 97, "the two samples dated after now are left out")
        XCTAssertTrue(points.allSatisfy { $0.t <= now })
        XCTAssertEqual(points.map(\.freeBytes).min(), gigabytes(20))
    }

    // MARK: segments and gaps

    func testReadingsCloseTogetherAreOneLineWithNoGap() throws {
        let chart = try chart(fourDaysSteady, host: nil)
        XCTAssertEqual(chart.segments.count, 1)
        XCTAssertEqual(chart.segments[0].points.count, 97)
        XCTAssertEqual(chart.segments[0].points.map(\.t), chart.segments[0].points.map(\.t).sorted(), "oldest first")
        XCTAssertEqual(chart.gaps, [])
    }

    func testSixHoursExactlyIsStillOneLineAndOneSecondMoreIsABreak() throws {
        let exactly = try chart([(100 * hour, 20), (94 * hour, 20), (10 * hour, 20)], host: nil)
        XCTAssertEqual(exactly.segments.map { $0.points.count }, [2, 1], "100 h to 94 h is six hours: joined; then a long gap")
        XCTAssertEqual(exactly.gaps.count, 1)

        let oneSecondMore = try chart([(100 * hour, 20), (94 * hour - 1, 20), (10 * hour, 20)], host: nil)
        XCTAssertEqual(oneSecondMore.segments.map { $0.points.count }, [1, 1, 1], "six hours and a second: broken")
        XCTAssertEqual(oneSecondMore.gaps.count, 2)
        XCTAssertEqual(HistoryTimeline.gap, 6 * 3_600)
    }

    func testNeverJoinsAcrossAGapAndEachPieceKeepsItsPoints() throws {
        let chart = try chart(
            [(100 * hour, 20), (94 * hour, 21), (40 * hour, 22), (34 * hour, 23), (33 * hour, 24), (10 * hour, 25)], host: nil
        )
        XCTAssertEqual(chart.segments.map { $0.points.map(\.freeBytes) }, [
            [gigabytes(20), gigabytes(21)], [gigabytes(22), gigabytes(23), gigabytes(24)], [gigabytes(25)],
        ])
    }

    func testEachGapIsFromTheLastReadingBeforeItToTheFirstOneAfter() throws {
        let chart = try chart(
            [(100 * hour, 20), (94 * hour, 21), (40 * hour, 22), (34 * hour, 23), (33 * hour, 24), (10 * hour, 25)], host: nil
        )
        XCTAssertEqual(chart.gaps, [
            HistoryTimeline.Gap(start: now.addingTimeInterval(-94 * hour), end: now.addingTimeInterval(-40 * hour)),
            HistoryTimeline.Gap(start: now.addingTimeInterval(-33 * hour), end: now.addingTimeInterval(-10 * hour)),
        ])
    }

    func testSamplesInAnyOrderAreDrawnOldestFirst() throws {
        let chart = try chart([(10 * hour, 25), (100 * hour, 20), (94 * hour, 21)], host: nil)
        XCTAssertEqual(chart.segments.map { $0.points.map(\.freeBytes) }, [[gigabytes(20), gigabytes(21)], [gigabytes(25)]])
    }

    func testTheGapBetweenTheLastNoteAndTheDiskNowIsAGapToo() throws {
        let chart = try chart(steady(endingAgo: 7 * hour), host: 24_000_000_000)
        XCTAssertEqual(chart.gaps, [HistoryTimeline.Gap(start: now.addingTimeInterval(-7 * hour), end: now)])
    }

    // MARK: how a gap is written

    func testAGapAcrossDaysIsWrittenFromDayToDay() throws {
        let gap = HistoryTimeline.Gap(start: rome.local(2026, 10, 3, 10, 0), end: rome.local(2026, 10, 5, 9, 30))
        XCTAssertEqual(HistoryTimeline.Gap.title, "No samples")
        XCTAssertEqual(gap.rangeText(calendar: rome, locale: british), "Sat 3 \u{2013} Mon 5 Oct", "the month once, when it is the same")
    }

    func testAGapAcrossAMonthSaysBothMonths() throws {
        let gap = HistoryTimeline.Gap(start: rome.local(2026, 9, 30, 10, 0), end: rome.local(2026, 10, 5, 9, 30))
        XCTAssertEqual(gap.rangeText(calendar: rome, locale: british), "Wed 30 Sep \u{2013} Mon 5 Oct")
    }

    func testAGapInsideADayIsWrittenWithTheTimes() throws {
        let gap = HistoryTimeline.Gap(start: rome.local(2026, 10, 3, 12, 0), end: rome.local(2026, 10, 3, 19, 5))
        XCTAssertEqual(gap.rangeText(calendar: rome, locale: british), "Sat 3 Oct, 12:00 \u{2013} 19:05")
    }

    func testAGapIsWrittenInTheCalendarsOwnTime() throws {
        // 23:30 UTC on the 3rd is half past one on the 4th in Rome
        let gap = HistoryTimeline.Gap(start: TestTime.utc("2026-10-03T23:30:00Z"), end: TestTime.utc("2026-10-06T10:00:00Z"))
        XCTAssertEqual(gap.rangeText(calendar: rome, locale: british), "Sun 4 \u{2013} Tue 6 Oct")
        XCTAssertEqual(gap.rangeText(calendar: TestCalendars.utc, locale: british), "Sat 3 \u{2013} Tue 6 Oct")
    }

    // MARK: the disk now

    func testTheDiskNowIsTheLastPointWhenItIsNewerThanTheLastSample() throws {
        let chart = try chart(steady(endingAgo: 2 * hour), host: 24_000_000_000)
        XCTAssertEqual(chart.segments.map { $0.points.count }, [98], "two hours after the last note: one line, and the disk now at its end")
        let last = try XCTUnwrap(chart.segments.last?.points.last)
        XCTAssertTrue(last.isNow)
        XCTAssertEqual(last.t, now)
        XCTAssertEqual(last.freeBytes, 24_000_000_000)
        XCTAssertEqual(chart.segments.flatMap(\.points).filter(\.isNow).count, 1)
    }

    func testTheDiskNowObeysTheGapRuleLikeEveryOtherReading() throws {
        let apart = try chart(steady(endingAgo: 7 * hour), host: 24_000_000_000)
        XCTAssertEqual(apart.segments.map { $0.points.count }, [97, 1], "the last note is seven hours old: the disk now stands alone")
        XCTAssertTrue(apart.segments[1].points[0].isNow)

        let joined = try self.chart(steady(endingAgo: 6 * hour), host: 24_000_000_000)
        XCTAssertEqual(joined.segments.map { $0.points.count }, [98], "six hours exactly is joined")
    }

    func testTheDiskNowIsNotAddedWhenTheLastSampleIsAsNewOrNewer() throws {
        let sameMoment = try chart(steady(endingAgo: 0), host: 24_000_000_000)
        XCTAssertEqual(sameMoment.segments.flatMap(\.points).count, 97, "not newer than the last sample")
        XCTAssertFalse(sameMoment.segments.flatMap(\.points).contains { $0.isNow })

        let reportedEarlier = try chart(
            steady(endingAgo: hour), host: 24_000_000_000, generatedAt: now.addingTimeInterval(-2 * hour)
        )
        XCTAssertFalse(reportedEarlier.segments.flatMap(\.points).contains { $0.isNow }, "the report is older than the last sample")
    }

    func testTheDiskNowIsNotAddedWhenCmmCouldNotReadIt() throws {
        let chart = try chart(steady(endingAgo: hour), host: nil)
        XCTAssertFalse(chart.segments.flatMap(\.points).contains { $0.isNow }, "unknown is not an empty disk")
        XCTAssertEqual(chart.segments.flatMap(\.points).map(\.freeBytes).min(), gigabytes(20))
    }

    func testTheDiskNowIsDatedByTheReportAndNeverLaterThanNow() throws {
        let earlier = try chart(steady(endingAgo: 3 * hour), host: 24_000_000_000, generatedAt: now.addingTimeInterval(-hour))
        XCTAssertEqual(earlier.segments.flatMap(\.points).last?.t, now.addingTimeInterval(-hour), "read an hour ago, drawn an hour ago")

        let future = try self.chart(steady(endingAgo: 3 * hour), host: 24_000_000_000, generatedAt: now.addingTimeInterval(day))
        XCTAssertEqual(future.segments.flatMap(\.points).last?.t, now, "a report cannot be from the future")
    }

    func testAReportWithoutATimeIsDatedNow() throws {
        var json = HistoryJSON()
        json.samples = [HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(-4 * day)), free: gigabytes(20)),
                        HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(-hour)), free: gigabytes(21))]
        json.generatedAt = "unreadable"
        let chart = try XCTUnwrap(HistoryTimeline(report: try json.report(), now: now).chart)
        XCTAssertEqual(chart.segments.flatMap(\.points).last?.t, now)
    }

    // MARK: markers

    func testOneMarkerPerCleanupAtItsEndAndAtTheFreeSpaceItLeft() throws {
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-2 * day)), freed: gigabytes(5), before: gigabytes(20)),
            // a Docker-only run: nothing came back to the disk, and it still gets its marker
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-10 * day)), freed: 0, inside: gigabytes(6), before: gigabytes(18)),
        ]
        let report = try self.report(fourDaysSteady, runs: runs, host: nil)
        let chart = try self.chart(fourDaysSteady, runs: runs, host: nil)

        XCTAssertEqual(chart.markers.count, 2)
        XCTAssertEqual(chart.markers.map(\.t), [now.addingTimeInterval(-10 * day), now.addingTimeInterval(-2 * day)], "oldest first, like the points")
        XCTAssertEqual(chart.markers.map(\.freeBytes), [gigabytes(18), gigabytes(25)], "free_after: where the marker sits")
        XCTAssertEqual(chart.markers.map(\.freeBeforeBytes), [gigabytes(18), gigabytes(20)], "free_before: where the jump line starts")
        XCTAssertEqual(chart.markers.map(\.freedBytes), [0, gigabytes(5)])
        XCTAssertEqual(Set(chart.markers.map(\.id)), Set(report.runs.map(\.id)), "the id of the run, shared with its row")
    }

    func testACleanupOutsideTheWindowOrFromTheFutureHasNoMarker() throws {
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-91 * day))),
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(day))),
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-90 * day))),
        ]
        let chart = try self.chart(fourDaysSteady, runs: runs, host: nil)
        XCTAssertEqual(chart.markers.map(\.t), [now.addingTimeInterval(-90 * day)], "exactly ninety days ago is in")
    }

    // MARK: the axis

    private func axis(_ gbs: [Double], host: Int64? = nil, runs: [String] = []) throws -> HistoryTimeline.YRange {
        // spread over four days so the line is a long one
        let step = 4 * day / TimeInterval(max(gbs.count - 1, 1))
        let samples = gbs.enumerated().map { (ago: 4 * day - TimeInterval($0.offset) * step + hour, gb: $0.element) }
        return try chart(samples, runs: runs, host: host).yRange
    }

    func testTheAxisRunsFromZeroToTheNextTwentyFiveGigabytesAboveTheHighestReading() throws {
        let fifty = try axis([30, 46])
        XCTAssertEqual(fifty.highGB, 50, "46 GB: 50")
        XCTAssertEqual(fifty.highBytes, 50_000_000_000)
        XCTAssertEqual(fifty.lowBytes, 0)
        XCTAssertEqual(fifty.lowLabel, "0")
        XCTAssertEqual(fifty.highLabel, "50 GB")

        let twentyFive = try axis([20, 24.4])
        XCTAssertEqual(twentyFive.highGB, 25, "24.4 GB: 25")
        XCTAssertEqual(twentyFive.highLabel, "25 GB")
        XCTAssertEqual(HistoryTimeline.axisStepGB, 25)
    }

    func testTheEdgesOfTheSteps() throws {
        XCTAssertEqual(try axis([10, 25]).highGB, 25, "exactly 25 GB fits in 25")
        XCTAssertEqual(try axis([10, 25.000000001]).highGB, 50, "a byte more does not")
        XCTAssertEqual(try axis([10, 49.9]).highGB, 50)
        XCTAssertEqual(try axis([10, 50]).highGB, 50)
        XCTAssertEqual(try axis([10, 50.1]).highGB, 75)
        XCTAssertEqual(try axis([10, 100]).highGB, 100)
    }

    func testTheAxisIsNeverShorterThan25GBEvenForADiskWithNothingFree() throws {
        XCTAssertEqual(try axis([0, 0, 0], host: 0).highGB, 25)
        XCTAssertEqual(try axis([0.3, 0.8]).highGB, 25)
        XCTAssertEqual(try axis([0, 0, 0], host: 0).lowLabel, "0")
    }

    func testTheLabelSaysTerabytesWhenItIsOneAndIsASizeText() throws {
        let tb = try axis([1_400, 1_480])
        XCTAssertEqual(tb.highGB, 1_500)
        XCTAssertEqual(tb.highLabel, SizeText.capacity(tb.highBytes))
        XCTAssertEqual(tb.highLabel, "1.5 TB")
    }

    func testTheAxisTakesInTheDiskNowAndBothEndsOfEveryCleanup() throws {
        XCTAssertEqual(try axis([20, 21], host: 40_000_000_000).highGB, 50, "the disk now is a point of the line")

        let high = HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-2 * day)), freed: 0, before: gigabytes(30), after: gigabytes(30))
        XCTAssertEqual(try axis([20, 21], runs: [high]).highGB, 50, "so is where a cleanup left the disk")

        let before = HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-2 * day)), freed: 0, before: gigabytes(60), after: gigabytes(10))
        XCTAssertEqual(try axis([20, 21], runs: [before]).highGB, 75, "and where it was before")
    }

    func testEveryPointAndMarkerIsInsideTheAxisWhateverTheHistory() throws {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for round in 0..<60 {
            let count = 2 + Int(next() * 12)
            let scale = [0.4, 3.0, 40.0, 900.0][round % 4]
            let base = next() * 100
            let gbs = (0..<count).map { _ in base + next() * scale }
            let step = 4 * day / TimeInterval(count - 1)
            let chart = try self.chart(
                gbs.enumerated().map { (ago: 5 * day - TimeInterval($0.offset) * step + hour, gb: $0.element) },
                host: gigabytes(base + next() * scale)
            )
            let range = chart.yRange
            for point in chart.segments.flatMap(\.points) {
                XCTAssertGreaterThanOrEqual(point.freeBytes, range.lowBytes, "round \(round)")
                XCTAssertLessThanOrEqual(point.freeBytes, range.highBytes, "round \(round)")
            }
            XCTAssertEqual(range.highGB % 25, 0, "round \(round)")
            XCTAssertGreaterThanOrEqual(range.highGB, 25)
            let highest = try XCTUnwrap(chart.segments.flatMap(\.points).map(\.freeBytes).max())
            XCTAssertTrue(range.highGB == 25 || range.highBytes - 25_000_000_000 < highest, "no more than one step above the highest: round \(round)")
        }
    }
}
