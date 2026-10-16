import Foundation

// The history is what `cmm history --json` prints (schema 1): the cleanups cmm has done, newest first, and the free-space
// timeline, oldest first. These types are read-only mirrors of it, and they are tolerant on purpose: the history is
// metadata that only decides what is drawn, so a line the app cannot use is left out and counted, never fatal. What can
// stop a report is its shape (not JSON, not an object, the lists not lists) and a schema this app does not read.

/// What the app will believe about a number. cmm's own files are checked when cmm reads them, but a history can be edited
/// by hand and a cmm of another version can say anything, so no size or count that a disk could not hold gets past here.
/// Everything after this point can add sizes up without a guard against overflow.
enum HistoryLimits {
    /// A petabyte: more than any disk of a Mac holds, and far from the end of an `Int64`.
    static let maxBytes: Int64 = 1_000_000_000_000_000
    static let maxCount = 1_000_000

    static func isSize(_ value: Int64) -> Bool { value >= 0 && value <= maxBytes }
    static func isCount(_ value: Int) -> Bool { value >= 0 && value <= maxCount }
}

/// The times of the history: UTC to the second as cmm writes them, read with fractions and offsets too.
enum HistoryTime {
    static func parse(_ text: String) -> Date? {
        try? Date.ISO8601FormatStyle().parse(text)
    }
}

/// One reading of the volume's free space: a note taken by `cmm sample`, or one of the two ends of a cleanup.
public struct FreeSample: Equatable, Sendable {
    public let t: Date
    public let freeBytes: Int64
    public let capacityBytes: Int64?
}

/// One item of a cleanup that was deleted or failed. Skipped items change nothing and are only counted.
public struct HistoryItem: Equatable, Sendable {
    public let rule: String
    public let group: String
    /// A file path, or for a command the label cmm gave it ("docker: unused images").
    public let path: String
    public let status: ItemStatus
    public let bytes: Int64
    public let freedBytes: Int64
    /// Where the space went when it was not the volume ("Docker's disk image"); nil when the volume got it.
    public let freesInside: String?
    /// Why it failed.
    public let reason: String?
}

/// One cleanup (one real `cmm apply` that deleted or failed something).
public struct HistoryRun: Equatable, Sendable, Identifiable {
    /// Tells the runs of a report apart, and a marker of the timeline from the run's row: the second the run ended, with a
    /// number after it for runs that ended in the same second (which only a hand-edited history has).
    public internal(set) var id: String
    public let startedAt: Date?
    public let finishedAt: Date
    public let deleted: Int
    public let skipped: Int
    public let failed: Int
    /// What the volume got back. Space freed inside another program's storage is never in it.
    public let freedBytes: Int64
    /// What was freed inside another program's storage (today Docker's disk image). Never part of any total.
    public let freedInsideBytes: Int64
    public let freeBefore: Int64
    public let freeAfter: Int64
    public let capacityBytes: Int64?
    public let stopped: Bool
    public let items: [HistoryItem]
    /// How many items did not fit in the line cmm wrote and are only counted in the totals.
    public let itemsOmitted: Int
}

/// The volume now. cmm writes an empty volume and 0 free bytes when it cannot read the free space; that is "unknown",
/// not an empty disk.
public struct HistoryHost: Equatable, Sendable {
    public let volume: String
    public let freeBytes: Int64?
    public let capacityBytes: Int64?
}

public struct HistoryReport: Equatable, Sendable {
    /// The one history schema this app reads.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    /// When cmm made the report (and read the host). Informational: an unreadable timestamp is dropped.
    public let generatedAt: Date?
    public let host: HistoryHost
    /// Newest first, as cmm sends them (the app sorts again where it matters).
    public let runs: [HistoryRun]
    /// Oldest first, as cmm sends them. Includes the two ends of every cleanup.
    public let samples: [FreeSample]
    /// Lines of cmm's history files that cmm could not read and left out.
    public let unreadableLines: Int
    /// Runs and samples in the document that this app could not use (a bad time, a negative size, a size no disk has).
    public let ignoredEntries: Int

    /// Decodes the output of `cmm history --json`. Every failure is a `CmmError` the app can show.
    static func parse(_ data: Data) throws -> HistoryReport {
        do {
            return try JSONDecoder().decode(HistoryReport.self, from: data)
        } catch let error as CmmError {
            throw error
        } catch let error as DecodingError {
            throw CmmError.malformedHistory(error.cmmDescription(subject: "the history"))
        } catch {
            throw CmmError.malformedHistory(error.localizedDescription)
        }
    }
}

// MARK: as of a moment

