import CoreGraphics
import XCTest
@testable import CmmKit

/// The chart's positions (the board `C-History` and the panels of `C-History-States`): the board's own numbers, read from its
/// SVG and CSS, are what the layout must give for the board's data.
final class HistoryChartLayoutTests: XCTestCase {
    private let calendar = HistoryBoard.calendar
    private let locale = HistoryBoard.locale

    private func layout(_ report: HistoryReport, now: Date = HistoryBoard.now, width: Double = 416) throws -> HistoryChartLayout {
        let chart = try XCTUnwrap(HistoryTimeline(report: report, now: now).chart, "no line to lay out")
        return HistoryChartLayout(chart: chart, width: width, calendar: calendar, locale: locale)
    }

    /// Hourly notes between two moments, each `free(hour index)` gigabytes.
    private func hourly(from first: Date, to last: Date, _ free: (Int) -> Double) -> [String] {
        var notes: [String] = []
        var hour = first
        var index = 0
        while hour <= last {
            notes.append(HistoryJSON.sample(HistoryBoard.iso(hour), free: gigabytes(free(index))))
            hour = hour.addingTimeInterval(3_600)
            index += 1
        }
        return notes
    }

    private func report(runs: [String] = [], samples: [String], now: Date = HistoryBoard.now, freeNow: Double? = 19.8) throws -> HistoryReport {
        var json = HistoryJSON()
        json.generatedAt = HistoryBoard.iso(now)
        json.host = freeNow.map { #"{"volume":"/System/Volumes/Data","free_bytes":\#(gigabytes($0))}"# } ?? #"{"volume":"","free_bytes":0}"#
        json.runs = runs
        json.samples = samples
        return try json.report()
    }

    // MARK: the board

    func testTheBoardsPlotAxesAndDays() throws {
        let board = try layout(try HistoryBoard.report())
        XCTAssertEqual(board.plot, CGRect(x: 30, y: 8, width: 386, height: 120), "the board's svg: 30 to 416 across, 8 to 128 down")
        XCTAssertEqual(board.start, HistoryBoard.at(9, 29, 9, 58), "the time axis starts at the first reading, not 90 days ago")
        XCTAssertEqual(board.end, HistoryBoard.now)
        XCTAssertEqual(board.valueLabels.map(\.text), ["50 GB", "0"])
        XCTAssertEqual(board.valueLabels.map(\.anchor), [.leading, .trailing])
        XCTAssertEqual(board.valueLabels.map(\.x), [0, 22], "the board writes 50 GB from the left edge, and 0 just left of the plot")

        let days = board.timeLabels
        XCTAssertEqual(days.map(\.text), ["29 Sep", "6 Oct", "13 Oct", "now"], "weeks, from their first day")
        XCTAssertEqual(days.map(\.anchor), [.leading, .center, .center, .trailing])
        guard days.count == 4 else { return }
        XCTAssertEqual(days[0].x, 30)
        // the board's words start at 182 and 358 and are about 25 and 30 pt wide
        XCTAssertEqual(days[1].x, 195, accuracy: 4)
        XCTAssertEqual(days[2].x, 373, accuracy: 4)
        XCTAssertEqual(days[3].x, 416)
        XCTAssertTrue(days.allSatisfy { $0.y == 140 }, "12 pt under the zero line")
    }

    func testTheBoardsLineBreaksAtTheGapAndAtEveryRise() throws {
        let board = try layout(try HistoryBoard.report())
        XCTAssertEqual(board.lines.count, 4, "the board's four strokes: before the gap, to the 9 Oct cleaning, to the 14 Oct one, to now")
        XCTAssertEqual(board.dots, [], "the foot of the first rise is the rise's, not a dot")
        // the board's rises: 29 Sep from 105.0 to 17.6, 9 Oct from 87.2 to 81.9, 14 Oct from 93.4 to 80.5
        XCTAssertEqual(board.rises.count, 3, "Docker's cleaning gave the disk nothing back: it does not rise")
        for (rise, expected) in zip(board.rises, [(30.0, 105.0, 17.6), (283.5, 87.2, 81.9), (415.0, 93.4, 80.5)]) {
            XCTAssertEqual(rise.x, expected.0, accuracy: 1)
            XCTAssertEqual(rise.fromY, expected.1, accuracy: 0.2)
            XCTAssertEqual(rise.toY, expected.2, accuracy: 0.2)
        }
        XCTAssertEqual(board.rises.map(\.id), [HistoryBoard.at(9, 29, 10, 2), HistoryBoard.at(10, 9, 9, 41), HistoryBoard.at(10, 14, 14, 6)].map(HistoryBoard.runID))
        // each stroke ends at the foot of a rise and the next starts at its top: the line never draws the rise itself
        for rise in board.rises.dropFirst() {
            let ending = try XCTUnwrap(board.lines.first { abs(($0.last?.x ?? 0) - rise.x) < 1 })
            let starting = try XCTUnwrap(board.lines.first { abs(($0.first?.x ?? 0) - rise.x) < 1 })
            XCTAssertEqual(ending.last?.y ?? 0, rise.fromY, accuracy: 0.01)
            XCTAssertEqual(starting.first?.y ?? 0, rise.toY, accuracy: 0.01)
        }
        // the first stroke starts where the first rise ends, as on the board (M30.0 17.6)
        XCTAssertEqual(board.lines.first?.first?.y ?? 0, 17.6, accuracy: 0.1)
    }

    func testTheBoardsGapSaysNoSamplesBetweenItsEndsAndNamesItsDays() throws {
        let board = try layout(try HistoryBoard.report())
        let gap = try XCTUnwrap(board.gaps.first)
        XCTAssertEqual(board.gaps.count, 1)
        XCTAssertEqual(gap.range, "Fri 3 \u{2013} Sun 5 Oct")
        XCTAssertEqual(gap.minX, 129.4, accuracy: 1.5, "the board's first stroke ends at 129.4")
        XCTAssertEqual(gap.maxX, 181.2, accuracy: 1.5, "and the next begins at 181.2")
        let label = try XCTUnwrap(gap.label)
        XCTAssertEqual(label.text, "No samples")
        XCTAssertEqual(label.anchor, .center)
        XCTAssertEqual(label.x, 155, accuracy: 1)
        XCTAssertEqual(label.y, 52, accuracy: 1, "between the two ends (45 and 58.9 on the board)")
        // nothing is drawn across it
        for line in board.lines {
            XCTAssertFalse(line.contains { $0.x > gap.minX + 0.5 && $0.x < gap.maxX - 0.5 }, "a stroke runs into the gap")
        }
    }

    func testTheBoardsValueNowIsWrittenOverItsReading() throws {
        let board = try layout(try HistoryBoard.report())
        let now = try XCTUnwrap(board.nowLabel)
        XCTAssertEqual(now.text, "19.8 GB")
        XCTAssertEqual(now.anchor, .trailing)
        XCTAssertEqual(now.x, 412, accuracy: 0.5, "the board: right: 4px")
        XCTAssertEqual(now.y, 64.5, accuracy: 1, "the board: top: 58px, 10.5 px words")
        XCTAssertEqual(board.readings.last?.isNow, true)
    }

    // MARK: the read-out

    func testTheReadoutIsTheReadingNearestThePointerAsTheBoardWritesIt() throws {
        let board = try layout(try HistoryBoard.report())
        let readout = try XCTUnwrap(board.readout(at: HistoryBoard.at(10, 7, 15, 10)))
        XCTAssertEqual(readout.first, "Tue 7 Oct, 15:00")
        XCTAssertEqual(readout.second, "22.9 GB free")
        XCTAssertFalse(readout.firstIsEmphasized, "the free space is the heavier line")
        let point = try XCTUnwrap(readout.point)
        XCTAssertEqual(point.y, 73, accuracy: 0.2, "the board's ringed point: cy=73")
        XCTAssertEqual(readout.lineX, 238.3, accuracy: 1, "the board's line: x=238.3")
        XCTAssertEqual(readout.lineX, point.x)
        // its box: 8 pt right of the line, 18 pt down (the board's left: 246px, top: 18px)
        let origin = board.readoutOrigin(for: readout)
        XCTAssertEqual(origin.x, 246, accuracy: 1)
        XCTAssertEqual(origin.y, 18)
    }

    func testOverAGapTheReadoutNamesTheDaysWithoutSamples() throws {
        let board = try layout(try HistoryBoard.report())
        let readout = try XCTUnwrap(board.readout(at: HistoryBoard.at(10, 4, 12, 0)))
        XCTAssertEqual(readout.first, "No samples")
        XCTAssertEqual(readout.second, "Fri 3 \u{2013} Sun 5 Oct")
        XCTAssertTrue(readout.firstIsEmphasized, "the words are the heavier line, as on the board")
        XCTAssertNil(readout.point, "nothing is ringed: there is no reading there, and none is made up")
        let gap = try XCTUnwrap(board.gaps.first)
        XCTAssertTrue(readout.lineX > gap.minX && readout.lineX < gap.maxX)
    }

    func testNearTheRightEdgeTheReadoutsBoxGoesLeftOfItsLine() throws {
        let board = try layout(try HistoryBoard.report())
        let readout = try XCTUnwrap(board.readout(at: HistoryBoard.now))
        XCTAssertEqual(readout.first, "Tue 14 Oct, 14:21", "the reading of the disk now")
        XCTAssertEqual(readout.second, "19.8 GB free")
        let origin = board.readoutOrigin(for: readout)
        XCTAssertLessThan(origin.x + 80, readout.lineX, "the box is to the left, clear of the line")
        XCTAssertGreaterThanOrEqual(origin.x, 0)
    }

    func testThePointerOnlyReadsOverThePlot() throws {
        let board = try layout(try HistoryBoard.report())
        XCTAssertNil(board.time(atX: 10), "over the axis's words")
        XCTAssertEqual(board.time(atX: 30), board.start)
        XCTAssertEqual(board.time(atX: 416), board.end)
        let middle = try XCTUnwrap(board.time(atX: 223))
        XCTAssertEqual(middle.timeIntervalSince(board.start) / board.end.timeIntervalSince(board.start), 0.5, accuracy: 0.001)
    }

    func testTheNearestReadingIsFoundByHalvingAndAgreesWithLookingAtEveryOne() throws {
        let board = try layout(try HistoryBoard.report())
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let time = board.start.addingTimeInterval(Double.random(in: -3_600...board.end.timeIntervalSince(board.start) + 3_600, using: &generator))
            let found = try XCTUnwrap(board.nearestReading(to: time))
            let best = board.readings.map { abs($0.t.timeIntervalSince(time)) }.min() ?? 0
            XCTAssertEqual(abs(found.t.timeIntervalSince(time)), best, accuracy: 0.001)
        }
        // two as near: the earlier
        let first = try XCTUnwrap(board.readings.first { $0.t == HistoryBoard.at(10, 7, 14, 0) })
        let found = try XCTUnwrap(board.nearestReading(to: HistoryBoard.at(10, 7, 14, 30)))
        XCTAssertEqual(found.t, first.t)
    }

