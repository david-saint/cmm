import Foundation
@testable import CmmKit

/// The data the History boards draw, on the calendar they were drawn on: 2025, when 14 October was a Tuesday (the app's other
/// boards are dated 2026, where it is a Wednesday and the weeks fall differently). "Now" is the board's scan, Tuesday 14 October
/// 2025 at 14:21 in Berlin, and the weeks start on Monday as in a British calendar.
enum HistoryBoard {
    static let calendar = TestCalendars.make("Europe/Berlin")
    static let locale = Locale(identifier: "en_GB")
    static let now = at(10, 14, 14, 21)

    /// A moment of 2025, in Berlin.
    static func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.local(2025, month, day, hour, minute, second)
    }

    static func iso(_ date: Date) -> String { TestTime.iso(date) }

    static let host = #"{"volume":"/System/Volumes/Data","free_bytes":19800000000,"capacity_bytes":228000000000}"#

    // MARK: the cleanings of C-History, newest first

    static let dockerOnly = HistoryJSON.run(
        finished: iso(at(10, 14, 14, 20)), started: iso(at(10, 14, 14, 19, 30)), freed: 0, inside: gigabytes(9),
        before: gigabytes(19.8), deleted: 1,
        items: [HistoryJSON.item(
            rule: "docker", group: "Docker", path: "docker: unused images", bytes: gigabytes(9), freed: gigabytes(9),
            inside: "Docker's disk image"
        )]
    )

    static let lanes = HistoryJSON.run(
        finished: iso(at(10, 14, 14, 6)), started: iso(at(10, 14, 14, 5, 20)), freed: gigabytes(5.4),
        before: gigabytes(14.4), deleted: 4,
        items: [
            HistoryJSON.item(rule: "lane-deps", group: "Idle lane dependencies", path: "/Users/test/lane-builds/lane-a/node_modules", bytes: gigabytes(1.6)),
            HistoryJSON.item(rule: "lane-deps", group: "Idle lane dependencies", path: "/Users/test/lane-builds/lane-b/node_modules", bytes: gigabytes(1.0)),
            HistoryJSON.item(rule: "uv-cache", group: "uv cache", path: "/Users/test/.cache/uv", bytes: gigabytes(1.6)),
            HistoryJSON.item(rule: "go-build", group: "Go build cache", path: "/Users/test/Library/Caches/go-build", bytes: gigabytes(1.2)),
        ]
    )

    /// The run of the failed item: what went is Homebrew's and npm's; Go's build cache was refused.
    static let failed = HistoryJSON.run(
        finished: iso(at(10, 9, 9, 41)), started: iso(at(10, 9, 9, 40, 30)), freed: gigabytes(2.2),
        before: gigabytes(17.0), deleted: 2, failed: 1,
        items: [
            HistoryJSON.item(rule: "go-build", group: "Go build cache", path: "/Users/test/Library/Caches/go-build", status: "failed",
                             bytes: gigabytes(1.2), reason: "permission denied"),
            HistoryJSON.item(rule: "homebrew", group: "Homebrew old versions", path: "homebrew: cleanup", bytes: gigabytes(0.7)),
            HistoryJSON.item(rule: "npm-cache", group: "npm cache", path: "/Users/test/.npm/_cacache", bytes: gigabytes(0.3)),
        ]
    )

    static let firstCleaning = HistoryJSON.run(
        finished: iso(at(9, 29, 10, 2)), started: iso(at(9, 29, 9, 58)), freed: gigabytes(36.4), before: gigabytes(9.6),
        deleted: 7,
        items: [
            HistoryJSON.item(rule: "simulators", group: "Unavailable simulators", path: "/Users/test/Library/Developer/CoreSimulator/Devices/5B1E", bytes: gigabytes(14.2)),
            HistoryJSON.item(rule: "lane-deps", group: "Idle lane dependencies", path: "/Users/test/lane-builds/lane-c/node_modules", bytes: gigabytes(8.1)),
            // a rule the catalog does not know, named by its label as cmm gives it
            HistoryJSON.item(rule: "cli-versions", group: "Old CLI versions", path: "/Users/test/.local/share/claude/versions/1.0.2", bytes: gigabytes(5.0)),
            HistoryJSON.item(rule: "deriveddata-stale", group: "Stale Xcode build output", path: "/Users/test/Library/Developer/Xcode/DerivedData/App-a", bytes: gigabytes(3.9)),
            HistoryJSON.item(rule: "xcode-module-cache", group: "Xcode module cache", path: "/Users/test/Library/Developer/Xcode/DerivedData/ModuleCache.noindex", bytes: gigabytes(2.2)),
            HistoryJSON.item(rule: "cocoapods", group: "CocoaPods cache", path: "/Users/test/Library/Caches/CocoaPods", bytes: gigabytes(1.8)),
            HistoryJSON.item(rule: "bun-cache", group: "bun cache", path: "/Users/test/.bun/install/cache", bytes: gigabytes(1.2)),
        ]
    )

    static let runs = [dockerOnly, lanes, failed, firstCleaning]

    // MARK: the line of C-History

    /// The board's own line (the `ln` paths of `C-History`, in its 416 x 140 picture): 29 Sep to 3 Oct, 5 Oct to the
    /// cleaning of 9 Oct, and from there to the cleaning of 14 Oct. Read back into free space, it is the samples the board
    /// was drawn from.
    private static let boardPaths = [
        "30.0 17.6 31.6 18.3 33.2 19.1 34.8 19.8 36.3 20.7 37.9 21.7 39.5 22.9 41.1 23.4 42.7 23.7 44.3 23.9 45.9 23.8 47.4 23.6 49.0 23.5 50.6 23.4 52.2 23.4 53.8 23.7 55.4 24.6 57.0 25.6 58.6 26.6 60.1 27.5 61.7 28.2 63.3 28.7 64.9 29.2 66.5 29.2 68.1 29.2 69.7 29.4 71.2 29.7 72.8 30.2 74.4 30.6 76.0 31.0 77.6 31.3 79.2 31.3 80.8 31.9 82.3 32.4 83.9 32.9 85.5 33.6 87.1 34.4 88.7 35.3 90.3 36.4 91.9 36.8 93.5 37.1 95.0 37.3 96.6 37.4 98.2 37.4 99.8 37.4 101.4 37.3 103.0 37.4 104.6 37.6 106.1 38.7 107.7 39.8 109.3 40.9 110.9 42.0 112.5 42.9 114.1 43.6 115.7 44.2 117.2 44.1 118.8 44.1 120.4 44.1 122.0 44.2 123.6 44.3 125.2 44.5 126.8 44.7 128.4 44.9 129.4 45.0",
        "181.2 58.9 182.3 59.4 183.9 60.0 185.5 60.6 187.0 61.1 188.6 61.6 190.2 62.2 191.8 63.0 193.4 63.3 195.0 63.7 196.6 64.0 198.2 64.2 199.7 64.3 201.3 64.2 202.9 64.0 204.5 64.0 206.1 64.0 207.7 64.6 209.3 65.4 210.8 66.4 212.4 67.3 214.0 68.1 215.6 68.8 217.2 69.3 218.8 69.2 220.4 69.2 221.9 69.1 223.5 69.2 225.1 69.3 226.7 69.6 228.3 69.9 229.9 70.3 231.5 70.5 233.1 71.1 234.6 71.7 236.2 72.4 237.8 73.1 238.3 73.0 239.4 73.9 241.0 74.6 242.6 75.6 244.2 76.0 245.7 76.3 247.3 76.7 248.9 76.9 250.5 77.0 252.1 77.0 253.7 77.0 255.3 77.0 256.8 77.2 258.4 78.2 260.0 79.4 261.6 80.7 263.2 81.9 264.8 83.0 266.4 83.9 268.0 84.7 269.5 84.7 271.1 84.8 272.7 84.9 274.3 85.1 275.9 85.4 277.5 85.7 279.1 86.0 280.6 86.3 282.2 86.5 283.5 87.2",
        "283.5 81.9 283.8 82.0 285.4 82.2 287.0 82.5 288.6 82.8 290.2 83.2 291.7 83.6 293.3 84.1 294.9 84.4 296.5 84.5 298.1 84.4 299.7 84.2 301.3 84.0 302.8 83.8 304.4 83.7 306.0 83.6 307.6 83.6 309.2 83.9 310.8 84.3 312.4 84.7 314.0 85.1 315.5 85.5 317.1 85.7 318.7 85.8 320.3 85.6 321.9 85.5 323.5 85.3 325.1 85.3 326.6 85.5 328.2 85.7 329.8 86.1 331.4 86.3 333.0 86.5 334.6 86.8 336.2 86.8 337.7 86.8 339.3 86.8 340.9 86.8 342.5 87.0 344.1 87.3 345.7 87.6 347.3 88.0 348.9 88.3 350.4 88.5 352.0 88.5 353.6 88.4 355.2 88.2 356.8 88.0 358.4 88.0 360.0 88.4 361.5 88.9 363.1 89.6 364.7 90.1 366.3 90.5 367.9 90.6 369.5 90.6 371.1 90.4 372.6 90.1 374.2 89.9 375.8 89.8 377.4 89.8 379.0 89.9 380.6 90.1 382.2 90.4 383.8 90.6 385.3 91.0 386.9 91.2 388.5 91.3 390.1 91.4 391.7 91.5 393.3 91.6 394.9 91.9 396.4 92.0 398.0 92.1 399.6 92.2 401.2 92.4 402.8 92.5 404.4 92.5 406.0 92.5 407.5 92.5 409.1 92.5 410.7 92.7 412.3 93.0 413.9 93.2 415.0 93.4",
    ]

    /// The board's picture runs from the first reading (29 Sep, 09:58) at x = 30 to now at x = 416, with 2.4 pt to the gigabyte
    /// above the zero line at y = 128.
    private static func free(atX x: Double, on path: [(x: Double, y: Double)]) -> Double {
        guard let after = path.firstIndex(where: { $0.x >= x }) else { return (128 - path[path.count - 1].y) / 2.4 }
        guard after > 0 else { return (128 - path[0].y) / 2.4 }
        let (a, b) = (path[after - 1], path[after])
        let y = a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, 0.001)
        return (128 - y) / 2.4
    }

    /// A note every hour along the board's line, the two ends of every cleaning, and the hour of the board's read-out (Tue 7 Oct,
    /// 15:00: 22.9 GB, which is also the note nearest to a week ago, 3.1 GB above the 19.8 GB free now).
    static var samples: [String] {
        let start = at(9, 29, 9, 58)
        let span = now.timeIntervalSince(start)
        func x(_ date: Date) -> Double { 30 + date.timeIntervalSince(start) / span * 386 }
        let paths = boardPaths.map { text -> [(x: Double, y: Double)] in
            let numbers = text.split(separator: " ").compactMap { Double($0) }
            return stride(from: 0, to: numbers.count - 1, by: 2).map { (numbers[$0], numbers[$0 + 1]) }
        }
        var notes: [(Date, Double)] = [
            (start, 9.6), (at(9, 29, 10, 2), 46.0),
            (at(10, 9, 9, 40, 30), 17.0), (at(10, 9, 9, 41), 19.2),
            (at(10, 14, 14, 5, 20), 14.4), (at(10, 14, 14, 6), 19.8),
            (at(10, 14, 14, 19, 30), 19.8), (at(10, 14, 14, 20), 19.8),
        ]
        let stretches = [
            (at(9, 29, 11, 0), at(10, 3, 7, 0), paths[0]),
            (at(10, 5, 9, 0), at(10, 9, 9, 0), paths[1]),
            (at(10, 9, 10, 0), at(10, 14, 14, 0), paths[2]),
        ]
        for (first, last, path) in stretches {
            var hour = first
            while hour <= last {
                let reading = calendar.isDate(hour, equalTo: at(10, 7, 14, 0), toGranularity: .minute)
                    || calendar.isDate(hour, equalTo: at(10, 7, 15, 0), toGranularity: .minute)
                notes.append((hour, reading ? 22.9 : (free(atX: x(hour), on: path) * 100).rounded() / 100))
                hour = hour.addingTimeInterval(3_600)
            }
        }
        return notes.sorted { $0.0 < $1.0 }.map { HistoryJSON.sample(iso($0.0), free: gigabytes($0.1), capacity: 228_000_000_000) }
    }

    /// C-History: the four cleanings and the line, with 19.8 GB free now (or another report made the same way).
    static func report(
        runs: [String] = runs, samples: [String]? = nil, now: Date = now, freeNow: Double = 19.8, unreadable: Int = 0
    ) throws -> HistoryReport {
        var json = HistoryJSON()
        json.generatedAt = iso(now)
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":\#(gigabytes(freeNow)),"capacity_bytes":228000000000}"#
        json.runs = runs
        json.samples = samples ?? Self.samples
        json.unreadable = unreadable
        return try json.report()
    }

    /// A note every hour from `first` to `last`, the `index`-th one `free(index)` gigabytes.
    static func hourly(from first: Date, to last: Date, _ free: (Int) -> Double) -> [String] {
        var notes: [String] = []
        var hour = first
        var index = 0
        while hour <= last {
            notes.append(HistoryJSON.sample(iso(hour), free: gigabytes(free(index))))
            hour = hour.addingTimeInterval(3_600)
            index += 1
        }
        return notes
    }

    // MARK: the panels of C-History-States

    /// Panel 2: two and a bit days of notes, from Sunday 12 Oct at 08:00, and the one cleaning of 14 Oct.
    static var fewSamples: [String] {
        hourly(from: at(10, 12, 8, 0), to: at(10, 14, 14, 0)) { 16.7 - Double($0) * 0.04 } + [
            HistoryJSON.sample(iso(at(10, 14, 14, 5, 20)), free: gigabytes(14.4)),
            HistoryJSON.sample(iso(at(10, 14, 14, 6)), free: gigabytes(19.8)),
        ]
    }

    /// Panel 3: 1 to 7 Oct, nothing from Friday 3 to Sunday 5, and no cleaning; it is Tuesday 7 Oct, 22:00.
    static let gapNow = at(10, 7, 22, 0)
    static var gapSamples: [String] {
        hourly(from: at(10, 1, 0, 30), to: at(10, 3, 8, 0)) { 41 - Double($0) * 0.1 }
            + hourly(from: at(10, 5, 8, 40), to: at(10, 7, 21, 0)) { 29 - Double($0) * 0.14 }
    }

    /// Panel 5: Stop was pressed after two of nine items, on Saturday 11 Oct.
    static let stopped = HistoryJSON.run(
        finished: iso(at(10, 11, 16, 40)), started: iso(at(10, 11, 16, 38)), freed: gigabytes(2.3), before: gigabytes(17.5),
        deleted: 2, stopped: true, planned: 9,
        items: [
            HistoryJSON.item(rule: "lane-deps", group: "Idle lane dependencies", path: "/Users/test/lane-builds/lane-a/node_modules", bytes: gigabytes(1.4)),
            HistoryJSON.item(rule: "lane-deps", group: "Idle lane dependencies", path: "/Users/test/lane-builds/lane-a/ios/Pods", bytes: gigabytes(0.9)),
        ]
    )

    /// The id the report gives a run that ended at this moment (the second it ended).
    static func runID(_ finished: Date) -> String { "\(Int64(finished.timeIntervalSince1970))" }
}