extension HistoryReport {
    /// The report as it can be believed at `now`: nothing that claims to have happened later (a clock that was wrong, or a
    /// hand-edited history), the samples oldest first and the runs newest first whatever order they came in. What was left
    /// out is added to `ignoredEntries`. Asking again of the result changes nothing.
    func asOf(_ now: Date) -> HistoryReport {
        let samples = self.samples.enumerated().filter { $0.element.t <= now }
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        let runs = self.runs.enumerated().filter { $0.element.finishedAt <= now }
            .sorted { ($1.element.finishedAt, $0.offset) < ($0.element.finishedAt, $1.offset) }.map(\.element)
        return HistoryReport(
            schemaVersion: schemaVersion, generatedAt: generatedAt, host: host, runs: runs, samples: samples,
            unreadableLines: unreadableLines,
            ignoredEntries: ignoredEntries + (self.samples.count - samples.count) + (self.runs.count - runs.count)
        )
    }
}

// MARK: decoding

extension HistoryReport: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case host, runs, samples
        case unreadableLines = "unreadable_lines"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // The version comes first and alone: a document of another schema may have another shape, and the person should be
        // told "this app reads schema 1", not shown an unrelated decoding error.
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.supportedSchemaVersion else { throw CmmError.unsupportedHistorySchema(found: version) }

        let runs = try c.decodeLossy(HistoryRun.self, forKey: .runs)
        let samples = try c.decodeLossy(FreeSample.self, forKey: .samples)
        let unreadable = (try? c.decodeIfPresent(Int.self, forKey: .unreadableLines)).flatMap { $0 } ?? 0

        self.init(
            schemaVersion: version,
            generatedAt: (try? c.decodeIfPresent(String.self, forKey: .generatedAt)).flatMap { $0 }.flatMap(HistoryTime.parse),
            host: try c.decodeIfPresent(RawHost.self, forKey: .host)?.host ?? HistoryHost(volume: "", freeBytes: nil, capacityBytes: nil),
            runs: Self.identified(runs.kept),
            samples: samples.kept,
            unreadableLines: min(max(unreadable, 0), HistoryLimits.maxCount),
            ignoredEntries: runs.dropped + samples.dropped
        )
    }

    /// Gives every run the id its marker and its row share.
    private static func identified(_ runs: [HistoryRun]) -> [HistoryRun] {
        var seen: [Int64: Int] = [:]
        return runs.map { run in
            var run = run
            let second = Int64(run.finishedAt.timeIntervalSince1970.rounded(.down))
            let number = (seen[second] ?? 0) + 1
            seen[second] = number
            run.id = number == 1 ? "\(second)" : "\(second)-\(number)"
            return run
        }
    }
}

/// The host as cmm writes it; what is wrong with it makes the free space unknown, not the report unreadable.
private struct RawHost: Decodable {
    private enum CodingKeys: String, CodingKey {
        case volume
        case freeBytes = "free_bytes"
        case capacityBytes = "capacity_bytes"
    }

    let host: HistoryHost

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let volume = (try? c.decodeIfPresent(String.self, forKey: .volume)).flatMap { $0 } ?? ""
        let free = (try? c.decodeIfPresent(Int64.self, forKey: .freeBytes)).flatMap { $0 }
        host = HistoryHost(
            volume: volume,
            // cmm writes an empty volume and 0 when it could not read the free space
            freeBytes: volume.isEmpty ? nil : free.flatMap { HistoryLimits.isSize($0) ? $0 : nil },
            capacityBytes: (try? c.decodeIfPresent(Int64.self, forKey: .capacityBytes)).flatMap { $0 }.flatMap(Self.capacity)
        )
    }

    /// A disk of no size, or of a size no disk has, is a disk of unknown size.
    static func capacity(_ value: Int64) -> Int64? {
        value > 0 && HistoryLimits.isSize(value) ? value : nil
    }
}

extension FreeSample: Decodable {
    private enum CodingKeys: String, CodingKey {
        case t
        case freeBytes = "free_bytes"
        case capacityBytes = "capacity_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let t = HistoryTime.parse(try c.decode(String.self, forKey: .t)) else {
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "not a time")
        }
        let free = try c.decode(Int64.self, forKey: .freeBytes)
        guard HistoryLimits.isSize(free) else {
            throw DecodingError.dataCorruptedError(forKey: .freeBytes, in: c, debugDescription: "not a size a disk has")
        }
        self.init(
            t: t, freeBytes: free,
            capacityBytes: (try? c.decodeIfPresent(Int64.self, forKey: .capacityBytes)).flatMap { $0 }.flatMap(RawHost.capacity)
        )
    }
}

extension HistoryItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rule, group, path, status, bytes, reason
        case freedBytes = "freed_bytes"
        case freesInside = "frees_inside"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An item is only what one row of a cleanup shows, so a size it cannot have is zero rather than a refusal.
        func size(_ key: CodingKeys) -> Int64 {
            let value = (try? c.decodeIfPresent(Int64.self, forKey: key)).flatMap { $0 } ?? 0
            return HistoryLimits.isSize(value) ? value : 0
        }
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            rule: text(.rule) ?? "", group: text(.group) ?? "",
            path: try c.decode(String.self, forKey: .path),
            status: try c.decode(ItemStatus.self, forKey: .status),
            bytes: size(.bytes), freedBytes: size(.freedBytes), freesInside: text(.freesInside), reason: text(.reason)
        )
    }
}