    // MARK: the time axis, as the three panels draw it

    func testAFewDaysAreMarkedDayByDay() throws {
        // C-History-States, panel 2: 12 Oct to now, marked 13 Oct and 14 Oct
        let now = HistoryBoard.at(10, 14, 14, 50)
        let chart = try layout(try report(samples: hourly(from: HistoryBoard.at(10, 12, 8, 0), to: HistoryBoard.at(10, 14, 14, 0)) { 16.7 - Double($0) * 0.04 }, now: now), now: now)
        XCTAssertEqual(chart.timeLabels.map(\.text), ["12 Oct", "13 Oct", "14 Oct", "now"])
        XCTAssertEqual(HistoryChartLayout.tickStep(start: chart.start, end: chart.end, plotWidth: chart.plot.width), .day)
    }

    func testAWeekIsMarkedEveryOtherDayFromTheFirst() throws {
        // C-History-States, panel 3: 1 Oct to 7 Oct, marked 3, 5 and 7 Oct
        let now = HistoryBoard.at(10, 7, 22, 0)
        let samples = hourly(from: HistoryBoard.at(10, 1, 0, 30), to: HistoryBoard.at(10, 3, 8, 0)) { 41 - Double($0) * 0.1 }
            + hourly(from: HistoryBoard.at(10, 5, 8, 40), to: HistoryBoard.at(10, 7, 21, 0)) { 29 - Double($0) * 0.1 }
        let chart = try layout(try report(samples: samples, now: now), now: now)
        XCTAssertEqual(chart.timeLabels.map(\.text), ["1 Oct", "3 Oct", "5 Oct", "7 Oct", "now"])
        XCTAssertEqual(chart.gaps.map(\.range), ["Fri 3 \u{2013} Sun 5 Oct"])
    }

