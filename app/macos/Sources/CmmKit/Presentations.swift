import Foundation

// The cleaning, done and empty screens as plain values. The numbers are cmm's: free space and capacity from the plan,
// what was freed from the apply events. The app adds nothing but subtraction ("still to go") and the clock.

/// `just now`, `5 min ago`, `3 hours ago`, `yesterday`, `4 days ago`.
public enum RelativeAge {
    public static func text(since date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "just now" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 1 ? "yesterday" : "\(days) days ago"
    }
}

/// When a cleanup ended: `today at 14:03`, `yesterday at 14:03`, `15 Oct at 14:03` (the hour in the person's own style).
public enum FinishedAt {
    public static func text(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.setLocalizedDateFormatFromTemplate("jm")

        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
            day = formatter.string(from: date)
        }
        return "\(day) at \(time.string(from: date))"
    }
}

/// While cmm works: how much is freed so far, a line of progress, the five latest items fading as they age, and the band
/// with what is still to go.
public struct CleaningPresentation: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case removing
            case deleted
            case skipped
            case failed
            case other
        }

        public let id: String
        public let kind: Kind
        /// `Removing`, `Deleted`, `Skipped`, `Failed`.
        public let word: String
        public let path: String
        /// Why it was skipped or failed, shown after the path.
        public let reason: String?
        public let sizeText: String
        public let opacity: Double
    }

    /// The five rows fade from the newest to the oldest, as on the board.
    static let opacities: [Double] = [1.0, 0.9, 0.78, 0.5, 0.3]

    public let label: String
    public let number: SizeText.Parts
    public let sentence: String
    public let fraction: Double
    public let rows: [Row]
    public let stopTitle: String
    public let stopEnabled: Bool
    public let band: DiskBand?
    public let caption: BandText.Caption
    public let bandSentence: String

    public init(progress: CleanProgress, capacity: Int64?, home: String) {
        let finished = progress.items.count
        label = progress.stopRequested
            ? "Stopping after the current item · \(finished) of \(progress.total)"
            : "Cleaning · \(finished) of \(progress.total) · each item is checked again right before it goes"
        number = SizeText.parts(progress.freedBytes)
        sentence = "freed so far."
        fraction = progress.fraction
        stopTitle = progress.stopRequested ? "Stopping…" : "Stop"
        stopEnabled = !progress.stopRequested

        var rows: [Row] = []
        if let next = progress.inFlight {
            rows.append(Row(
                id: "removing:\(next.path)", kind: .removing, word: "Removing",
                path: PathFormat.shorten(next.path, home: home), reason: nil,
                sizeText: SizeText.string(next.bytes), opacity: 1
            ))
        }
        for event in progress.items.reversed() {
            rows.append(Self.row(for: event, home: home))
        }
        self.rows = rows.prefix(Self.opacities.count).enumerated().map { index, row in
            Row(id: row.id, kind: row.kind, word: row.word, path: row.path, reason: row.reason,
                sizeText: row.sizeText, opacity: Self.opacities[index])
        }

        let toGo = progress.toGoBytes
        band = DiskBand(
            capacity: capacity, free: progress.startFree, review: progress.reviewHeld, selected: toGo, freed: progress.freedBytes
        )
        caption = BandText.cleaning(capacity: capacity, freeNow: progress.freeNow, toGo: toGo)
        bandSentence = BandText.cleaningSentence(capacity: capacity, freeNow: progress.freeNow, toGo: toGo)
    }

    private static func row(for event: ItemEvent, home: String) -> Row {
        let kind: Row.Kind
        let word: String
        switch event.status {
        case .deleted: (kind, word) = (.deleted, "Deleted")
        case .skipped: (kind, word) = (.skipped, "Skipped")
        case .failed: (kind, word) = (.failed, "Failed")
        case .dryRun: (kind, word) = (.other, "Dry run")
        case .other(let name): (kind, word) = (.other, name.prefix(1).uppercased() + name.dropFirst())
        }
        return Row(
            id: "reported:\(event.path)", kind: kind, word: word, path: PathFormat.shorten(event.path, home: home),
            reason: event.reason.isEmpty ? nil : event.reason,
            // A deleted item shows what cmm says it freed; anything else shows the size it would have been.
            sizeText: SizeText.string(event.status == .deleted ? event.freedBytes : event.bytes), opacity: 1
        )
    }
}

