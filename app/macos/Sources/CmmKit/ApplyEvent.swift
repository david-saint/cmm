import Foundation

// The NDJSON events of `cmm apply --yes --json --select-file FILE`, one JSON object per line:
//
//   start  -> item (one per selected path) ... -> done
//
// Fields the app does not need are ignored. Fields it does need are required: an event that lacks them is
// reported as unreadable rather than filled with zeros, because a made-up summary would be worse than none.

/// What happened to one item.
public enum ItemStatus: Hashable, Sendable {
    case deleted
    case skipped
    case failed
    /// Only in a dry run, which this app never starts.
    case dryRun
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "deleted": self = .deleted
        case "skipped": self = .skipped
        case "failed": self = .failed
        case "dry-run": self = .dryRun
        default: self = .other(rawValue)
        }
    }
}

extension ItemStatus: Decodable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// The first event: how much cmm is about to work on.
public struct StartEvent: Equatable, Sendable {
    /// Paths in the selection file.
    public let selected: Int
    /// Selected paths that are in cmm's fresh plan.
    public let matched: Int
    public let bytes: Int64
    public let freeBytes: Int64
}

extension StartEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case selected, matched, bytes
        case freeBytes = "free_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selected: try c.decode(Int.self, forKey: .selected),
            matched: try c.decode(Int.self, forKey: .matched),
            bytes: try c.decode(Int64.self, forKey: .bytes),
            freeBytes: try c.decode(Int64.self, forKey: .freeBytes)
        )
    }
}

/// One item has been dealt with.
public struct ItemEvent: Equatable, Sendable, Identifiable {
    public let rule: String
    public let group: String
    public let path: String
    public let status: ItemStatus
    /// Why it was skipped or failed; empty when it was deleted.
    public let reason: String
    public let bytes: Int64
    public let freedBytes: Int64
    /// Where the space went when it was not the volume ("Docker's disk image"); the item's `freedBytes` are then not
    /// part of `done.freedBytes`. Nil when the volume got the space.
    public let freesInside: String?

    public var id: String { path }

    init(
        rule: String, group: String, path: String, status: ItemStatus, reason: String, bytes: Int64, freedBytes: Int64,
        freesInside: String? = nil
    ) {
        self.rule = rule
        self.group = group
        self.path = path
        self.status = status
        self.reason = reason
        self.bytes = bytes
        self.freedBytes = freedBytes
        self.freesInside = freesInside
    }
}

extension ItemEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rule, group, path, status, reason, bytes
        case freedBytes = "freed_bytes"
        case freesInside = "frees_inside"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rule: try c.decodeIfPresent(String.self, forKey: .rule) ?? "",
            group: try c.decodeIfPresent(String.self, forKey: .group) ?? "",
            path: try c.decode(String.self, forKey: .path),
            status: try c.decode(ItemStatus.self, forKey: .status),
            reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
            bytes: try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0,
            freedBytes: try c.decodeIfPresent(Int64.self, forKey: .freedBytes) ?? 0,
            freesInside: (try? c.decodeIfPresent(String.self, forKey: .freesInside)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// The last event: what the cleanup really did.
public struct DoneEvent: Equatable, Sendable {
    public let deleted: Int
    public let skipped: Int
    public let failed: Int
    /// What the volume got back. Space freed inside another program's own storage (Docker's disk image) is not in it.
    public let freedBytes: Int64
    /// What was freed inside another program's own storage: the disk shows it later, or not at all. Zero when absent.
    public let freedInsideBytes: Int64
    public let freeBefore: Int64
    public let freeAfter: Int64
    /// True when the person stopped the cleanup before every item was dealt with.
    public let stopped: Bool
    /// Problems with the log or the stamp; never failures of the cleanup itself.
    public let warnings: [String]
    /// Where the record of this cleanup is; present only when something was logged.
    public let log: String?

    init(
        deleted: Int, skipped: Int, failed: Int, freedBytes: Int64, freedInsideBytes: Int64 = 0, freeBefore: Int64,
        freeAfter: Int64, stopped: Bool, warnings: [String], log: String?
    ) {
        self.deleted = deleted
        self.skipped = skipped
        self.failed = failed
        self.freedBytes = freedBytes
        self.freedInsideBytes = freedInsideBytes
        self.freeBefore = freeBefore
        self.freeAfter = freeAfter
        self.stopped = stopped
        self.warnings = warnings
        self.log = log
    }
}

extension DoneEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case deleted, skipped, failed, stopped, warnings, log
        case freedBytes = "freed_bytes"
        case freedInsideBytes = "freed_inside_bytes"
        case freeBefore = "free_before"
        case freeAfter = "free_after"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deleted: try c.decode(Int.self, forKey: .deleted),
            skipped: try c.decode(Int.self, forKey: .skipped),
            failed: try c.decode(Int.self, forKey: .failed),
            freedBytes: try c.decode(Int64.self, forKey: .freedBytes),
            freedInsideBytes: try c.decodeIfPresent(Int64.self, forKey: .freedInsideBytes) ?? 0,
            freeBefore: try c.decode(Int64.self, forKey: .freeBefore),
            freeAfter: try c.decode(Int64.self, forKey: .freeAfter),
            stopped: try c.decode(Bool.self, forKey: .stopped),
            warnings: try c.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            log: try c.decodeIfPresent(String.self, forKey: .log)
        )
    }
}

/// What the process client reports while a cleanup runs.
public enum ApplyEvent: Equatable, Sendable {
    case start(StartEvent)
    case item(ItemEvent)
    case done(DoneEvent)
    /// A line cmm printed that could not be understood (the beginning of it, for diagnosis). The cleanup itself is
    /// not affected; the app counts these and says so at the end.
    case unreadable(String)

    private struct Head: Decodable {
        let event: String
    }

    /// Decodes one line. Returns nil for an event kind this app does not know (so newer cmm versions can add
    /// events); throws when the line is not a well-formed event.
    static func decode(line: Data) throws -> ApplyEvent? {
        let decoder = JSONDecoder()
        switch try decoder.decode(Head.self, from: line).event {
        case "start": return .start(try decoder.decode(StartEvent.self, from: line))
        case "item": return .item(try decoder.decode(ItemEvent.self, from: line))
        case "done": return .done(try decoder.decode(DoneEvent.self, from: line))
        default: return nil
        }
    }
}
