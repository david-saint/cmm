import Foundation

/// The free-space chart of the History face, as plain values: the points, the segments they make, the gaps between the
/// segments, one marker per cleanup, the "now" point, and the range of the vertical axis. The view only draws what this says.
///
/// The rules (the boards `C-History` and `C-History-States`, which replaced spec R1's axis and its "no chart" rule):
/// two readings more than six hours apart are never joined (the app was not running, and nothing is guessed for the time in
/// between) and each such gap is handed on as a range, for a tooltip; nothing is forecast; the axis starts at zero and ends
/// at the next 25 GB above the highest reading; and while there are fewer than three days of samples the line is drawn as
/// far as it goes, with a plain sentence under it that says how many days there are so far.
public struct HistoryTimeline: Equatable, Sendable {
    /// How far back the chart looks.
    public static let windowDays = 90
    /// Two readings further apart than this are not joined by a line.
    public static let gap: TimeInterval = 6 * 3_600
    /// Samples that cover less time than this are a start, not a trend, and the chart says so.
    public static let minimumSpan: TimeInterval = 3 * 86_400
    /// The axis ends at a multiple of this many gigabytes.
    public static let axisStepGB: Int64 = 25
    public static let fillingInMessage = "History fills in as cmm runs"

    /// One reading of the free space.
    public struct Point: Equatable, Sendable {
        public let t: Date
        public let freeBytes: Int64
        /// The reading cmm took of the disk when it made the report, rather than a note from the history.
        public let isNow: Bool
    }

    /// A run of readings that follow each other closely enough to be joined by a line. A segment of one point is a dot.
    public struct Segment: Equatable, Sendable {
        public let points: [Point]
    }

    /// A stretch with no readings in it: from the last reading before it to the first one after.
    public struct Gap: Equatable, Sendable {
        public static let title = "No samples"
        public let start: Date
        public let end: Date

        /// `Fri 3 – Sun 5 Oct` for a gap that spans days (the month is said once when it is the same), and
        /// `Fri 3 Oct, 12:00 – 19:00` for one inside a day.
        public func rangeText(calendar: Calendar, locale: Locale) -> String {
            func formatter(_ template: String) -> DateFormatter {
                HistoryDates.formatter(template, calendar: calendar, locale: locale)
            }
            if calendar.isDate(start, inSameDayAs: end) {
                let time = formatter("jm")
                return "\(formatter("EEEdMMM").string(from: start)), \(time.string(from: start)) \u{2013} \(time.string(from: end))"
            }
            let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            let first = formatter(sameMonth ? "EEEd" : "EEEdMMM").string(from: start)
            return "\(first) \u{2013} \(formatter("EEEdMMM").string(from: end))"
        }
    }

    /// A cleanup, at the moment it ended and the free space it left. The jump line starts where the free space was before.
    public struct Marker: Equatable, Sendable, Identifiable {
        /// The id of the run (`HistoryRun.id`), which its row in the list shares.
        public let id: String
        public let t: Date
        /// `free_after`: where the marker sits.
        public let freeBytes: Int64
        /// `free_before`: where the jump started.
        public let freeBeforeBytes: Int64
        /// What the disk got back (never Docker's figure), so a run that freed nothing can be drawn as such.
        public let freedBytes: Int64
    }

    /// The vertical axis: from zero to a multiple of 25 GB that holds every reading and every marker, never less than 25 GB.
    public struct YRange: Equatable, Sendable {
        public let highGB: Int64
        public var lowBytes: Int64 { 0 }
        public var highBytes: Int64 { highGB * 1_000_000_000 }
        /// `0`
        public let lowLabel: String
        /// `50 GB`
        public let highLabel: String
    }

    public struct Chart: Equatable, Sendable {
        public let windowStart: Date
        public let windowEnd: Date
        public let segments: [Segment]
        public let gaps: [Gap]
        public let markers: [Marker]
        public let yRange: YRange
    }

    /// The line, or nil when there is nothing to draw: fewer than two readings, or readings that all share one moment.
    public let chart: Chart?
    /// `History fills in as cmm runs: 3 days so far.` under a line that is still short, `History fills in as cmm runs.`
    /// where there is no line yet, and nil once there are three days of samples.
    public let caption: String?

    /// - Parameter now: the moment the person is looking, taken after the report arrived. Anything the report dates later
    ///   than `now` is not believed and not drawn.
    public init(report: HistoryReport, now: Date) {
        let report = report.asOf(now)
        let start = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)

        // "Days of samples" are counted between the first and the last note in the window; the disk now is not a note.
        let samples = report.samples.filter { $0.t >= start }
        guard let first = samples.first, let last = samples.last, last.t > first.t else {
            chart = nil
            caption = "\(Self.fillingInMessage)."
            return
        }
        let span = last.t.timeIntervalSince(first.t)
        // Under three days the count is whole days rounded up, so it never says more than 3 before it goes away.
        caption = span >= Self.minimumSpan
            ? nil : "\(Self.fillingInMessage): \(Self.daysSoFar(span))."

        var points = samples.map { Point(t: $0.t, freeBytes: $0.freeBytes, isNow: false) }
        // The disk now, as cmm read it when it made the report, if that is newer than the last note. It is dated by the
        // report (never later than now) and takes part in the gap rule like any other reading.
        if let free = report.host.freeBytes {
            let read = min(report.generatedAt ?? now, now)
            if read >= start, read > last.t { points.append(Point(t: read, freeBytes: free, isNow: true)) }
        }

        var segments: [Segment] = []
        var gaps: [Gap] = []
        var current: [Point] = []
        for point in points {
            if let previous = current.last, point.t.timeIntervalSince(previous.t) > Self.gap {
                segments.append(Segment(points: current))
                gaps.append(Gap(start: previous.t, end: point.t))
                current = []
            }
            current.append(point)
        }
        segments.append(Segment(points: current))

        // oldest first, like the points (the report lists its runs newest first)
        let markers = report.runs.reversed().filter { $0.finishedAt >= start }.map {
            Marker(id: $0.id, t: $0.finishedAt, freeBytes: $0.freeAfter, freeBeforeBytes: $0.freeBefore, freedBytes: $0.freedBytes)
        }

        chart = Chart(
            windowStart: start, windowEnd: now, segments: segments, gaps: gaps, markers: markers,
            yRange: Self.yRange(for: points.map(\.freeBytes) + markers.flatMap { [$0.freeBytes, $0.freeBeforeBytes] })
        )
    }

    /// `1 day so far`, `2 days so far`, `3 days so far`: whole days rounded up, at least one and at most three.
    private static func daysSoFar(_ span: TimeInterval) -> String {
        let days = min(3, max(1, Int((span / 86_400).rounded(.up))))
        return days == 1 ? "1 day so far" : "\(days) days so far"
    }

    /// Zero to the next multiple of 25 GB above the highest value, and never less than 25 GB, so even a disk with nothing
    /// free has an axis.
    static func yRange(for values: [Int64]) -> YRange {
        let step = axisStepGB * 1_000_000_000
        let highest = values.max() ?? 0
        let top = max(step, (highest + step - 1) / step * step)
        return YRange(highGB: top / 1_000_000_000, lowLabel: "0", highLabel: SizeText.capacity(top))
    }
}
