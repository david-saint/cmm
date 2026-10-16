import CoreGraphics
import Foundation

/// The free-space chart of the History face as positions in its block (the board `C-History`): where the line runs, where
/// each cleaning rises, where the gaps are and what they say, the words of both axes, and the read-out for the moment under
/// the pointer. The chart view strokes and fills what this says and works nothing out; what is shown comes from
/// `HistoryTimeline`, and this only places it.
///
/// The rules the boards draw:
/// - the time axis runs from the first reading (or cleaning) to now, not over the whole ninety days, so a short history fills
///   the width instead of hiding at its right end;
/// - the line breaks at every gap (never joined, never guessed) and at every cleaning that gave the disk something back: the
///   rise from what was free before to what was free after is drawn in green, not as part of the line. (cmm lists the two ends
///   of every cleaning among the readings, so without the break the line would draw the rise itself.) A reading on its own is
///   a dot, unless it is the foot of a rise, which the rise already draws;
/// - the values are labelled `0` and the top of the axis; the days are labelled with the first day at the left edge, `now` at
///   the right, and between them days, every other day, weeks (from their first day), fortnights or months, whichever is the
///   first to leave room between the words; a word that would touch another is left out;
/// - the value now is written over the last reading, when that is cmm's reading of the disk now.
public struct HistoryChartLayout: Equatable, Sendable {
    // The board's block: 150 pt tall, the plot from the top of the axis at 8 pt down to zero at 128 pt, the days written
    // 12 pt under it. The plot begins at 30 pt at least, so the top of the axis ("50 GB") is written to its left.
    public static let height = 150.0
    public static let plotTop = 8.0
    public static let plotBottom = 128.0
    public static let timeLabelY = 140.0
    public static let minimumPlotLeft = 30.0
    /// The axes are written at 10 pt, the value now at 10.5 pt, the read-out at 11 pt.
    public static let labelSize = 10.0
    public static let nowLabelSize = 10.5
    public static let readoutSize = 11.0
    /// Two day labels closer than this are one too many (the board keeps "13 Oct" 10 pt from "now").
    static let labelGap = 6.0
    /// The days between two marks of the time axis are at least this far apart.
    static let minimumTickSpacing = 70.0
    /// The value now is written this far above its reading (or below it, when there is no room above).
    static let nowLabelRise = 16.0
    public static let nowWord = "now"

    public enum Anchor: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    /// A word on the chart, at a point: `x` is its leading edge, its centre or its trailing edge, and `y` its middle.
    public struct Label: Equatable, Sendable {
        public let text: String
        public let x: Double
        public let y: Double
        public let anchor: Anchor
    }

    /// A cleaning that gave the disk something back: from what was free before to what was free after, at the moment it ended.
    public struct Rise: Equatable, Sendable, Identifiable {
        /// The run's id, which its row in the list shares.
        public let id: String
        public let x: Double
        public let fromY: Double
        public let toY: Double
    }