    func testNinetyDaysAreMarkedByMonth() throws {
        let now = HistoryBoard.now
        var samples: [String] = []
        var day = now.addingTimeInterval(-89 * 86_400)
        while day < now {
            samples.append(HistoryJSON.sample(HistoryBoard.iso(day), free: gigabytes(30)))
            day = day.addingTimeInterval(4 * 3_600)
        }
        let chart = try layout(try report(samples: samples))
        XCTAssertEqual(chart.timeLabels.map(\.text), ["17 Jul", "1 Aug", "1 Sep", "1 Oct", "now"])
    }

    func testAMarkThatWouldTouchNowOrTheFirstDayIsLeftOut() throws {
        // a day's mark an hour before now would sit on the word now
        let now = HistoryBoard.at(10, 14, 1, 0)
        let chart = try layout(try report(samples: hourly(from: HistoryBoard.at(10, 12, 8, 0), to: HistoryBoard.at(10, 14, 0, 30)) { _ in 20 }, now: now), now: now)
        XCTAssertEqual(chart.timeLabels.map(\.text), ["12 Oct", "13 Oct", "now"])
        // and none of the words that are kept touch each other
        let extents = chart.timeLabels.map(HistoryChartLayout.extent(of:)).sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(extents, extents.dropFirst()) { XCTAssertLessThan(a.upperBound + 10, b.lowerBound) }
    }

