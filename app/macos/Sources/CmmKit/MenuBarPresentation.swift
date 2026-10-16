import Foundation

/// The menu bar item itself: the free space beside the icon, an amber dot under 10 GB, and what VoiceOver says (the dot is
/// never the only signal).
public struct MenuBarItem: Equatable, Sendable {
    /// `19.8 GB`; nil until something has said how much is free (the icon stands alone).
    public let title: String?
    public let isLow: Bool
    /// `19.8 GB free`, `8.1 GB free, low on space`.
    public let accessibilityLabel: String
}

/// What the popover writes, line by line, for the state it is in (the board `C-MenuBar-States`).
public struct MenuBarPopover: Equatable, Sendable {
    public struct Header: Equatable, Sendable {
        /// `Low on space`, set in bold after an amber dot.
        public let lead: String?
        /// `Macintosh HD · 19.8 GB free`, or `8.1 GB free` after the lead.
        public let detail: String

        public var text: String { [lead, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") }
    }

    public struct HistoryRow: Equatable, Sendable {
        /// `Last cleaned Tue · 5.4 GB`, or `See it in History` right after a cleaning.
        public let text: String
    }

    public let header: Header
    /// The big number: what can go, what was freed, or, when nothing can go, what is free. Nil while it is working.
    public let number: SizeText.Parts?
    /// The serif line under it: `can go.`, `free. Nothing to clean.`, `freed just now.`, `Checking what can go…`
    public let sentence: String
    /// `Only looks. Nothing is removed from here.` while it scans.
    public let note: String?
    /// The three largest groups that can go.
    public let groups: [GroupLine]
    public let band: DiskBand?
    public let historyRow: HistoryRow?
    /// `Scan`, or `Scanning…` while it does.
    public let scanTitle: String
    /// The window's own rule for ⌘R: not while a scan or a cleanup runs, nor while the confirmation card is open.
    public let canScan: Bool
    /// A scan or a cleaning is running: the spinner turns (and stops under Reduce Motion).
    public let isBusy: Bool
    /// What VoiceOver reads, in order: the one thing to act on, then the free space.
    public let spoken: String
}

/// Everything the menu bar shows, for one moment.
public struct MenuBarPresentation: Equatable, Sendable {
    public let state: MenuBarState
    public let item: MenuBarItem
    public let popover: MenuBarPopover
    /// When this will say something else without anything happening: the end of "just cleaned". Nil when it will not.
    public let changesAt: Date?
}

// MARK: what each state writes

extension MenuBarContext {
    /// The item and the popover for one moment, as the boards write them. `confirmationOpen` is whether the window's
    /// confirmation card is up: `Scan` follows the window's own rule for ⌘R (not while a scan or a cleanup runs, and not while
    /// the card is open, because a scan would take the card away).
    public func presentation(
        phase: AppModel.Phase, confirmationOpen: Bool, volumeName: String, now: Date, calendar: Calendar, locale: Locale
    ) -> MenuBarPresentation {
        let state = self.state(phase: phase, now: now)
        let free = reading?.bytes
        let capacity = reading?.capacity ?? lastScan?.capacity
        let working = phase == .scanning || phase == .cleaning
        func size(_ bytes: Int64) -> String { SizeText.string(bytes) }

        let item = MenuBarItem(
            title: free.map(size),
            isLow: free.map { $0 < MenuBarState.lowBelowBytes } ?? false,
            accessibilityLabel: free.map { $0 < MenuBarState.lowBelowBytes ? "\(size($0)) free, low on space" : "\(size($0)) free" } ?? "cmm"
        )

        /// `Macintosh HD · 19.8 GB free`: the volume, and the free space when the header carries it.
        func header(_ free: Int64?) -> MenuBarPopover.Header {
            let parts = [volumeName.isEmpty ? nil : volumeName, free.map { "\(size($0)) free" }].compactMap { $0 }
            return MenuBarPopover.Header(lead: nil, detail: parts.joined(separator: " \u{00B7} "))
        }

        var popover = MenuBarPopover(
            header: header(free), number: nil, sentence: "", note: nil, groups: [], band: nil,
            historyRow: lastCleanedRow(now: now, calendar: calendar, locale: locale),
            scanTitle: phase == .scanning ? "Scanning\u{2026}" : "Scan", canScan: !working && !confirmationOpen, isBusy: working, spoken: ""
        )
        let review = lastScan?.reviewBytes ?? 0
        let groups = lastScan?.groups ?? []

        switch state {
        case .ready(let canGo, let free):
            popover = popover.with(
                header: header(free), number: SizeText.parts(canGo), sentence: "can go.", groups: groups,
                band: DiskBand(capacity: capacity, free: free, review: review, selected: canGo),
                spoken: "\(size(canGo)) can go. \(size(free)) free."
            )
        case .nothingToClean(let free):
            popover = popover.with(
                header: header(nil), number: SizeText.parts(free), sentence: "free. Nothing to clean.",
                band: DiskBand(capacity: capacity, free: free, review: review), spoken: "\(size(free)) free. Nothing to clean."
            )
        case .low(let free, let canGo):
            let lead = MenuBarPopover.Header(lead: "Low on space", detail: "\(size(free)) free")
            if canGo > 0 {
                popover = popover.with(
                    header: lead, number: SizeText.parts(canGo), sentence: "can go.", groups: groups,
                    band: DiskBand(capacity: capacity, free: free, review: review, selected: canGo),
                    spoken: "Low on space. \(size(canGo)) can go. \(size(free)) free."
                )
            } else {
                popover = popover.with(
                    header: lead, number: SizeText.parts(free), sentence: "free. Nothing to clean.",
                    band: DiskBand(capacity: capacity, free: free, review: review),
                    spoken: "Low on space. \(size(free)) free. Nothing to clean."
                )
            }
        case .scanning:
            popover = popover.with(
                sentence: "Checking what can go\u{2026}", note: "Only looks. Nothing is removed from here.",
                band: free.flatMap { DiskBand(capacity: capacity, free: $0) },
                spoken: "Checking what can go. Only looks. Nothing is removed from here."
            )
        case .cleaning:
            popover = popover.with(sentence: "Cleaning\u{2026}", band: nil, spoken: "Cleaning.")
        case .justCleaned(let freed, let free):
            popover = popover.with(
                header: header(free), number: SizeText.parts(freed), sentence: "freed just now.",
                band: DiskBand(capacity: capacity, free: max(free - freed, 0), freed: freed),
                historyRow: MenuBarPopover.HistoryRow(text: "See it in History"),
                spoken: "Freed \(size(freed)). \(size(free)) free."
            )
        case .unknown:
            popover = popover.with(
                sentence: "Scan to see what can go.", band: free.flatMap { DiskBand(capacity: capacity, free: $0) },
                spoken: "Scan to see what can go."
            )
        }

        var changesAt: Date?
        if case .justCleaned = state, let cleaning { changesAt = cleaning.finishedAt.addingTimeInterval(MenuBarState.justCleanedFor) }
        return MenuBarPresentation(state: state, item: item, popover: popover, changesAt: changesAt)
    }