    /// A stretch without readings.
    public struct GapMark: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let minX: Double
        public let maxX: Double
        /// `No samples` over the middle of the gap, or nil when the gap is too narrow to hold the words.
        public let label: Label?
        /// `Fri 3 – Sun 5 Oct`, for the read-out.
        public let range: String
    }

    /// One reading of the free space, where it is drawn.
    public struct Reading: Equatable, Sendable {
        public let t: Date
        public let freeBytes: Int64
        public let point: CGPoint
        /// cmm's reading of the disk when it made the report, rather than a note from the history.
        public let isNow: Bool
    }

    /// What the chart shows for the moment under the pointer: a vertical line, the reading ringed, and two lines of words.
    public struct Readout: Equatable, Sendable {
        public let lineX: Double
        /// The reading, ringed; nil over a gap, where there is none.
        public let point: CGPoint?
        /// `Tue 7 Oct, 15:00` over `22.9 GB free`; over a gap, `No samples` over `Fri 3 – Sun 5 Oct`.
        public let first: String
        public let second: String
        /// Which of the two lines is set heavier: the free space of a reading, the words of a gap.
        public let firstIsEmphasized: Bool
    }

    public let width: Double
    public let plot: CGRect
    /// The left and right edges of the time axis: the first reading or cleaning, and now.
    public let start: Date
    public let end: Date
    /// Runs of readings joined by a line, each of two points or more.
    public let lines: [[CGPoint]]
    /// Readings on their own.
    public let dots: [CGPoint]
    public let rises: [Rise]
    public let gaps: [GapMark]
    /// `50 GB` at the top of the axis, `0` at the bottom.
    public let valueLabels: [Label]
    /// The first day, the marks between, and `now`.
    public let timeLabels: [Label]
    /// The value now over its reading (`19.8 GB`), when the last reading is cmm's reading of the disk now.
    public let nowLabel: Label?
    /// Every reading, oldest first, for the pointer.
    public let readings: [Reading]
    private let calendar: Calendar
    private let locale: Locale

    public init(chart: HistoryTimeline.Chart, width: Double, calendar: Calendar, locale: Locale) {
        self.width = width
        self.calendar = calendar
        self.locale = locale
        let points = chart.segments.flatMap(\.points)
        let firstMoment = ([points.first?.t, chart.markers.first?.t].compactMap { $0 }).min() ?? chart.windowStart
        let end = max(chart.windowEnd, firstMoment.addingTimeInterval(60))
        let start = min(firstMoment, end.addingTimeInterval(-60))
        self.start = start
        self.end = end

        let plotLeft = max(Self.minimumPlotLeft, Self.estimatedWidth(chart.yRange.highLabel, size: Self.labelSize) + 1)
        let plot = CGRect(
            x: plotLeft, y: Self.plotTop, width: max(width - plotLeft, 1), height: Self.plotBottom - Self.plotTop
        )
        self.plot = plot
        let span = end.timeIntervalSince(start)
        let high = Double(max(chart.yRange.highBytes, 1))
        func x(_ t: Date) -> Double {
            plot.minX + min(max(t.timeIntervalSince(start) / span, 0), 1) * plot.width
        }
        func y(_ bytes: Int64) -> Double {
            plot.maxY - min(max(Double(bytes) / high, 0), 1) * plot.height
        }

        // The line, broken at every rise. A rise is a cleaning that gave the disk something back; one that gave nothing back
        // (only Docker's prune, say) is not drawn, and does not break the line.
        let drawn = chart.markers.filter { $0.freedBytes > 0 }
        var lines: [[CGPoint]] = []
        var dots: [CGPoint] = []
        var next = 0
        for segment in chart.segments {
            var part: [CGPoint] = []
            var afterRise = false
            for point in segment.points {
                // the reading that ends a cleaning (and anything after the cleaning ended) is on the far side of its rise
                while next < drawn.count,
                      point.t > drawn[next].t || (point.t == drawn[next].t && point.freeBytes == drawn[next].freeBytes) {
                    if !part.isEmpty {
                        Self.close(part, nextToRise: true, lines: &lines, dots: &dots)
                        part = []
                        afterRise = true
                    }
                    next += 1
                }
                part.append(CGPoint(x: x(point.t), y: y(point.freeBytes)))
            }
            Self.close(part, nextToRise: afterRise, lines: &lines, dots: &dots)
        }
        self.lines = lines
        self.dots = dots
        rises = drawn.map { Rise(id: $0.id, x: x($0.t), fromY: y($0.freeBeforeBytes), toY: y($0.freeBytes)) }

        // The gaps, each between the last reading of one stretch and the first of the next. The words go over a gap about as
        // wide as they are (the board's is 52 pt for 51 pt of words), between the heights of its two ends.
        let noSamples = HistoryTimeline.Gap.title
        let room = Self.estimatedWidth(noSamples, size: Self.labelSize) * 0.85
        gaps = zip(chart.gaps, zip(chart.segments, chart.segments.dropFirst())).map { gap, sides in
            let (minX, maxX) = (x(gap.start), x(gap.end))
            let before = sides.0.points.last?.freeBytes ?? 0
            let after = sides.1.points.first?.freeBytes ?? 0
            let label = maxX - minX >= room
                ? Label(text: noSamples, x: (minX + maxX) / 2, y: (y(before) + y(after)) / 2, anchor: .center) : nil
            return GapMark(
                start: gap.start, end: gap.end, minX: minX, maxX: maxX, label: label,
                range: gap.rangeText(calendar: calendar, locale: locale)
            )
        }

        valueLabels = [
            Label(text: chart.yRange.highLabel, x: 0, y: plot.minY + 1, anchor: .leading),
            Label(text: chart.yRange.lowLabel, x: plot.minX - 8, y: plot.maxY - 1, anchor: .trailing),
        ]
        timeLabels = Self.timeLabels(start: start, end: end, plot: plot, calendar: calendar, locale: locale)

        readings = points.map { Reading(t: $0.t, freeBytes: $0.freeBytes, point: CGPoint(x: x($0.t), y: y($0.freeBytes)), isNow: $0.isNow) }
        if let now = readings.last, now.isNow {
            let text = SizeText.string(now.freeBytes)
            let above = now.point.y - Self.nowLabelRise
            let labelY = above - Self.nowLabelSize / 2 - 1 >= 0 ? above : now.point.y + Self.nowLabelRise
            let fits = now.point.x - 4 - Self.estimatedWidth(text, size: Self.nowLabelSize) >= plot.minX
            nowLabel = fits
                ? Label(text: text, x: now.point.x - 4, y: labelY, anchor: .trailing)
                : Label(text: text, x: now.point.x + 4, y: labelY, anchor: .leading)
        } else {
            nowLabel = nil
        }
    }

    private static func close(_ part: [CGPoint], nextToRise: Bool, lines: inout [[CGPoint]], dots: inout [CGPoint]) {
        if part.count > 1 {
            lines.append(part)
        } else if let only = part.first, !nextToRise {
            dots.append(only)
        }
    }

    // MARK: the pointer

    /// The moment at a point of the block, or nil when the point is not over the plot.
    public func time(atX x: Double) -> Date? {
        guard x >= plot.minX - 1, x <= plot.maxX + 1 else { return nil }
        let fraction = min(max((x - plot.minX) / plot.width, 0), 1)
        return start.addingTimeInterval(fraction * end.timeIntervalSince(start))
    }

    /// What to show for a moment: the words of the gap it falls in, or else the reading nearest to it.
    public func readout(at time: Date) -> Readout? {
        guard time >= start.addingTimeInterval(-1), time <= end.addingTimeInterval(1) else { return nil }
        if let gap = gaps.first(where: { $0.start < time && time < $0.end }) {
            let fraction = min(max(time.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
            return Readout(
                lineX: plot.minX + fraction * plot.width, point: nil, first: HistoryTimeline.Gap.title, second: gap.range,
                firstIsEmphasized: true
            )
        }
        guard let reading = nearestReading(to: time) else { return nil }
        let when = HistoryDates.formatter("EEEdMMM", calendar: calendar, locale: locale).string(from: reading.t)
        let clock = HistoryDates.formatter("jm", calendar: calendar, locale: locale).string(from: reading.t)
        return Readout(
            lineX: reading.point.x, point: reading.point, first: "\(when), \(clock)",
            second: "\(SizeText.string(reading.freeBytes)) free", firstIsEmphasized: false
        )
    }

    /// The reading nearest to a moment (the earlier of two as near), found by halving: a history can hold thousands.
    func nearestReading(to time: Date) -> Reading? {
        guard !readings.isEmpty else { return nil }
        var low = 0
        var high = readings.count
        while low < high {
            let middle = (low + high) / 2
            if readings[middle].t < time { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { readings.indices.contains($0) }
        return candidates.map { readings[$0] }.min {
            abs($0.t.timeIntervalSince(time)) < abs($1.t.timeIntervalSince(time))
        }
    }

    /// Where the read-out's box goes: 8 pt to the right of its line, or to its left when it would leave the block, 18 pt from
    /// the top, as on the board. The width is estimated from its words, so the box can be placed before it is drawn.
    public func readoutOrigin(for readout: Readout) -> CGPoint {
        let box = max(
            Self.estimatedWidth(readout.first, size: Self.readoutSize), Self.estimatedWidth(readout.second, size: Self.readoutSize)
        ) + 18
        let right = readout.lineX + 8
        let x = right + box <= width ? right : max(0, readout.lineX - 8 - box)
        return CGPoint(x: x, y: 18)
    }

    // MARK: the time axis

    /// The marks of the time axis, from the finest to the coarsest; the first that leaves room between its words is used.
    enum TickStep: CaseIterable, Equatable {
        case day, twoDays, week, twoWeeks, month, twoMonths

        var days: Double {
            switch self {
            case .day: 1
            case .twoDays: 2
            case .week: 7
            case .twoWeeks: 14
            case .month: 30
            case .twoMonths: 61
            }
        }

        /// The first mark's base, and how far each mark is from the one before.
        func marks(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
            let base: Date
            let component: Calendar.Component
            let count: Int
            switch self {
            case .day, .twoDays:
                base = calendar.startOfDay(for: start)
                (component, count) = (.day, self == .day ? 1 : 2)
            case .week, .twoWeeks:
                base = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? calendar.startOfDay(for: start)
                (component, count) = (.weekOfYear, self == .week ? 1 : 2)
            case .month, .twoMonths:
                base = calendar.dateInterval(of: .month, for: start)?.start ?? calendar.startOfDay(for: start)
                (component, count) = (.month, self == .month ? 1 : 2)
            }
            var marks: [Date] = []
            // counted from the base each time (not mark by mark), so a change of the clock cannot move them
            for step in 1...200 {
                guard let mark = calendar.date(byAdding: component, value: step * count, to: base), mark < end else { break }
                if mark > start { marks.append(mark) }
            }
            return marks
        }
    }

    static func tickStep(start: Date, end: Date, plotWidth: Double) -> TickStep {
        let perDay = plotWidth / max(end.timeIntervalSince(start) / 86_400, 1.0 / 24)
        return TickStep.allCases.first { $0.days * perDay >= minimumTickSpacing } ?? .twoMonths
    }

    private static func timeLabels(start: Date, end: Date, plot: CGRect, calendar: Calendar, locale: Locale) -> [Label] {
        let day = HistoryDates.formatter("dMMM", calendar: calendar, locale: locale)
        let first = Label(text: day.string(from: start), x: plot.minX, y: timeLabelY, anchor: .leading)
        let now = Label(text: nowWord, x: plot.maxX, y: timeLabelY, anchor: .trailing)
        var taken = [extent(of: first), extent(of: now)]
        var labels = [first]
        let span = end.timeIntervalSince(start)
        for mark in tickStep(start: start, end: end, plotWidth: plot.width).marks(from: start, to: end, calendar: calendar) {
            let x = plot.minX + mark.timeIntervalSince(start) / span * plot.width
            let label = Label(text: day.string(from: mark), x: x, y: timeLabelY, anchor: .center)
            let range = extent(of: label)
            guard !taken.contains(where: { $0.lowerBound - labelGap < range.upperBound && range.lowerBound < $0.upperBound + labelGap })
            else { continue }
            labels.append(label)
            taken.append(range)
        }
        labels.append(now)
        return labels
    }

    /// From where to where a word on the time axis runs.
    static func extent(of label: Label) -> ClosedRange<Double> {
        let width = estimatedWidth(label.text, size: labelSize)
        switch label.anchor {
        case .leading: return label.x...(label.x + width)
        case .center: return (label.x - width / 2)...(label.x + width / 2)
        case .trailing: return (label.x - width)...label.x
        }
    }

    /// About how wide a short label of SF is, so a decision about room can be made before anything is drawn: figures (which the
    /// chart sets in equal widths), capitals, the wide and the narrow letters each at their usual share of the size.
    static func estimatedWidth(_ text: String, size: Double) -> Double {
        let ems = text.reduce(0.0) { total, character in
            let em: Double
            if character.isNumber {
                em = 0.6
            } else if character == " " {
                em = 0.26
            } else if "iljtfrI.,:;'\u{00B7}()".contains(character) {
                em = 0.3
            } else if "mwMW".contains(character) {
                em = 0.85
            } else if character.isUppercase {
                em = 0.68
            } else {
                em = 0.54
            }
            return total + em
        }
        return ems * size
    }
}

extension HistoryPresentation {
    /// What VoiceOver reads for the chart, which is one element: the paragraph above it (spec R11), or, when there is none, the
    /// words under the line, so the chart is never nameless.
    public var chartLabel: String {
        summary ?? timeline?.caption ?? "Free space over time"
    }
}
