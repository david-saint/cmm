import Foundation

/// The sentences above the History list (spec R3 and the board's paragraph): what the cleanings gave the disk back, and how
/// the free space has moved since a week ago.
public enum HistorySentences {
    /// What the cleanings of the last ninety days gave the disk back.
    public struct FreedTotals: Equatable, Sendable {
        /// The sum of what the volume got back (`freed_bytes`). Docker's figure, which is freed inside Docker's disk
        /// image, is never in it.
        public let bytes: Int64
        /// The cleanings that gave the disk something back. A run that freed nothing on the disk (only Docker's prune, say)
        /// is listed in the rows but not counted.
        public let cleanings: Int
        /// When the oldest of them ended.
        public let since: Date
    }

    /// The cleanings that ended in the last ninety days (and not after `now`) and gave the disk something back, or nil
    /// when there are none. The history holds every cleaning cmm remembers, so the window is cut here.
    public static func freedTotals(report: HistoryReport, now: Date) -> FreedTotals? {
        let start = now.addingTimeInterval(-Double(HistoryTimeline.windowDays) * 86_400)
        let counted = report.asOf(now).runs.filter { $0.finishedAt >= start && $0.freedBytes > 0 }
        guard let oldest = counted.map(\.finishedAt).min() else { return nil }
        return FreedTotals(bytes: HistoryLimits.sum(counted.map(\.freedBytes)), cleanings: counted.count, since: oldest)
    }

    /// `Freed 44.0 GB in 3 cleanings since 29 Sep.`, or nil when no cleaning in the window gave anything back.
    public static func totalsSentence(report: HistoryReport, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard let totals = freedTotals(report: report, now: now) else { return nil }
        let day = HistoryDates.formatter("dMMM", calendar: calendar, locale: locale).string(from: totals.since)
        let cleanings = totals.cleanings == 1 ? "1 cleaning" : "\(totals.cleanings) cleanings"
        return "Freed \(SizeText.string(totals.bytes)) in \(cleanings) since \(day)."
    }

    /// The paragraph under the tabs: the totals sentence and the change over the week, whichever there are, as the board
    /// sets them (`Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago.`). It is also what
    /// the chart says to VoiceOver as its one summary.
    public static func summary(totals: String?, weekChange: WeekChange?) -> String? {
        let parts = [totals, weekChange?.text].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
