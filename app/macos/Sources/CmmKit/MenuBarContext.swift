import Foundation

/// One reading of the volume: how much is free, when that was true, and, when known, how big the volume is.
public struct FreeReading: Equatable, Sendable {
    public let bytes: Int64
    public let capacity: Int64?
    public let at: Date
}

/// A line of the popover's list: a group of things that can go, and how much.
public struct GroupLine: Equatable, Sendable {
    public let title: String
    public let bytes: Int64
    public let sizeText: String
}

/// What the app last scanned, as the popover shows it. It is kept in memory only: nothing about a scan is ever stored
/// (spec R9).
public struct LastScan: Equatable, Sendable {
    /// How many groups the popover lists.
    static let listed = 3

    /// When cmm made the plan, and never later than the moment the app received it.
    public let at: Date
    public let free: Int64
    public let capacity: Int64?
    /// What can go: the safe items that give the disk its space back. Never a review item (Docker's), and never an item whose
    /// space is freed inside another program's storage, whatever its tier.
    public let canGo: Int64
    /// What cmm offers for a look (dotted on the band): never in `canGo`.
    public let reviewBytes: Int64
    /// The three largest groups that can go, largest first.
    public let groups: [GroupLine]

    public init(plan: Plan, scannedAt: Date) {
        // the plan is read the way the window reads it: an item once, however many times its path is listed
        let selection = SelectionModel(plan: plan)
        let lines = selection.groups(in: .safe).compactMap { group -> GroupLine? in
            let bytes = group.items.filter { $0.freesInside == nil }.map { max($0.bytes, 0) }.saturatingTotal()
            guard bytes > 0 else { return nil }
            return GroupLine(title: RuleCatalog.title(rule: group.rule, label: group.name), bytes: bytes, sizeText: SizeText.string(bytes))
        }
        .sorted { ($1.bytes, $0.title) < ($0.bytes, $1.title) }

        at = min(plan.generatedAt ?? scannedAt, scannedAt)
        free = max(plan.host.freeBytes, 0)
        capacity = DiskBand.validCapacity(plan.host.capacityBytes, free: max(plan.host.freeBytes, 0))
        canGo = lines.map(\.bytes).saturatingTotal()
        reviewBytes = max(selection.reviewBytes, 0)
        groups = Array(lines.prefix(Self.listed))
    }
}

/// A cleaning that gave the disk something back: from the window's own done screen, or from the newest such run of the
/// history. A run that freed nothing on the disk (only Docker's prune) is not one.
public struct CleaningRecord: Equatable, Sendable {
    public let finishedAt: Date
    public let freedBytes: Int64
    public let freeAfter: Int64

    init(finishedAt: Date, freedBytes: Int64, freeAfter: Int64) {
        self.finishedAt = finishedAt
        self.freedBytes = freedBytes
        self.freeAfter = freeAfter
    }

    public init?(summary: CleanSummary) {
        guard summary.done.freedBytes > 0 else { return nil }
        self.init(finishedAt: summary.finishedAt, freedBytes: summary.done.freedBytes, freeAfter: max(summary.done.freeAfter, 0))
    }

    /// The newest cleaning in the report that gave the disk something back, as of `now`.
    public static func newest(in report: HistoryReport, now: Date) -> CleaningRecord? {
        guard let run = report.asOf(now).runs.first(where: { $0.freedBytes > 0 }) else { return nil }
        return CleaningRecord(finishedAt: run.finishedAt, freedBytes: run.freedBytes, freeAfter: run.freeAfter)
    }
}

/// Everything the menu bar item knows between one look and the next, in memory only: the last scan, the newest cleaning, and
/// the freshest word on how much is free, from whichever of them said it last. A value: whoever holds it (the app, a test)
/// tells it what happened and asks it what to show.
public struct MenuBarContext: Equatable, Sendable {
    public private(set) var lastScan: LastScan?
    public private(set) var cleaning: CleaningRecord?
    public private(set) var reading: FreeReading?

    public init() {}

    // MARK: what happened

    /// A scan finished, the window's own or the weekly one's.
    public mutating func recordScan(plan: Plan, at: Date) {
        let scan = LastScan(plan: plan, scannedAt: at)
        lastScan = scan
        note(FreeReading(bytes: scan.free, capacity: scan.capacity, at: scan.at))
    }

    /// `cmm sample` answered. Whether or not it wrote a note, it read the free space.
    public mutating func recordSample(_ sample: SampleResult, receivedAt: Date) {
        note(FreeReading(
            bytes: sample.freeBytes, capacity: sample.capacityBytes.flatMap { $0 > 0 ? $0 : nil },
            at: sample.t.map { min($0, receivedAt) } ?? receivedAt
        ))
    }

    /// A history report arrived: the disk as cmm read it, and the newest cleaning that gave something back.
    public mutating func recordHistory(_ report: HistoryReport, now: Date) {
        if let free = report.host.freeBytes {
            note(FreeReading(bytes: free, capacity: report.host.capacityBytes, at: min(report.generatedAt ?? now, now)))
        }
        if let record = CleaningRecord.newest(in: report, now: now) { keep(record) }
    }

    /// The window finished a cleaning. One that gave the disk nothing back (Docker's prune) changes nothing here.
    public mutating func recordCleaning(_ summary: CleanSummary) {
        if let record = CleaningRecord(summary: summary) { keep(record) }
    }

    private mutating func keep(_ record: CleaningRecord) {
        if let existing = cleaning, existing.finishedAt >= record.finishedAt { return }
        cleaning = record
        note(FreeReading(bytes: record.freeAfter, capacity: nil, at: record.finishedAt))
    }

    /// The freshest reading wins, and of two at the same moment the one that arrived last.
    private mutating func note(_ new: FreeReading) {
        if let current = reading, current.at > new.at { return }
        reading = new
    }

    // MARK: which state

    /// The precedence, from the top: a scan or a cleaning that is running; an hour after a cleaning that gave something back;
    /// no scan, or a scan older than the last cleaning (what it said could go has gone, and nothing says what can now), which
    /// are unknown; then low space, then something that can go, then nothing to clean.
    public func state(phase: AppModel.Phase, now: Date) -> MenuBarState {
        switch phase {
        case .scanning: return .scanning
        case .cleaning: return .cleaning
        default: break
        }

        if let cleaning {
            let elapsed = now.timeIntervalSince(cleaning.finishedAt)
            if elapsed >= 0, elapsed < MenuBarState.justCleanedFor {
                return .justCleaned(freed: cleaning.freedBytes, free: reading?.bytes ?? cleaning.freeAfter)
            }
        }
        guard let scan = lastScan else { return .unknown }
        if let cleaning, cleaning.finishedAt > scan.at { return .unknown }

        let free = reading?.bytes ?? scan.free
        if free < MenuBarState.lowBelowBytes { return .low(free: free, canGo: scan.canGo) }
        return scan.canGo > 0 ? .ready(canGo: scan.canGo, free: free) : .nothingToClean(free: free)
    }
}
