import XCTest
@testable import CmmKit

/// Spec R10: what the new background behaviours can and cannot do, pinned the way the first milestone's safety rules are.
///
/// The History face, the menu bar item, the weekly reminder, the free-space sampler, the settings and the one-time card can
/// only look and say. Nothing in their files can clean, delete, start a program or reach a file, none of them is a second way to
/// start cmm, and what they say is made of numbers and plain words. Part of this file reads the app's own source and is blunt on
/// purpose: when a check trips, read the rule, then change the check together with a reason.
@MainActor
final class BackgroundSafetyTests: XCTestCase {
    // MARK: reading the app's source

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CmmKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app/macos

    private struct SourceFile {
        let name: String
        let raw: String  // as written, comments and all
        let code: String  // without `//` comments
    }

    private func sources(of targets: [String] = ["CmmKit", "Cmm"]) throws -> [SourceFile] {
        var all: [SourceFile] = []
        for target in targets {
            let folder = Self.packageRoot.appendingPathComponent("Sources/\(target)")
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            XCTAssertFalse(urls.isEmpty, "no sources found in \(folder.path): these checks would pass for the wrong reason")
            for url in urls {
                let text = try String(contentsOf: url, encoding: .utf8)
                all.append(SourceFile(name: url.lastPathComponent, raw: text, code: Self.strippingComments(text)))
            }
        }
        return all
    }