    /// `Last cleaned Tue · 5.4 GB`: the weekday for the last six days (a seventh would be today's weekday again), a date after
    /// that, with the year when it is more than a year ago.
    private func lastCleanedRow(now: Date, calendar: Calendar, locale: Locale) -> MenuBarPopover.HistoryRow? {
        guard let cleaning else { return nil }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: cleaning.finishedAt), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let template: String
        if (0...6).contains(days) {
            template = "EEE"
        } else {
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now.addingTimeInterval(-365 * 86_400)
            template = cleaning.finishedAt < yearAgo ? "dMMMy" : "dMMM"
        }
        let when = HistoryDates.formatter(template, calendar: calendar, locale: locale).string(from: cleaning.finishedAt)
        return MenuBarPopover.HistoryRow(text: "Last cleaned \(when) \u{00B7} \(SizeText.string(cleaning.freedBytes))")
    }
}

extension MenuBarPopover {
    /// The popover with what a state writes put over what every state has.
    fileprivate func with(
        header: Header? = nil, number: SizeText.Parts? = nil, sentence: String, note: String? = nil, groups: [GroupLine] = [],
        band: DiskBand?, historyRow: HistoryRow? = nil, spoken: String
    ) -> MenuBarPopover {
        MenuBarPopover(
            header: header ?? self.header, number: number, sentence: sentence, note: note, groups: groups, band: band,
            historyRow: historyRow ?? self.historyRow, scanTitle: scanTitle, canScan: canScan, isBusy: isBusy, spoken: spoken
        )
    }
}
