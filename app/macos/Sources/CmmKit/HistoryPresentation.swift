import Foundation

/// Everything the History face says, from one report: the paragraph, the line, the weeks of cleanings, and what to say when
/// there is nothing yet (spec R1 to R4 and the board `C-History-States`). It only composes what the pieces work out, so the
/// face has one value to draw and nothing to decide.
public struct HistoryPresentation: Equatable, Sendable {
    /// Where the list would be, when no cleaning has ever been made: the first run.
    public static let emptyMessage = "Nothing cleaned yet. When you clean, it shows up here."

    /// `Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago.`, whichever halves there are.
    public let summary: String?
    /// The line and the words under it. Nil when the free-space history is switched off, and before there is anything at all
    /// to show (no line and no cleaning): the face then says only `emptyMessage`.
    public let timeline: HistoryTimeline?
    public let rows: RunRows
    /// Nil once a cleaning has been made.
    public let emptyMessage: String?

    /// - Parameter historyEnabled: whether "Keep a free-space history" is on. Off, the cleanings are still listed (they come
    ///   from cmm's cleaning journal, not from the notes of the free space) but there is no line and no week-over-week change.
    public init(report: HistoryReport, historyEnabled: Bool, now: Date, calendar: Calendar, locale: Locale, home: String) {
        let rows = RunRows(report: report, now: now, calendar: calendar, locale: locale, home: home)
        let weekChange = historyEnabled ? WeekChange(report: report, now: now) : nil
        summary = HistorySentences.summary(
            totals: HistorySentences.totalsSentence(report: report, now: now, calendar: calendar, locale: locale),
            weekChange: weekChange
        )
        // Before there is a line or a cleaning there is nothing true to say about either, so the face says only that.
        let timeline = historyEnabled ? HistoryTimeline(report: report, now: now) : nil
        self.timeline = timeline?.chart == nil && rows.isEmpty ? nil : timeline
        self.rows = rows
        emptyMessage = rows.isEmpty ? Self.emptyMessage : nil
    }
}