    // MARK: what is drawn and what is not

    func testACleaningThatGaveTheDiskNothingBackNeitherRisesNorBreaksTheLine() throws {
        let docker = HistoryJSON.run(
            finished: HistoryBoard.iso(HistoryBoard.at(10, 13, 12, 0)), started: HistoryBoard.iso(HistoryBoard.at(10, 13, 11, 59)),
            freed: 0, inside: gigabytes(9), before: gigabytes(20)
        )
        let samples = hourly(from: HistoryBoard.at(10, 12, 0, 0), to: HistoryBoard.at(10, 14, 14, 0)) { _ in 20 }
            + [HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 13, 11, 59)), free: gigabytes(20)),
               HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 13, 12, 0)), free: gigabytes(20))]
        let chart = try layout(try report(runs: [docker], samples: samples.sorted()))
        XCTAssertEqual(chart.rises, [])
        XCTAssertEqual(chart.lines.count, 1, "one stroke from the first reading to now")
    }

    func testAReadingOnItsOwnIsADot() throws {
        let samples = [
            HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 10, 8, 0)), free: gigabytes(20)),
            HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 10, 9, 0)), free: gigabytes(21)),
            HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 11, 9, 0)), free: gigabytes(22)),  // alone between two gaps
            HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 12, 9, 0)), free: gigabytes(23)),
            HistoryJSON.sample(HistoryBoard.iso(HistoryBoard.at(10, 12, 10, 0)), free: gigabytes(24)),
        ]
        let chart = try layout(try report(samples: samples, freeNow: nil))
        XCTAssertEqual(chart.lines.count, 2)
        XCTAssertEqual(chart.dots.count, 1)
        XCTAssertEqual(chart.gaps.count, 2)
        XCTAssertNil(chart.nowLabel, "cmm could not read the disk now: no value is written for it")
        XCTAssertEqual(chart.end, HistoryBoard.now, "the axis still ends now: the time since the last reading shows as such")
    }

    func testAValueNowAtTheTopOfTheAxisIsWrittenUnderItsReading() throws {
        let samples = hourly(from: HistoryBoard.at(10, 12, 8, 0), to: HistoryBoard.at(10, 14, 14, 0)) { _ in 20 }
        let chart = try layout(try report(samples: samples, freeNow: 50))
        let label = try XCTUnwrap(chart.nowLabel)
        XCTAssertEqual(chart.valueLabels.first?.text, "50 GB")
        XCTAssertGreaterThan(label.y, chart.plot.minY, "under the reading, inside the block")
    }

    func testAWideTopOfTheAxisMovesThePlotRightSoItsWordsFit() throws {
        let samples = hourly(from: HistoryBoard.at(10, 12, 8, 0), to: HistoryBoard.at(10, 14, 14, 0)) { _ in 510 }
        let chart = try layout(try report(samples: samples, freeNow: 510))
        XCTAssertEqual(chart.valueLabels.first?.text, "525 GB")
        XCTAssertGreaterThan(chart.plot.minX, 30)
        XCTAssertLessThanOrEqual(HistoryChartLayout.estimatedWidth("525 GB", size: 10), chart.plot.minX)
    }

    func testEverythingDrawnIsInsideThePlot() throws {
        let board = try layout(try HistoryBoard.report())
        let plot = board.plot.insetBy(dx: -0.01, dy: -0.01)
        for point in board.lines.flatMap({ $0 }) + board.dots + board.readings.map(\.point) {
            XCTAssertTrue(plot.contains(point), "\(point)")
        }
        for rise in board.rises {
            XCTAssertTrue(plot.contains(CGPoint(x: rise.x, y: rise.fromY)) && plot.contains(CGPoint(x: rise.x, y: rise.toY)))
        }
    }

    // MARK: what VoiceOver reads for the chart

    func testTheChartReadsTheParagraphOrElseTheWordsUnderTheLine() throws {
        let board = HistoryPresentation(
            report: try HistoryBoard.report(), historyEnabled: true, now: HistoryBoard.now, calendar: calendar, locale: locale, home: "/Users/test"
        )
        XCTAssertEqual(board.chartLabel, board.summary)
        // a line of two days and no cleaning: no paragraph, so the words under the line
        let short = HistoryPresentation(
            report: try report(samples: hourly(from: HistoryBoard.at(10, 12, 18, 0), to: HistoryBoard.at(10, 14, 14, 0)) { _ in 20 }),
            historyEnabled: true, now: HistoryBoard.now, calendar: calendar, locale: locale, home: "/Users/test"
        )
        XCTAssertNil(short.summary)
        XCTAssertEqual(short.chartLabel, "History fills in as cmm runs: 2 days so far.")
    }
}