extension HistoryRun: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case deleted, skipped, failed, stopped, items
        case freedBytes = "freed_bytes"
        case freedInsideBytes = "freed_inside_bytes"
        case freeBefore = "free_before"
        case freeAfter = "free_after"
        case capacityBytes = "capacity_bytes"
        case itemsOmitted = "items_omitted"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func refuse(_ key: CodingKeys, _ why: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: why)
        }
        func size(_ key: CodingKeys, optional: Bool = false) throws -> Int64 {
            let value = optional ? try c.decodeIfPresent(Int64.self, forKey: key) ?? 0 : try c.decode(Int64.self, forKey: key)
            guard HistoryLimits.isSize(value) else { throw refuse(key, "not a size a disk has") }
            return value
        }
        func count(_ key: CodingKeys, optional: Bool = false) throws -> Int {
            let value = optional ? try c.decodeIfPresent(Int.self, forKey: key) ?? 0 : try c.decode(Int.self, forKey: key)
            guard HistoryLimits.isCount(value) else { throw refuse(key, "not a count a cleanup has") }
            return value
        }

        // A run of another schema is not read, whatever it looks like.
        guard try c.decode(Int.self, forKey: .schemaVersion) == HistoryReport.supportedSchemaVersion else {
            throw refuse(.schemaVersion, "a run of another schema")
        }
        guard let finishedAt = HistoryTime.parse(try c.decode(String.self, forKey: .finishedAt)) else {
            throw refuse(.finishedAt, "not a time")
        }
        let items = try c.decodeLossy(HistoryItem.self, forKey: .items)

        self.init(
            id: "",
            startedAt: (try? c.decodeIfPresent(String.self, forKey: .startedAt)).flatMap { $0 }.flatMap(HistoryTime.parse),
            finishedAt: finishedAt,
            deleted: try count(.deleted), skipped: try count(.skipped), failed: try count(.failed),
            freedBytes: try size(.freedBytes), freedInsideBytes: try size(.freedInsideBytes, optional: true),
            freeBefore: try size(.freeBefore), freeAfter: try size(.freeAfter),
            capacityBytes: (try? c.decodeIfPresent(Int64.self, forKey: .capacityBytes)).flatMap { $0 }.flatMap(RawHost.capacity),
            stopped: (try? c.decodeIfPresent(Bool.self, forKey: .stopped)).flatMap { $0 } ?? false,
            items: items.kept,
            itemsOmitted: try count(.itemsOmitted, optional: true)
        )
    }
}

// MARK: a list that survives a bad element

/// Stands in for an element that could not be decoded, so the list's cursor moves past it.
private struct Discard: Decodable {}

extension KeyedDecodingContainer {
    /// The elements of a list that can be decoded, and how many could not. A list that is missing is an empty one; a
    /// value that is not a list at all is an error, because then the shape is wrong.
    fileprivate func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> (kept: [T], dropped: Int) {
        guard contains(key), try !decodeNil(forKey: key) else { return ([], 0) }
        var list = try nestedUnkeyedContainer(forKey: key)
        var kept: [T] = []
        var dropped = 0
        while !list.isAtEnd {
            if let element = try? list.decode(T.self) {
                kept.append(element)
            } else {
                dropped += 1
                _ = try? list.decode(Discard.self)
            }
        }
        return (kept, dropped)
    }
}

// MARK: cmm sample

/// What `cmm sample --json` prints: whether a note was added, and the free space it read.
public struct SampleResult: Equatable, Sendable {
    public let recorded: Bool
    public let t: Date?
    public let freeBytes: Int64
    public let capacityBytes: Int64?

    /// Decodes the one line `cmm sample --json` prints. Every failure is a `CmmError` the app can show.
    static func parse(_ data: Data) throws -> SampleResult {
        do {
            return try JSONDecoder().decode(SampleResult.self, from: data)
        } catch let error as DecodingError {
            throw CmmError.malformedSample(error.cmmDescription(subject: "cmm's note"))
        } catch {
            throw CmmError.malformedSample(error.localizedDescription)
        }
    }
}

extension SampleResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case recorded, t
        case freeBytes = "free_bytes"
        case capacityBytes = "capacity_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let free = try c.decode(Int64.self, forKey: .freeBytes)
        guard HistoryLimits.isSize(free) else {
            throw DecodingError.dataCorruptedError(forKey: .freeBytes, in: c, debugDescription: "not a size a disk has")
        }
        self.init(
            recorded: try c.decode(Bool.self, forKey: .recorded),
            t: (try? c.decodeIfPresent(String.self, forKey: .t)).flatMap { $0 }.flatMap(HistoryTime.parse),
            freeBytes: free,
            capacityBytes: (try? c.decodeIfPresent(Int64.self, forKey: .capacityBytes)).flatMap { $0 }.flatMap(RawHost.capacity)
        )
    }
}