/// After the cleanup: the free space now, what was freed, what was skipped or failed and why, and where the log is.
public struct DonePresentation: Equatable, Sendable {
    /// A skipped or failed item, with the reason cmm gave.
    public struct Issue: Identifiable, Equatable, Sendable {
        public let id: String
        public let path: String
        public let message: String
        /// A path Finder can show (for a failed item); nil for a skipped one or a label that is not a path.
        public let revealPath: String?
    }

    public struct Log: Equatable, Sendable {
        public let path: String
        public let revealPath: String
    }

    public let label: String
    public let number: SizeText.Parts
    public let sentence: String
    /// `Up from 19.8 GB. 5.4 GB freed.` with the last sentence emphasized.
    public let comparison: [BandText.Run]
    public let deletedText: String
    public let skippedText: String
    public let failedText: String
    public let issues: [Issue]
    public let log: Log?
    public let warnings: [String]
    /// Sentences about the run itself: that it was stopped, that some of cmm's output could not be read.
    public let notes: [String]
    public let band: DiskBand?
    public let caption: BandText.Caption
    public let bandSentence: String

    public init(
        summary: CleanSummary, capacity: Int64?, volumeName: String, home: String,
        now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) {
        let done = summary.done
        let when = FinishedAt.text(summary.finishedAt, now: now, calendar: calendar, locale: locale)
        label = [done.stopped ? "Stopped" : "Done", volumeName.isEmpty ? nil : volumeName, when].compactMap { $0 }.joined(separator: " · ")
        number = SizeText.parts(done.freeAfter)
        sentence = "free now."
        comparison = [
            .plain("Up from \(SizeText.string(done.freeBefore)). "),
            .strong(done.freedBytes > 0 ? "\(SizeText.string(done.freedBytes)) freed." : "Nothing freed."),
        ]
        deletedText = "\(done.deleted) deleted"
        skippedText = "\(done.skipped) skipped"
        failedText = "\(done.failed) failed"

        issues = summary.items.compactMap { event in
            let reason = event.reason.isEmpty ? "" : ", \(event.reason)"
            switch event.status {
            case .skipped:
                return Issue(id: event.path, path: PathFormat.shorten(event.path, home: home),
                             message: "skipped\(reason) · offered again next scan", revealPath: nil)
            case .failed:
                return Issue(id: event.path, path: PathFormat.shorten(event.path, home: home),
                             message: "failed\(reason)", revealPath: event.path.hasPrefix("/") ? event.path : nil)
            default:
                return nil
            }
        }
        log = done.log.map { Log(path: PathFormat.shorten($0, home: home), revealPath: $0) }
        warnings = done.warnings

        var notes: [String] = []
        if done.stopped { notes.append("Stopped early. Items after the one in progress were not touched.") }
        if summary.unreadableLines > 0 {
            let lines = summary.unreadableLines == 1 ? "1 line" : "\(summary.unreadableLines) lines"
            notes.append("\(lines) of cmm's output could not be read; the figures above are cmm's own.")
        }
        self.notes = notes

        band = DiskBand(capacity: capacity, free: done.freeBefore, review: summary.reviewHeld, freed: done.freedBytes)
        caption = BandText.done(capacity: capacity, freeBefore: done.freeBefore, freeAfter: done.freeAfter)
        bandSentence = BandText.doneSentence(capacity: capacity, freeAfter: done.freeAfter, freed: done.freedBytes)
    }
}

/// Nothing to clean: the free space, why anything was held back, and the band of a disk with nothing to offer.
public struct EmptyPresentation: Equatable, Sendable {
    public let label: String
    public let number: SizeText.Parts
    public let sentence: String
    public let heldSentence: String?
    public let band: DiskBand?
    public let caption: BandText.Caption
    public let bandSentence: String

    public init(plan: Plan, volumeName: String, now: Date, calendar: Calendar = .current) {
        let free = plan.host.freeBytes
        let capacity = DiskBand.validCapacity(plan.host.capacityBytes, free: free)
        let scanned = "scanned \(RelativeAge.text(since: plan.generatedAt, now: now, calendar: calendar))"
        label = volumeName.isEmpty ? scanned.prefix(1).uppercased() + scanned.dropFirst() : "\(volumeName) · \(scanned)"
        number = SizeText.parts(free)
        sentence = "free. Nothing to clean today."
        heldSentence = HeldBack.sentence(for: DetailsModel.heldRows(selection: SelectionModel(plan: plan)))
        band = DiskBand(capacity: capacity, free: free)
        caption = BandText.empty(capacity: capacity, free: free)
        bandSentence = BandText.emptySentence(capacity: capacity, free: free)
    }
}
