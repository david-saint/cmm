import Foundation

/// The free-space chart of the History face, as plain values: the points, the segments they make, one marker per cleanup,
/// the "now" point, and the range of the vertical axis. The view only draws what this says.
///
/// The rules (spec R1): two readings more than six hours apart are never joined (the app was not running, and nothing is
/// guessed for the time in between); nothing is forecast; the axis is whole gigabytes and at least five of them tall, so
/// small movements do not look dramatic; and with fewer than three days of samples there is no chart at all, only a plain
/// sentence, because a few points are not a trend.
public struct HistoryTimeline: Equatable, Sendable {
    /// How far back the chart looks.
    public static let windowDays = 90
    /// Two readings further apart than this are not joined by a line.
    public static let gap: TimeInterval = 6 * 3_600
    /// Samples that cover less time than this are not a trend.
    public static let minimumSpan: TimeInterval = 3 * 86_400
    /// The axis is at least this many gigabytes tall.
    public static let minimumHeightGB: Int64 = 5
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

    /// A cleanup, at the moment it ended and the free space it left.
    public struct Marker: Equatable, Sendable, Identifiable {
        /// The id of the run (`HistoryRun.id`), which its row in the list shares.
        public let id: String
        public let t: Date
        public let freeBytes: Int64
        /// What the disk got back (never Docker's figure), so a run that freed nothing can be drawn as such.
        public let freedBytes: Int64
    }

    /// The vertical axis: whole gigabytes, floor of the lowest reading to ceiling of the highest, at least five tall.
    public struct YRange: Equatable, Sendable {
        public let lowGB: Int64
        public let highGB: Int64
        public var lowBytes: Int64 { lowGB * 1_000_000_000 }
        public var highBytes: Int64 { highGB * 1_000_000_000 }
        /// `18 GB`
        public let lowLabel: String
        /// `24 GB`
        public let highLabel: String
    }

    public struct Chart: Equatable, Sendable {
        public let windowStart: Date
        public let windowEnd: Date
        public let segments: [Segment]
        public let markers: [Marker]
        public let yRange: YRange
    }

    public enum Display: Equatable, Sendable {
        /// Not enough history for a chart: say so, plainly.
        case fillingIn(String)
        case chart(Chart)
    }

    public let display: Display

    /// - Parameter now: the moment the person is looking, taken after the report arrived. Anything the report dates later
    ///   than `now` is not believed and not drawn.
    public init(report: HistoryReport, now: Date) {
        let report = report.asOf(now)
        let start = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)

        // "Days of samples" are counted between the first and the last note in the window; the disk now is not a note.
        let samples = report.samples.filter { $0.t >= start }
        guard let first = samples.first, let last = samples.last, last.t.timeIntervalSince(first.t) >= Self.minimumSpan else {
            display = .fillingIn(Self.fillingInMessage)
            return
        }

        var points = samples.map { Point(t: $0.t, freeBytes: $0.freeBytes, isNow: false) }
        // The disk now, as cmm read it when it made the report, if that is newer than the last note. It is dated by the
        // report (never later than now) and takes part in the gap rule like any other reading.
        if let free = report.host.freeBytes {
            let read = min(report.generatedAt ?? now, now)
            if read >= start, read > last.t { points.append(Point(t: read, freeBytes: free, isNow: true)) }
        }

        var segments: [Segment] = []
        var current: [Point] = []
        for point in points {
            if let previous = current.last, point.t.timeIntervalSince(previous.t) > Self.gap {
                segments.append(Segment(points: current))
                current = []
            }
            current.append(point)
        }
        segments.append(Segment(points: current))

        // oldest first, like the points (the report lists its runs newest first)
        let markers = report.runs.reversed().filter { $0.finishedAt >= start }.map {
            Marker(id: $0.id, t: $0.finishedAt, freeBytes: $0.freeAfter, freedBytes: $0.freedBytes)
        }

        display = .chart(Chart(
            windowStart: start, windowEnd: now, segments: segments, markers: markers,
            yRange: Self.yRange(for: points.map(\.freeBytes) + markers.map(\.freeBytes))
        ))
    }

    /// Whole gigabytes, from the floor of the lowest value to the ceiling of the highest. An axis shorter than five of them
    /// is made five tall around what it holds (the extra below first, rounded down), and one that would go below zero
    /// starts at zero and keeps its height.
    static func yRange(for values: [Int64]) -> YRange {
        let gigabyte: Int64 = 1_000_000_000
        var low = (values.min() ?? 0) / gigabyte
        var high = ((values.max() ?? 0) + gigabyte - 1) / gigabyte
        if high - low < minimumHeightGB {
            low -= (minimumHeightGB - (high - low)) / 2
            high = low + minimumHeightGB
            if low < 0 {
                high -= low
                low = 0
            }
        }
        return YRange(
            lowGB: low, highGB: high, lowLabel: SizeText.capacity(low * gigabyte), highLabel: SizeText.capacity(high * gigabyte)
        )
    }
}