    /// Drops `// ...` comments (not inside string literals), so a check can look at the code alone.
    private static func strippingComments(_ text: String) -> String {
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var inString = false
            var previous: Character = " "
            for character in line {
                if character == "\"", previous != "\\" { inString.toggle() }
                if !inString, character == "/", previous == "/" {
                    kept.removeLast()
                    break
                }
                kept.append(character)
                previous = character
            }
            out += kept + "\n"
        }
        return out
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
    }

    /// The files of the new behaviours, by the first word of their names (spec R10). The one-time card's file, `OptIn...`, comes
    /// with the card; the scan is already waiting for it.
    private static let prefixes = ["History", "MenuBar", "Notification", "Sampler", "Settings", "OptIn", "Weekly"]

    private func newBehaviourFiles() throws -> [SourceFile] {
        try sources().filter { file in Self.prefixes.contains { file.name.hasPrefix($0) } }
    }

    // MARK: they cannot clean, delete, start anything or reach a file

    func testTheFilesOfTheNewBehavioursNeverMentionCleaningDeletingOrLaunching() throws {
        let files = try newBehaviourFiles()
        let names = Set(files.map(\.name))
        for known in [
            "HistoryReport.swift", "HistoryTimeline.swift", "HistoryRunRows.swift", "MenuBarState.swift", "MenuBarContext.swift",
            "MenuBarPresentation.swift", "NotificationContent.swift", "NotificationPermission.swift", "SamplerSchedule.swift",
            "Settings.swift", "SettingsLoginItem.swift", "WeeklyPlanner.swift", "WeeklyReminder.swift",
        ] {
            XCTAssertTrue(names.contains(known), "\(known) is among the files these checks read")
        }
        let unmatched = Self.prefixes.filter { prefix in !files.contains { $0.name.hasPrefix(prefix) } }
        XCTAssertTrue(unmatched.allSatisfy { $0 == "OptIn" }, "a prefix that matches no file reads nothing: \(unmatched)")

        // Spec R10's six words, in the files as written (a comment that names one is rewritten, not excused).
        for token in ["confirmClean", "apply", "removeItem", "trashItem", "Process(", "NSWorkspace"] {
            XCTAssertEqual(files.filter { $0.raw.contains(token) }.map(\.name), [], "`\(token)` appears")
        }
        // And what would be a second way to clean, to start cmm, to touch a file or to send something away.
        for token in [
            "requestClean", "cancelClean", "ChildProcess", "ProcessCmmClient", "SelectionFile", "FileManager", "NSTask",
            "posix_spawn", "URLSession", "URLRequest", "NWConnection", "NSAppleScript",
        ] {
            XCTAssertEqual(files.filter { $0.code.contains(token) }.map(\.name), [], "`\(token)` appears in code")
        }
    }

    func testOnlyTheSamplerAndTheHistoryModelTakeTheClientAndEachCallsOneThingOnIt() throws {
        // Nothing else of the new files holds a client at all.
        let files = try newBehaviourFiles()
        let calls = [
            "SamplerSchedule.swift": "{ try await client.sample() }",
            "HistoryModel.swift": "{ try await client.history() }",
        ]
        XCTAssertEqual(Set(files.filter { $0.code.contains("CmmClient") }.map(\.name)), Set(calls.keys))
        for (name, call) in calls {
            let code = try XCTUnwrap(files.first { $0.name == name }).code
            XCTAssertEqual(code.components(separatedBy: "client.").count - 1, 1, "\(name) calls one thing on the client")
            XCTAssertTrue(code.contains(call), name)
        }
    }

    // MARK: the engine client is the only code that starts cmm

    func testTheEngineClientIsTheOnlyCodeThatStartsCmmAndItsFourCommandsArePinned() throws {
        let files = try sources()
        XCTAssertEqual(files.filter { $0.code.contains("ChildProcess(") }.map(\.name), ["ProcessCmmClient.swift"])
        XCTAssertEqual(files.filter { $0.code.contains("\"--json\"") }.map(\.name), ["ProcessCmmClient.swift"], "only the client speaks to cmm")
        XCTAssertEqual(files.filter { $0.code.contains("\"--select-file\"") }.map(\.name), ["ProcessCmmClient.swift"])

        let client = try XCTUnwrap(files.first { $0.name == "ProcessCmmClient.swift" }).code
        let commands = try matches(#"arguments: \["[^\]]*\]"#, in: client)
        XCTAssertEqual(
            commands.sorted(),
            [
                #"arguments: ["apply", "--yes", "--json", "--select-file", file.url.path]"#,
                #"arguments: ["history", "--json", "--limit", "0", "--days", "90"]"#,
                #"arguments: ["plan", "--json"]"#,
                #"arguments: ["sample", "--json"]"#,
            ].sorted(),
            "cmm is started with these four commands and no other; the two new ones only read, and note the free space"
        )
        for command in commands where !command.contains("apply") {
            XCTAssertFalse(command.contains("--yes"), "only the cleaning carries --yes: \(command)")
        }
    }

    // MARK: what they say

    func testEveryStringTheNotificationBuilderCanProduceIsPlain() {
        let sizes: [Int64] = [
            Int64.min, -1, 0, 1, 999_999_999, 1_000_000_000, 1_500_000_000, 1_999_999_999, 2_000_000_000, 7_999_999_999,
            9_999_999_999, 10_000_000_000, 14_999_999_999, 15_000_000_000, 19_800_000_000, 28_400_000_000, 228_000_000_000,
            1_000_000_000_000, 1_000_000_000_000_000, Int64.max - 1, Int64.max,
        ]
        var spoken = 0
        for free in sizes {
            for canGo in sizes {
                guard let note = WeeklyNotification(free: free, canGo: canGo) else { continue }
                spoken += 1
                for text in [note.identifier, note.title, note.body] {
                    XCTAssertFalse(text.isEmpty)
                    XCTAssertFalse(text.contains("/"), "\(text) (free \(free), can go \(canGo))")
                    XCTAssertFalse(text.contains("\\"), text)
                    XCTAssertFalse(text.contains("~"), text)
                    XCTAssertFalse(text.lowercased().contains("docker"), text)
                }
                for text in [note.title, note.body] {
                    XCTAssertNil(text.range(of: #"[-−]\d"#, options: .regularExpression), "negative-looking: \(text)")
                }
            }
        }
        XCTAssertGreaterThan(spoken, 100, "the sweep reached the notifications")
    }

    func testAPlanFullOfPathsAndDockerSpeaksInNumbersOnly() {
        let plan = TestPlans.plan(
            [
                TestPlans.item("/Users/saint/Library/Caches/com.secret.app", group: "Caches of /Users/saint", rule: "caches", bytes: gigabytes(6)),
                TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gigabytes(30), tier: .review, action: .command, freesInside: "Docker's disk image"),
                TestPlans.item("/Volumes/Backup/Docker.raw", group: "Docker disk", rule: "docker-raw", bytes: gigabytes(40), tier: .manual),
            ],
            freeBytes: gigabytes(7), volume: "/Volumes/Docker"
        )
        guard case .notify(let note) = WeeklyPlanner(calendar: TestCalendars.rome).outcome(for: plan) else { return XCTFail("6 GB can go") }
        XCTAssertEqual(note.title, "Only 7.0 GB free")
        XCTAssertEqual(note.body, "6 GB can go.")
        for text in [note.identifier, note.title, note.body] {
            XCTAssertFalse(text.contains("/"), text)
            XCTAssertFalse(text.lowercased().contains("docker"), text)
            XCTAssertFalse(text.contains("secret"), text)
            XCTAssertFalse(text.contains("saint"), text)
        }
    }

    func testTheNotificationFileHoldsNoStringThatCouldNameAPathOrDocker() throws {
        let file = try XCTUnwrap(sources().first { $0.name == "NotificationContent.swift" })
        let literals = try matches(#""(?:[^"\\]|\\.)*""#, in: file.code)
        XCTAssertGreaterThanOrEqual(literals.count, 4, "the file's strings were found")
        for literal in literals {
            XCTAssertFalse(literal.contains("/"), literal)
            XCTAssertFalse(literal.lowercased().contains("docker"), literal)
        }
    }

    // MARK: the popover has no way to clean

    func testThePopoversActionsAreLookingOpeningAndQuittingAndNeverCleaning() {
        XCTAssertEqual(MenuBarAction.allCases.map(\.rawValue), ["scan", "openWindow", "openHistory", "openSettings", "quit"])
        for action in MenuBarAction.allCases {
            let word = action.rawValue.lowercased()
            for forbidden in ["clean", "delete", "remove", "apply", "confirm", "trash", "free"] {
                XCTAssertFalse(word.contains(forbidden), "\(action)")
            }
        }
    }

    // MARK: the menu bar keeps nothing

    func testTheMenuBarsMemoryIsNeverWrittenAnywhere() throws {
        // The memory is the three types of CmmKit that hold and word what the menu bar item knows. (The views that draw it, in
        // the app target, are held to the words above like every file of the new behaviours, and may use the settings.)
        let files = try sources(of: ["CmmKit"]).filter { $0.name.hasPrefix("MenuBar") }
        XCTAssertEqual(files.map(\.name), ["MenuBarContext.swift", "MenuBarModel.swift", "MenuBarPresentation.swift", "MenuBarState.swift"])
        for file in files {
            for token in [
                "UserDefaults", "SettingsStore", "SettingsModel", "SettingsKey", "FileManager", "write(", "Codable", "Encodable", "Decodable", "JSONEncoder",
                "PropertyListEncoder", "NSKeyedArchiver", "fileURLWithPath", "Data(", "@AppStorage", "SceneStorage",
            ] {
                XCTAssertFalse(file.code.contains(token), "\(file.name) uses `\(token)`")
            }
        }
        // and what it remembers cannot be turned into bytes
        let remembered: [Any] = [MenuBarContext(), FreeReading(bytes: 1, capacity: nil, at: Date(timeIntervalSince1970: 0))]
        for value in remembered { XCTAssertFalse(value is Encodable, "\(type(of: value)) can be encoded") }
    }
}

/// A history that was edited by hand, or damaged, can only change what is drawn (spec R10): it never crashes the app and never
/// makes it draw a number that cannot be.
@MainActor
final class TamperedHistoryTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    private let now = TestTime.utc("2026-10-15T09:00:00Z")

    /// Everything a report makes the app draw (the chart, the sentence, the rows and the menu bar), checking on the way that
    /// every number is one a disk could have. Returns the words, for the checks that are about words.
    private func everythingDrawn(from report: HistoryReport, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var texts: [String] = []

        let timeline = HistoryTimeline(report: report, now: now)
        texts += [timeline.caption].compactMap { $0 }
        if let chart = timeline.chart {
            XCTAssertGreaterThan(chart.yRange.highGB, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(chart.yRange.highGB, 1_000_000, "no taller than a petabyte", file: file, line: line)
            XCTAssertEqual(chart.yRange.lowBytes, 0, "the axis starts at zero", file: file, line: line)
            texts += [chart.yRange.lowLabel, chart.yRange.highLabel]
            for point in chart.segments.flatMap(\.points) {
                XCTAssertGreaterThanOrEqual(point.freeBytes, 0, "a point below zero", file: file, line: line)
                XCTAssertLessThanOrEqual(point.freeBytes, chart.yRange.highBytes, "a point above the axis", file: file, line: line)
                XCTAssertTrue(point.t >= chart.windowStart && point.t <= chart.windowEnd, "a point outside the window", file: file, line: line)
            }
            for gap in chart.gaps {
                XCTAssertLessThan(gap.start, gap.end, file: file, line: line)
                texts += [HistoryTimeline.Gap.title, gap.rangeText(calendar: rome, locale: british)]
            }
            for marker in chart.markers {
                XCTAssertGreaterThanOrEqual(marker.freedBytes, 0, file: file, line: line)
                XCTAssertGreaterThanOrEqual(marker.freeBytes, 0, file: file, line: line)
            }
        }

        let change = WeekChange(report: report, now: now)
        if let change {
            XCTAssertGreaterThanOrEqual(change.difference, 0, "a difference is a size", file: file, line: line)
            texts.append(change.text)
        }
        let totals = HistorySentences.freedTotals(report: report, now: now)
        if let totals { XCTAssertGreaterThanOrEqual(totals.bytes, 0, file: file, line: line) }
        texts += [HistorySentences.summary(totals: HistorySentences.totalsSentence(report: report, now: now, calendar: rome, locale: british), weekChange: change)].compactMap { $0 }

        let rows = RunRows(report: report, now: now, calendar: rome, locale: british, home: "/Users/test")
        texts += [rows.footnote].compactMap { $0 }
        for week in rows.weeks {
            XCTAssertGreaterThanOrEqual(week.freedBytes, 0, file: file, line: line)
            texts += [week.title, week.totalText]
            for row in week.rows {
                XCTAssertGreaterThanOrEqual(row.freedBytes, 0, file: file, line: line)
                texts += [row.dateText, row.timeText, row.freedText]
                texts += [row.groupsText, row.failedText, row.stoppedText, row.insideText, row.omittedText, row.footnote].compactMap { $0 }
                for item in row.items { texts += [item.title, item.detail, item.sizeText] + [item.insidePlace].compactMap { $0 } }
            }
        }

        var context = MenuBarContext()
        context.recordHistory(report, now: now)
        for phase in [AppModel.Phase.idle, .scanning, .ready, .empty, .cleaning, .done, .failed] {
            let shown = context.presentation(
                phase: phase, confirmationOpen: false, volumeName: "Macintosh HD", now: now, calendar: rome, locale: british
            )
            texts += [shown.item.title, shown.item.accessibilityLabel, shown.popover.header.text, shown.popover.sentence, shown.popover.scanTitle, shown.popover.spoken]
                .compactMap { $0 }
            texts += [shown.popover.note, shown.popover.historyRow?.text].compactMap { $0 }
            texts += shown.popover.groups.flatMap { [$0.title, $0.sizeText] }
        }
        return texts
    }

    private func assertPlain(_ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(texts.isEmpty, "something was drawn", file: file, line: line)
        for text in texts {
            XCTAssertNil(text.range(of: #"[-−]\d"#, options: .regularExpression), "negative-looking: \(text)", file: file, line: line)
            XCTAssertNil(text.range(of: #"\b(nan|inf|infinity)\b"#, options: [.regularExpression, .caseInsensitive]), "not a number: \(text)", file: file, line: line)
            XCTAssertNil(text.range(of: #"\de[+-]?\d"#, options: .regularExpression), "scientific: \(text)", file: file, line: line)
        }
    }

    /// A first week with real runs and notes, so a damaged entry has something sane beside it.
    private func sane() -> HistoryJSON {
        var json = HistoryJSON()
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":24000000000,"capacity_bytes":245107195904}"#
        json.runs = [
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4)),
            HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2.2)),
        ]
        json.samples = [
            HistoryJSON.sample("2026-10-08T09:00:00Z", free: gigabytes(27.1)),
            HistoryJSON.sample("2026-10-12T09:00:00Z", free: gigabytes(22)),
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: gigabytes(24)),
        ]
        return json
    }

    // MARK: single faults

    func testTheSaneHistoryDrawsSomethingSoTheChecksBelowAreNotEmpty() throws {
        let texts = everythingDrawn(from: try sane().report())
        assertPlain(texts)
        XCTAssertTrue(texts.contains { $0.hasPrefix("Freed 7.6 GB in 2 cleanings since 9 Oct.") }, "\(texts)")
    }

    func testNegativeBytesAreLeftOutAndNeverDrawn() throws {
        var json = sane()
        json.runs.append(HistoryJSON.run(finished: "2026-10-13T12:00:00Z", freed: -5_000_000_000, before: -1, after: -2))
        json.runs.append(HistoryJSON.run(finished: "2026-10-12T12:00:00Z", freed: gigabytes(1), before: -20_000_000_000))
        json.samples.append(HistoryJSON.sample("2026-10-13T09:00:00Z", free: -7))
        json.samples.append(HistoryJSON.sample("2026-10-13T10:00:00Z", free: gigabytes(5), capacity: -1))
        let report = try json.report()
        XCTAssertEqual(report.runs.count, 2, "the damaged runs are not in the report")
        XCTAssertGreaterThan(report.ignoredEntries, 0)
        assertPlain(everythingDrawn(from: report))
    }

    func testAnEntryThatFinishedBeforeItStartedIsDrawnAsAnEntryAtItsEnd() throws {
        var json = sane()
        json.runs.append(HistoryJSON.run(finished: "2026-10-13T12:00:00Z", started: "2026-10-13T18:00:00Z", freed: gigabytes(1)))
        let report = try json.report()
        assertPlain(everythingDrawn(from: report))
    }

    func testAnEntryFromTheFutureIsNotDrawnAtAll() throws {
        var json = sane()
        json.generatedAt = "2099-01-01T00:00:00Z"
        json.runs.append(HistoryJSON.run(finished: "2099-01-01T00:00:00Z", freed: gigabytes(900)))
        json.samples.append(HistoryJSON.sample("2099-01-01T00:00:00Z", free: gigabytes(10)))
        let report = try json.report()
        let texts = everythingDrawn(from: report)
        assertPlain(texts)
        XCTAssertFalse(texts.contains { $0.contains("900") || $0.contains("2099") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Freed 7.6 GB in 2 cleanings since 9 Oct.") }, "the same sentence as without it")
    }

    func testHugeValuesStopAtTheLargestNumberTheAppDraws() throws {
        var json = sane()
        json.runs.append(HistoryJSON.run(finished: "2026-10-13T12:00:00Z", freed: Int64.max, before: 0, after: 0))
        json.runs.append(HistoryJSON.run(finished: "2026-10-12T12:00:00Z", freed: HistoryLimits.maxBytes, before: 0, after: 0, deleted: Int.max))
        json.runs.append(HistoryJSON.run(finished: "2026-10-11T12:00:00Z", freed: HistoryLimits.maxBytes, before: 0, after: 0))
        json.runs.append(HistoryJSON.run(finished: "2026-10-10T12:00:00Z", freed: HistoryLimits.maxBytes, before: 0, after: 0))
        json.samples.append(HistoryJSON.sample("2026-10-13T09:00:00Z", free: Int64.max))
        json.samples.append(HistoryJSON.sample("2026-10-13T10:00:00Z", free: HistoryLimits.maxBytes))
        let report = try json.report()
        assertPlain(everythingDrawn(from: report))
    }

    func testAnUnreadableHostIsNotAnEmptyDisk() throws {
        var json = sane()
        json.host = #"{"volume":"","free_bytes":0}"#
        let report = try json.report()
        XCTAssertNil(report.host.freeBytes, "unreadable, not zero")
        let texts = everythingDrawn(from: report)
        assertPlain(texts)
        XCTAssertFalse(
            texts.contains { $0.range(of: #"(^|[^0-9.])0 (GB|MB|KB|bytes?) free"#, options: .regularExpression) != nil },
            "an unreadable disk is not drawn as an empty one: \(texts)"
        )
    }

    func testAbsurdTextInAnEntryIsJustText() throws {
        var json = sane()
        let long = String(repeating: "x", count: 200_000)
        json.runs.append(HistoryJSON.run(
            finished: "2026-10-13T12:00:00Z", freed: gigabytes(1),
            items: [HistoryJSON.item(group: long, path: "/Users/test/" + long, status: "weird", reason: "\u{0000}\n\r\t")]
        ))
        assertPlain(everythingDrawn(from: try json.report()))
    }

    // MARK: ten thousand runs

    func testTenThousandRunsAreDrawnWithoutTrouble() throws {
        var json = sane()
        json.runs = (0..<10_000).map { index in
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(-Double(index) * 60 - 60)), freed: gigabytes(0.5))
        }
        json.samples = (0..<10_000).map { index in
            HistoryJSON.sample(TestTime.iso(now.addingTimeInterval(-Double(index) * 300 - 300)), free: gigabytes(Double(10 + index % 40)))
        }
        let report = try json.report()
        XCTAssertEqual(report.runs.count, 10_000)

        let started = ContinuousClock.now
        let texts = everythingDrawn(from: report)
        let took = ContinuousClock.now - started
        assertPlain(texts)
        XCTAssertLessThan(took, .seconds(30), "ten thousand runs took \(took)")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Freed 5.0 TB in 10000 cleanings since 8 Oct.") }, "the sum is the sum: \(texts.filter { $0.hasPrefix("Freed") }.prefix(1))")
    }

    func testTenThousandPetabyteRunsAddUpToTheLargestNumberAndNoFurther() throws {
        // each run is as large as a run may be; together they are more than an Int64 holds
        var json = sane()
        json.runs = (0..<10_000).map { index in
            HistoryJSON.run(
                finished: TestTime.iso(now.addingTimeInterval(-Double(index) - 60)), freed: HistoryLimits.maxBytes, before: 0, after: 0
            )
        }
        let report = try json.report()
        XCTAssertEqual(report.runs.count, 10_000)
        let texts = everythingDrawn(from: report)
        assertPlain(texts)
        XCTAssertEqual(HistorySentences.freedTotals(report: report, now: now)?.bytes, Int64.max, "it stops at the largest number")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Freed ") && $0.contains("in 10000 cleanings") }, "\(texts.filter { $0.hasPrefix("Freed") }.prefix(1))")
    }

    // MARK: everything at once, and what is not a report at all

    func testEverythingWrongAtOnce() throws {
        var json = sane()
        json.host = #"{"volume":"","free_bytes":-1}"#
        json.generatedAt = "not a time"
        json.unreadable = 40
        json.runs += [
            HistoryJSON.run(finished: "2026-10-13T12:06:00Z", freed: -5_000_000_000, before: -1, after: -2),
            HistoryJSON.run(finished: "2026-10-12T12:00:00Z", started: "2026-10-12T20:00:00Z", freed: gigabytes(1)),
            HistoryJSON.run(finished: "2099-01-01T00:00:00Z", freed: gigabytes(900)),
            HistoryJSON.run(finished: "1970-01-01T00:00:00Z", freed: gigabytes(900)),
            HistoryJSON.run(finished: "2026-10-11T12:00:00Z", freed: Int64.max, before: 0, after: 0),
            HistoryJSON.run(finished: "2026-10-10T12:00:00Z", freed: gigabytes(1), deleted: -1, skipped: Int.max, failed: Int.min),
            HistoryJSON.run(finished: "2026-10-09T12:00:00Z", freed: gigabytes(1), schema: 99),
            "{\"finished_at\":\"2026-10-08T12:00:00Z\"}",
            "7", "null", "\"text\"", "[]",
        ]
        json.samples += [
            HistoryJSON.sample("2026-10-13T09:00:00Z", free: -7),
            HistoryJSON.sample("2099-01-01T00:00:00Z", free: gigabytes(10)),
            HistoryJSON.sample("garbage", free: gigabytes(10)),
            "{\"t\":\"2026-10-13T09:00:00Z\"}",
            "3", "null",
        ]
        let report = try json.report()
        assertPlain(everythingDrawn(from: report))
    }

    func testWhatIsNotAReportIsAnErrorTheAppCanShowAndNotACrash() {
        let notReports: [Data] = [
            Data(), Data("null".utf8), Data("[]".utf8), Data("{}".utf8), Data("not json".utf8), Data("{\"schema_version\":1}".utf8),
            Data("{\"schema_version\":1,\"runs\":7,\"samples\":\"x\"}".utf8),
            Data("{\"schema_version\":2,\"runs\":[],\"samples\":[]}".utf8),
            Data(String(repeating: "[", count: 200_000).utf8),
            Data(String(repeating: "{\"a\":", count: 100_000).utf8),
            Data(repeating: 0xFF, count: 10_000),
        ]
        for data in notReports {
            do {
                let report = try HistoryReport.parse(data)
                assertPlain(everythingDrawn(from: report))  // an odd shape that is still a report draws like one
            } catch let error as CmmError {
                XCTAssertFalse(error.title.isEmpty)
            } catch {
                XCTFail("an error that is not cmm's: \(error)")
            }
        }
    }
}
