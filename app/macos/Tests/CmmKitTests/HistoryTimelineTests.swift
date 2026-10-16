import XCTest
@testable import CmmKit

/// The chart of the History face (spec R1): points, segments that break wherever the app was not running, a marker per
/// cleanup, the "now" point, the whole-gigabyte axis, and the plain sentence in place of a chart that would pretend.
final class HistoryTimelineTests: XCTestCase {
    private let now = TestTime.utc("2026-10-15T09:00:00Z")
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

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

    private func chart(
        _ samples: [(ago: TimeInterval, gb: Double)], runs: [String] = [], host: Int64? = 24_000_000_000, generatedAt: Date? = nil
    ) throws -> HistoryTimeline.Chart {
        let timeline = HistoryTimeline(report: try report(samples, runs: runs, host: host, generatedAt: generatedAt), now: now)
        guard case .chart(let chart) = timeline.display else {
            XCTFail("expected a chart, got \(timeline.display)")
            throw XCTSkip("no chart")
        }
        return chart
    }

    /// Samples every hour for four days at the same level: enough for a chart, one segment, nothing in the way.
    private var fourDaysSteady: [(ago: TimeInterval, gb: Double)] {
        steady(endingAgo: 3_600)
    }

    /// Hourly samples at 20 GB over the four days that end `endingAgo` seconds before now.
    private func steady(endingAgo: TimeInterval) -> [(ago: TimeInterval, gb: Double)] {
        (0...96).map { (ago: endingAgo + TimeInterval($0) * 3_600, gb: 20.0) }
    }

    // MARK: not enough history

    func testTheGoldenReportIsStillFillingIn() throws {
        let golden = try HistoryReport.parse(Fixture.data("history-v1.json"))
        let timeline = HistoryTimeline(report: golden, now: TestTime.utc("2026-10-15T09:00:00Z"))
        XCTAssertEqual(timeline.display, .fillingIn("History fills in as cmm runs"))
        XCTAssertEqual(HistoryTimeline.fillingInMessage, "History fills in as cmm runs")
    }

    func testNoSamplesAndOneSampleAreFillingIn() throws {
        XCTAssertEqual(HistoryTimeline(report: try report(), now: now).display, .fillingIn(HistoryTimeline.fillingInMessage))
        XCTAssertEqual(HistoryTimeline(report: try report([(hour, 20)]), now: now).display, .fillingIn(HistoryTimeline.fillingInMessage))
    }

    func testThreeDaysOfSamplesIsEnoughAndOneSecondLessIsNot() throws {
        let enough = HistoryTimeline(report: try report([(3 * day + hour, 20), (hour, 20)]), now: now)
        guard case .chart = enough.display else { return XCTFail("exactly three days is a chart: \(enough.display)") }

        let notQuite = HistoryTimeline(report: try report([(3 * day + hour - 1, 20), (hour, 20)]), now: now)
        XCTAssertEqual(notQuite.display, .fillingIn(HistoryTimeline.fillingInMessage), "one second short of three days")
    }

    func testTheDaysAreCountedBetweenTheSamplesNotUpToNow() throws {
        // two samples a day apart, the second one four days ago: the history is old, not long
        let timeline = HistoryTimeline(report: try report([(5 * day, 20), (4 * day, 20)]), now: now)
        XCTAssertEqual(timeline.display, .fillingIn(HistoryTimeline.fillingInMessage))
    }

