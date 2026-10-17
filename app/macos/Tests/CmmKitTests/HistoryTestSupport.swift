import Foundation
import XCTest
@testable import CmmKit

/// Times for the history tests: written the way cmm writes them, read in UTC.
enum TestTime {
    /// `2026-10-15T09:00:00Z`, optionally plus days, hours and seconds (so a test can count from a moment it names).
    static func utc(_ text: String, plusDays days: Double = 0, hours: Double = 0, seconds: Double = 0) -> Date {
        guard let date = try? Date.ISO8601FormatStyle().parse(text) else { fatalError("not a time: \(text)") }
        return date.addingTimeInterval(days * 86_400 + hours * 3_600 + seconds)
    }

    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}

/// Decimal gigabytes, the way the app writes them.
func gigabytes(_ value: Double) -> Int64 {
    Int64((value * 1_000_000_000).rounded())
}

/// Calendars with a time zone and the first weekday written down, so a test does not depend on the machine's region.
enum TestCalendars {
    static func make(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")  // first: giving a calendar a locale resets what was set before it
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static let rome = make("Europe/Rome")
    static let utc = make("UTC")
}

extension Calendar {
    /// A moment written as local wall-clock time in this calendar's zone.
    func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        guard let date = self.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )) else { fatalError("no such moment") }
        return date
    }
}

/// A history report written as JSON, so the tests build their input the way cmm hands it over.
struct HistoryJSON {
    var host: String = #"{"volume":"/System/Volumes/Data","free_bytes":24000000000,"capacity_bytes":245107195904}"#
    var generatedAt = "2026-10-15T09:00:00Z"
    var runs: [String] = []
    var samples: [String] = []
    var unreadable = 0
    var schema = 1

    static func sample(_ t: String, free: Int64, capacity: Int64? = 245_107_195_904) -> String {
        var fields = #""t":"\#(t)","free_bytes":\#(free)"#
        if let capacity { fields += #","capacity_bytes":\#(capacity)"# }
        return "{\(fields)}"
    }

    static func run(
        finished: String, started: String? = nil, freed: Int64 = 1_000_000_000, inside: Int64 = 0,
        before: Int64 = 20_000_000_000, after: Int64? = nil, deleted: Int = 1, skipped: Int = 0, failed: Int = 0,
        stopped: Bool = false, planned: Int? = nil, items: [String] = [], schema: Int = 1, extra: String = ""
    ) -> String {
        var fields = [
            #""schema_version":\#(schema)"#,
            #""started_at":"\#(started ?? finished)""#,
            #""finished_at":"\#(finished)""#,
            #""deleted":\#(deleted)"#, #""skipped":\#(skipped)"#, #""failed":\#(failed)"#,
            #""freed_bytes":\#(freed)"#,
            #""free_before":\#(before)"#, #""free_after":\#(after ?? (before &+ freed))"#,
            #""stopped":\#(stopped)"#,
            #""items":[\#(items.joined(separator: ","))]"#,
        ]
        if inside != 0 { fields.append(#""freed_inside_bytes":\#(inside)"#) }
        if let planned { fields.append(#""planned":\#(planned)"#) }
        if !extra.isEmpty { fields.append(extra) }
        return "{\(fields.joined(separator: ","))}"
    }

    static func item(
        rule: String = "go-build", group: String = "Go build cache", path: String = "/Users/test/Library/Caches/go-build",
        status: String = "deleted", bytes: Int64 = 1_000_000_000, freed: Int64? = nil, inside: String? = nil,
        reason: String? = nil
    ) -> String {
        var fields = [
            #""rule":"\#(rule)""#, #""group":"\#(group)""#, #""path":"\#(path)""#, #""status":"\#(status)""#,
            #""bytes":\#(bytes)"#, #""freed_bytes":\#(freed ?? (status == "deleted" ? bytes : 0))"#,
        ]
        if let inside { fields.append(#""frees_inside":"\#(inside)""#) }
        if let reason { fields.append(#""reason":"\#(reason)""#) }
        return "{\(fields.joined(separator: ","))}"
    }

    var text: String {
        """
        {"schema_version":\(schema),"generated_at":"\(generatedAt)","host":\(host),
         "runs":[\(runs.joined(separator: ","))],"samples":[\(samples.joined(separator: ","))],"unreadable_lines":\(unreadable)}
        """
    }

    var data: Data { Data(text.utf8) }

    func report() throws -> HistoryReport {
        try HistoryReport.parse(data)
    }
}
