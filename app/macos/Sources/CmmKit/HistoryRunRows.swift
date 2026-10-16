import Foundation

/// The list under the chart (spec R4 and the boards): the cleanings, newest first, grouped by calendar week in the person's
/// own time, each week with what it gave back. A row says when, what came back to the disk, which groups went, what failed
/// or stopped and, apart and never added to anything, what was freed inside another program's storage. Opening a row lists
/// its items and says what the disk's free space did.
public struct RunRows: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            case deleted
            case failed
            case other
        }

        public let id: String
        /// The path with the home folder written `~`, or, for a command, the label cmm gave it, as it is.
        public let title: String
        /// After the title: `deleted`, `deleted inside Docker's disk image`, or why it failed (`permission denied`).
        public let detail: String
        public let sizeText: String
        public let status: Status
        /// Where the space went when it was not the disk: the size is then dotted and amber, not counted.
        public let insidePlace: String?
    }

    public struct Row: Identifiable, Equatable, Sendable {
        /// The id of the run, which the chart's marker shares.
        public let id: String
        public let finishedAt: Date
        /// `Wed 14 Oct`, with the year (`Wed 14 Oct 2024`) only when it is more than a year ago.
        public let dateText: String
        /// `14:20`
        public let timeText: String
        /// What the disk got back, in bytes.
        public let freedBytes: Int64
        /// `5.4 GB freed`, or `0 GB freed` for a run that gave the disk nothing back.
        public let freedText: String
        /// `Idle lane dependencies, uv cache, Go build cache`: the groups of the items that were deleted, largest first, three
        /// at most and then `and 4 more`.
        public let groupsText: String?
        /// `1 failed`, shown in the failed colour.
        public let failedText: String?
        /// `Stopped`, or `Stopped after 2 of 9` when cmm said how many it meant to do.
        public let stoppedText: String?
        /// `9.0 GB inside Docker's disk image, not counted`, shown dotted and amber, apart from the figure above.
        public let insideText: String?
        public let items: [Item]
        /// `and 812 more, not listed`: the items that did not fit in the line cmm wrote.
        public let omittedText: String?
        /// `Freed is what the disk got back: 17.0 → 19.2 GB free.` under the items; nil for a run that freed nothing.
        public let footnote: String?

        public var hasDetails: Bool { !items.isEmpty || omittedText != nil }
    }

    public struct Week: Identifiable, Equatable, Sendable {
        public let id: String
        /// The first moment of the week in the person's calendar.
        public let start: Date
        /// `This week`, `Last week`, `29 Sep – 5 Oct`.
        public let title: String
        /// What the week gave the disk back: the sum of its rows, never Docker's figure.
        public let freedBytes: Int64
        /// `5.4 GB`
        public let totalText: String
        public let rows: [Row]
    }

    /// How many groups a row names before it says `and N more`.
    static let namedGroups = 3

    public let weeks: [Week]
    /// `2 lines of the history could not be read.`: only when there are such lines.
    public let footnote: String?

    public var isEmpty: Bool { weeks.isEmpty }

    public init(report: HistoryReport, now: Date, calendar: Calendar, locale: Locale, home: String) {
        let report = report.asOf(now)
        let dates = Dates(calendar: calendar, locale: locale, now: now)

        let thisWeek = dates.weekStart(of: now)
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek.addingTimeInterval(-7 * 86_400)

        var weeks: [Week] = []
        var start: Date?
        var rows: [Row] = []
        func closeWeek() {
            guard let opened = start, !rows.isEmpty else { return }
            let freed = HistoryLimits.sum(rows.map(\.freedBytes))
            let title: String
            if opened == thisWeek {
                title = "This week"
            } else if opened == lastWeek {
                title = "Last week"
            } else {
                title = dates.rangeText(ofWeekStarting: opened)
            }
            weeks.append(Week(
                id: "\(Int64(opened.timeIntervalSince1970))", start: opened, title: title, freedBytes: freed,
                totalText: SizeText.string(freed), rows: rows
            ))
            rows = []
        }

        // newest first, so the runs of one week are next to each other
        for run in report.runs {
            let opened = dates.weekStart(of: run.finishedAt)
            if opened != start {
                closeWeek()
                start = opened
            }
            rows.append(Self.row(for: run, dates: dates, home: home))
        }
        closeWeek()

        self.weeks = weeks
        let unread = report.unreadableLines + report.ignoredEntries
        footnote = unread == 0 ? nil : unread == 1 ? "1 line of the history could not be read." : "\(unread) lines of the history could not be read."
    }

    // MARK: dates

    /// The formatters and the weeks of one list, made once: a list may be ten thousand rows long.
    private struct Dates {
        let calendar: Calendar
        let yearAgo: Date
        let day: DateFormatter
        let dayWithYear: DateFormatter
        let time: DateFormatter
        let shortDay: DateFormatter
        let shortDayWithYear: DateFormatter

        init(calendar: Calendar, locale: Locale, now: Date) {
            self.calendar = calendar
            yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now.addingTimeInterval(-365 * 86_400)
            day = HistoryDates.formatter("EEEdMMM", calendar: calendar, locale: locale)
            dayWithYear = HistoryDates.formatter("EEEdMMMy", calendar: calendar, locale: locale)
            time = HistoryDates.formatter("jm", calendar: calendar, locale: locale)
            shortDay = HistoryDates.formatter("dMMM", calendar: calendar, locale: locale)
            shortDayWithYear = HistoryDates.formatter("dMMMy", calendar: calendar, locale: locale)
        }

        /// The first moment of the calendar week a moment is in. (The week of the calendar, not a number of the year: a week
        /// that runs across New Year, or across a change of the clock, is one week.)
        func weekStart(of date: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }

        func isOld(_ date: Date) -> Bool { date < yearAgo }

        /// `29 Sep – 5 Oct`: the week's first and last day, with the year on both when the week is more than a year old.
        func rangeText(ofWeekStarting start: Date) -> String {
            let last = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let format = isOld(start) ? shortDayWithYear : shortDay
            return "\(format.string(from: start)) \u{2013} \(format.string(from: last))"
        }
    }

    // MARK: a row

    private static func row(for run: HistoryRun, dates: Dates, home: String) -> Row {
        let when = dates.isOld(run.finishedAt) ? dates.dayWithYear : dates.day
        return Row(
            id: run.id,
            finishedAt: run.finishedAt,
            dateText: when.string(from: run.finishedAt),
            timeText: dates.time.string(from: run.finishedAt),
            freedBytes: run.freedBytes,
            freedText: "\(SizeText.string(run.freedBytes)) freed",
            groupsText: groupsText(for: run),
            failedText: run.failed > 0 ? "\(run.failed) failed" : nil,
            stoppedText: stoppedText(for: run),
            insideText: insideText(for: run),
            items: items(of: run, home: home),
            omittedText: run.itemsOmitted > 0 ? "and \(run.itemsOmitted) more, not listed" : nil,
            footnote: footnote(for: run)
        )
    }

    /// The groups of the items that were deleted, largest first (what each gave, the sizes of its items added up; the same
    /// size by name), named by the catalog. Only the first name keeps its capital: `Unavailable simulators, idle lane
    /// dependencies, Go build cache`.
    private static func groupsText(for run: HistoryRun) -> String? {
        var totals: [String: Int64] = [:]
        for item in run.items where item.status == .deleted {
            let name = RuleCatalog.title(rule: item.rule, label: item.group)
            guard !name.isEmpty else { continue }
            totals[name] = HistoryLimits.sum([totals[name] ?? 0, item.freedBytes])
        }
        let names = totals.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(namedGroups).enumerated().map { index, name in index == 0 ? name : RuleCatalog.midSentence(name) }
        let more = names.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }

    /// `Stopped`, and how far it got only when cmm said how many it meant to do and that makes sense: the items it dealt with
    /// (deleted, skipped or failed) are at least one and no more than that.
    private static func stoppedText(for run: HistoryRun) -> String? {
        guard run.stopped else { return nil }
        let reached = run.deleted + run.skipped + run.failed
        if let planned = run.planned, reached > 0, reached <= planned { return "Stopped after \(reached) of \(planned)" }
        return "Stopped"
    }

    /// What went inside another program's storage: cmm's own total, and the places the items name (or a generic one).
    private static func insideText(for run: HistoryRun) -> String? {
        guard run.freedInsideBytes > 0 else { return nil }
        var places: [String] = []
        for item in run.items {
            if let place = item.freesInside, !places.contains(place) { places.append(place) }
        }
        let where_ = places.isEmpty ? Inside.fallbackPlace : HeldBack.join(places)
        return "\(SizeText.string(run.freedInsideBytes)) inside \(where_), not counted"
    }

    /// `Freed is what the disk got back: 17.0 → 19.2 GB free.` The first figure drops its unit when it is the second's.
    private static func footnote(for run: HistoryRun) -> String? {
        guard run.freedBytes > 0 else { return nil }
        let before = SizeText.parts(run.freeBefore)
        let after = SizeText.parts(run.freeAfter)
        let first = before.unit == after.unit ? before.value : before.text
        return "Freed is what the disk got back: \(first) \u{2192} \(after.text) free."
    }

    /// The items of the run, largest first by the size each row shows: what a deleted item freed, what any other would have.
    private static func items(of run: HistoryRun, home: String) -> [Item] {
        let shown = run.items.enumerated().map { offset, item -> (offset: Int, size: Int64, item: HistoryItem) in
            (offset, item.status == .deleted ? item.freedBytes : item.bytes, item)
        }
        return shown.sorted { ($1.size, $0.offset) < ($0.size, $1.offset) }.map { entry in
            let item = entry.item
            let status: Item.Status
            let detail: String
            switch item.status {
            case .deleted:
                (status, detail) = (.deleted, item.freesInside.map { "deleted inside \($0)" } ?? "deleted")
            case .failed:
                (status, detail) = (.failed, item.reason ?? "failed")
            case .skipped:
                (status, detail) = (.other, item.reason ?? "skipped")
            case .dryRun:
                (status, detail) = (.other, item.reason ?? "dry run")
            case .other(let name):
                (status, detail) = (.other, item.reason ?? name)
            }
            return Item(
                id: "\(run.id)/\(entry.offset)", title: PathFormat.shorten(item.path, home: home), detail: detail,
                sizeText: SizeText.string(entry.size), status: status, insidePlace: item.freesInside
            )
        }
    }
}