    func testTheDiskNowDoesNotCountAsADayOfSamples() throws {
        // a sample two days ago and the disk now: that is no more than two days of history
        let timeline = HistoryTimeline(report: try report([(2 * day, 20), (day, 20)], host: 24_000_000_000), now: now)
        XCTAssertEqual(timeline.display, .fillingIn(HistoryTimeline.fillingInMessage))
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

    func testTheSpanIsMeasuredOnTheSamplesInTheWindow() throws {
        // two samples a week apart, but only the later one is inside the window
        let timeline = HistoryTimeline(report: try report([(91 * day, 20), (89 * day + hour, 20)]), now: now)
        XCTAssertEqual(timeline.display, .fillingIn(HistoryTimeline.fillingInMessage))
    }

    func testNothingFromTheFutureIsDrawnOrForecast() throws {
        let chart = try chart(fourDaysSteady + [(-hour, 5), (-day, 1)], host: nil)
        let points = chart.segments.flatMap(\.points)
        XCTAssertEqual(points.count, 97, "the two samples dated after now are left out")
        XCTAssertTrue(points.allSatisfy { $0.t <= now })
        XCTAssertEqual(points.map(\.freeBytes).min(), gigabytes(20), "and they do not move the axis either")
    }

    // MARK: segments

    func testReadingsCloseTogetherAreOneLine() throws {
        let chart = try chart(fourDaysSteady, host: nil)
        XCTAssertEqual(chart.segments.count, 1)
        XCTAssertEqual(chart.segments[0].points.count, 97)
        XCTAssertEqual(chart.segments[0].points.map(\.t), chart.segments[0].points.map(\.t).sorted(), "oldest first")
    }

    func testSixHoursExactlyIsStillOneLineAndOneSecondMoreIsABreak() throws {
        let exactly = try chart([(100 * hour, 20), (94 * hour, 20), (10 * hour, 20)], host: nil)
        XCTAssertEqual(exactly.segments.map { $0.points.count }, [2, 1], "100 h to 94 h is six hours: joined; then a long gap")

        let oneSecondMore = try chart([(100 * hour, 20), (94 * hour - 1, 20), (10 * hour, 20)], host: nil)
        XCTAssertEqual(oneSecondMore.segments.map { $0.points.count }, [1, 1, 1], "six hours and a second: broken")
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

    func testSamplesInAnyOrderAreDrawnOldestFirst() throws {
        let chart = try chart([(10 * hour, 25), (100 * hour, 20), (94 * hour, 21)], host: nil)
        XCTAssertEqual(chart.segments.map { $0.points.map(\.freeBytes) }, [[gigabytes(20), gigabytes(21)], [gigabytes(25)]])
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
        let timeline = HistoryTimeline(report: try json.report(), now: now)
        guard case .chart(let chart) = timeline.display else { return XCTFail("\(timeline.display)") }
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
        XCTAssertEqual(chart.markers.map(\.freeBytes), [gigabytes(18), gigabytes(25)], "free_after")
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

    private func range(_ gbs: [Double], host: Int64? = nil, runs: [String] = []) throws -> HistoryTimeline.YRange {
        // spread over four days so the history is long enough for a chart
        let step = 4 * day / TimeInterval(max(gbs.count - 1, 1))
        let samples = gbs.enumerated().map { (ago: 4 * day - TimeInterval($0.offset) * step + hour, gb: $0.element) }
        return try chart(samples, runs: runs, host: host).yRange
    }

    func testTheAxisIsWholeGigabytesFromTheFloorOfTheLowestToTheCeilingOfTheHighest() throws {
        let range = try self.range([20.2, 29.1])
        XCTAssertEqual(range.lowGB, 20)
        XCTAssertEqual(range.highGB, 30)
        XCTAssertEqual(range.lowBytes, 20_000_000_000)
        XCTAssertEqual(range.highBytes, 30_000_000_000)
        XCTAssertEqual(range.lowLabel, "20 GB")
        XCTAssertEqual(range.highLabel, "30 GB")
    }

    func testWholeGigabytesAreNotRoundedAwayFromThemselves() throws {
        let range = try self.range([20.0, 30.0])
        XCTAssertEqual([range.lowGB, range.highGB], [20, 30])
    }

    func testASmallMovementIsGivenAtLeastFiveGigabytesOfHeightAroundIt() throws {
        let r1 = try self.range([20.2, 20.9])
        XCTAssertEqual([r1.lowGB, r1.highGB], [18, 23], "one GB of movement in five GB of axis, not the whole chart")

        let r2 = try self.range([20.0, 24.0])
        XCTAssertEqual([r2.lowGB, r2.highGB], [20, 25])

        let r3 = try self.range([20.0, 23.0])
        XCTAssertEqual([r3.lowGB, r3.highGB], [19, 24])

        let r4 = try self.range([20.0, 22.0])
        XCTAssertEqual([r4.lowGB, r4.highGB], [19, 24])

        let flat = try self.range([20.0, 20.0, 20.0])
        XCTAssertEqual([flat.lowGB, flat.highGB], [18, 23], "a flat line is five GB tall too")

        let exactlyFive = try self.range([20.0, 25.0])
        XCTAssertEqual([exactlyFive.lowGB, exactlyFive.highGB], [20, 25], "five is already enough")
        XCTAssertEqual(HistoryTimeline.minimumHeightGB, 5)
    }

    func testTheAxisNeverGoesBelowZeroAndTheHeightIsKept() throws {
        let r1 = try self.range([0.3, 0.8])
        XCTAssertEqual([r1.lowGB, r1.highGB], [0, 5])
        XCTAssertEqual(r1.lowLabel, "0 GB")

        let r2 = try self.range([1.5, 2.2])
        XCTAssertEqual([r2.lowGB, r2.highGB], [0, 5])

        let r3 = try self.range([2.0, 4.0])
        XCTAssertEqual([r3.lowGB, r3.highGB], [1, 6], "room below is used before it runs out")
    }

    func testTheLabelsAreSizeTextsAndSayTerabytesWhenTheyAre() throws {
        let range = try self.range([1_500.0, 1_500.4])
        XCTAssertEqual(range.lowLabel, SizeText.capacity(range.lowBytes))
        XCTAssertEqual(range.highLabel, SizeText.capacity(range.highBytes))
        XCTAssertEqual(range.highLabel, "1.5 TB")
    }

    func testTheAxisTakesInTheDiskNowAndTheMarkersToo() throws {
        let withNow = try self.range([20.0, 21.0], host: 40_000_000_000)
        XCTAssertEqual(withNow.highGB, 40, "the disk now is a point of the chart")

        let run = HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-2 * day)), freed: 0, before: gigabytes(9), after: gigabytes(9))
        let withMarker = try self.range([20.0, 21.0], runs: [run])
        XCTAssertEqual(withMarker.lowGB, 9, "so is where a cleanup left the disk")
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
            XCTAssertGreaterThanOrEqual(range.lowGB, 0)
            XCTAssertGreaterThanOrEqual(range.highGB - range.lowGB, 5, "round \(round)")
        }
    }
}
