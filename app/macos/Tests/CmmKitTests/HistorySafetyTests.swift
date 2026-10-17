import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The History face can only look and say (spec R10, R11). Part of this file reads the app's own source, bluntly, like the other
/// safety tests: when a check trips, read the rule, then change the check together with a reason. The rest feeds the face
/// histories no cmm would write (negative sizes, a cleaning that ended before it began, one from the future, ten thousand
/// cleanings, sizes no disk has, groups without names) and checks that it draws them without crashing and without nonsense.
@MainActor
final class HistorySafetyTests: XCTestCase {
    // MARK: reading the app's source

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CmmKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app/macos

    private struct SourceFile {
        let target: String
        let name: String
        let raw: String  // as written, comments and all
        let code: String  // without `//` comments
    }

    private func sources(_ target: String) throws -> [SourceFile] {
        let folder = Self.packageRoot.appendingPathComponent("Sources/\(target)")
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "no sources found in \(folder.path): these checks would pass for the wrong reason")
        return try urls.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            return SourceFile(target: target, name: url.lastPathComponent, raw: text, code: Self.strippingComments(text))
        }
    }

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

    /// The History face's views (the app target's files named History...).
    private func viewFiles() throws -> [SourceFile] {
        try sources("Cmm").filter { $0.name.hasPrefix("History") }
    }

    func testTheHistoryFilesNeverMentionCleaningDeletingLaunchingOrFiles() throws {
        let files = try sources("Cmm").filter { $0.name.hasPrefix("History") } + sources("CmmKit").filter { $0.name.hasPrefix("History") }
        let names = Set(files.map(\.name))
        for known in [
            "HistoryFace.swift", "HistoryRunRow.swift", "HistoryChart.swift", "HistoryTheme.swift", "HistoryRefresh.swift",
            "HistoryFaceState.swift", "HistoryChartLayout.swift", "HistoryNavigation.swift", "HistoryReadStatus.swift",
            "HistoryRefreshRule.swift", "HistorySpoken.swift",
        ] {
            XCTAssertTrue(names.contains(known), "\(known) is among the files these checks read")
        }
        // the words of the brief's traps, in the files as written (a comment that names one is rewritten, not excused)
        for token in ["confirmClean", "apply", "removeItem", "trashItem", "Process(", "NSWorkspace", "ProcessInfo", "FileManager"] {
            XCTAssertEqual(files.filter { $0.raw.contains(token) }.map(\.name), [], "`\(token)` appears")
        }
    }

    func testTheFaceOnlyReadsTheHistoryModelAndNeverTouchesTheWindowsModelOrTheClient() throws {
        let files = try viewFiles()
        for token in ["model.", "AppModel(", ".scan(", "toggle(item", "requestClean", "CmmClient", "client.", "Settings.standard", "settings?.", "settings."] {
            let found = files.filter { $0.code.contains(token) }.map(\.name)
            if token == "settings?." {
                XCTAssertEqual(found, ["HistoryFace.swift"], "the face reads the history switch, nothing else of the settings")
            } else if token != "settings." {
                XCTAssertEqual(found, [], "`\(token)` appears in the History face's views")
            }
        }
        // what the views ask of the History model: to read, and what it holds
        var asked = Set<String>()
        for file in files {
            let pattern = try NSRegularExpression(pattern: #"history\.(\w+)"#)
            for match in pattern.matches(in: file.code, range: NSRange(file.code.startIndex..., in: file.code)) {
                asked.insert((file.code as NSString).substring(with: match.range(at: 1)))
            }
        }
        XCTAssertEqual(asked, ["load", "presentation", "phase", "isLoading"])
        XCTAssertEqual(files.filter { $0.code.contains("history.load()") }.map(\.name).sorted(), ["HistoryFace.swift", "HistoryRefresh.swift"])
        let face = try XCTUnwrap(files.first { $0.name == "HistoryFace.swift" }).code
        XCTAssertEqual(face.components(separatedBy: "history.load()").count - 1, 2, "when the face appears, and Retry")
        XCTAssertTrue(face.contains("settings?.historyEnabled ?? true"), "with no settings the history counts as on")
    }

    func testTheReadAfterACleaningIsWatchedOnceAtTheWindowsRoot() throws {
        let root = try XCTUnwrap(try sources("Cmm").first { $0.name == "RootView.swift" }).code
        XCTAssertEqual(root.components(separatedBy: "HistoryRefresh(").count - 1, 1)
        XCTAssertTrue(root.contains(".modifier(HistoryRefresh(phase: model.phase))"))
        let refresh = try XCTUnwrap(try viewFiles().first { $0.name == "HistoryRefresh.swift" }).code
        XCTAssertTrue(refresh.contains("HistoryRefreshRule.readsAgain(from: old, to: new)"))
        XCTAssertEqual(refresh.components(separatedBy: "history.").count - 1, 1, "and all it does is read")
    }

    /// The face's keys are the pane's (in DetailsPane.swift, the one file besides the map's that the source tripwire allows to
    /// handle keys), and they stop behind the confirmation card and when a modifier makes the key a shortcut.
    func testTheFacesKeysGoThroughThePanesHandlerWhichStopsBehindTheCard() throws {
        let files = try viewFiles()
        for token in [".onKeyPress", ".keyboardShortcut(", "NSEvent", "keyDown"] {
            XCTAssertEqual(files.filter { $0.code.contains(token) }.map(\.name), [], "`\(token)` appears in the History face's views")
        }
        let face = try XCTUnwrap(files.first { $0.name == "HistoryFace.swift" }).code
        XCTAssertTrue(face.contains(".modifier(PaneKeys {"))
        XCTAssertTrue(face.contains("HistoryNavigation.handle(key,"))
        let pane = try XCTUnwrap(try sources("Cmm").first { $0.name == "DetailsPane.swift" }).code
        let keys = try XCTUnwrap(pane.range(of: "struct PaneKeys"))
        let handler = pane[keys.lowerBound...]
        XCTAssertTrue(handler.contains("@Environment(\\.isEnabled)"))
        XCTAssertTrue(handler.contains("guard isEnabled, press.modifiers.isDisjoint(with: [.command, .option, .control])"))
    }

    /// Reduce Motion (spec R11): nothing on the face moves by itself, so there is nothing to stop; and the chart's read-out is
    /// paint that takes no clicks and says nothing to VoiceOver (the chart says the paragraph, once).
    func testNothingOnTheFaceIsAnimatedAndTheReadoutIsPaintOnly() throws {
        let files = try viewFiles()
        for token in ["withAnimation", ".animation(", "TimelineView", ".transition(", "repeatForever"] {
            XCTAssertEqual(files.filter { $0.code.contains(token) }.map(\.name), [], "`\(token)` appears in the History face's views")
        }
        let chart = try XCTUnwrap(files.first { $0.name == "HistoryChart.swift" }).code
        XCTAssertEqual(chart.components(separatedBy: ".allowsHitTesting(false)").count - 1, 2, "the gap's words and the read-out")
        XCTAssertEqual(chart.components(separatedBy: ".accessibilityHidden(true)").count - 1, 2)
        XCTAssertEqual(chart.components(separatedBy: ".accessibilityElement(children: .ignore)").count - 1, 1, "the chart is one element")
    }

    // MARK: a tampered history

    private let now = HistoryBoard.now

    private func iso(_ date: Date) -> String { HistoryBoard.iso(date) }

    /// A history no cmm would write, each line of it wrong in its own way.
    private func tampered() -> HistoryJSON {
        var json = HistoryJSON()
        json.generatedAt = iso(now)
        json.host = HistoryBoard.host
        let unnamed = HistoryJSON.item(rule: "", group: "", path: "/Users/test/x", bytes: gigabytes(1))
        json.runs = [
            // negative sizes, which the reader leaves out
            HistoryJSON.run(finished: iso(now.addingTimeInterval(-3_600)), freed: -5_000_000_000, before: -1, after: -2),
            // finished before it started
            HistoryJSON.run(finished: iso(now.addingTimeInterval(-7_200)), started: iso(now.addingTimeInterval(3_600)), freed: gigabytes(1), items: [unnamed]),
            // from the future
            HistoryJSON.run(finished: "2099-01-01T00:00:00Z", freed: gigabytes(900)),
            // sizes no disk has, and the largest a disk could have
            HistoryJSON.run(finished: iso(now.addingTimeInterval(-10_800)), freed: Int64.max, before: 0, after: 0),
            HistoryJSON.run(finished: iso(now.addingTimeInterval(-14_400)), freed: HistoryLimits.maxBytes, before: 0, after: HistoryLimits.maxBytes),
            // groups without names, and an item of no size
            HistoryJSON.run(finished: iso(now.addingTimeInterval(-18_000)), freed: gigabytes(2), items: [unnamed, HistoryJSON.item(rule: "", group: "", path: "", bytes: 0)]),
            // counts no cleaning has
            HistoryJSON.run(finished: iso(now.addingTimeInterval(-21_600)), freed: gigabytes(1), deleted: -1, skipped: Int.max, failed: Int.min),
        ]
        json.samples = [
            HistoryJSON.sample(iso(now.addingTimeInterval(-86_400)), free: -7),
            HistoryJSON.sample(iso(now.addingTimeInterval(-80_000)), free: HistoryLimits.maxBytes),
            HistoryJSON.sample(iso(now.addingTimeInterval(-70_000)), free: Int64.max),
            HistoryJSON.sample(iso(now.addingTimeInterval(-60_000)), free: gigabytes(20)),
            HistoryJSON.sample("2099-01-01T00:00:00Z", free: gigabytes(10)),
            HistoryJSON.sample("garbage", free: gigabytes(10)),
        ]
        return json
    }

    /// Ten thousand cleanings, a minute apart, and a note every five minutes.
    private func tenThousand() -> HistoryJSON {
        var json = HistoryJSON()
        json.generatedAt = iso(now)
        json.host = HistoryBoard.host
        json.runs = (0..<10_000).map { index in
            HistoryJSON.run(
                finished: iso(now.addingTimeInterval(-Double(index) * 60 - 60)), freed: gigabytes(0.5),
                items: [HistoryJSON.item(rule: "uv-cache", group: "uv cache", path: "/Users/test/.cache/uv", bytes: gigabytes(0.5))]
            )
        }
        json.samples = (0..<4_000).reversed().map { index in
            HistoryJSON.sample(iso(now.addingTimeInterval(-Double(index) * 300 - 300)), free: gigabytes(Double(10 + index % 40)))
        }
        return json
    }

    /// Every word the face would draw for a report: the paragraph, the words under the line, the weeks, the rows, the items,
    /// and the chart's labels and read-outs.
    private func everythingSaid(_ report: HistoryReport) -> (words: [String], layout: HistoryChartLayout?) {
        let face = HistoryPresentation(report: report, historyEnabled: true, now: now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale, home: "/Users/test")
        var words = [face.summary, face.timeline?.caption, face.emptyMessage, face.rows.footnote, face.chartLabel].compactMap { $0 }
        for week in face.rows.weeks {
            words += [week.title, week.totalText, week.spoken]
            for row in week.rows {
                words += [row.dateText, row.timeText, row.freedText, row.spoken] + [row.groupsText, row.failedText, row.stoppedText, row.insideText, row.omittedText, row.footnote].compactMap { $0 }
                words += row.items.flatMap { [$0.title, $0.detail, $0.sizeText, $0.spoken] }
            }
        }
        let layout = face.timeline?.chart.map {
            HistoryChartLayout(chart: $0, width: HistoryFaceContent.width, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale)
        }
        if let layout {
            words += (layout.valueLabels + layout.timeLabels + [layout.nowLabel].compactMap { $0 }).map(\.text)
            words += layout.gaps.flatMap { [$0.range, $0.label?.text].compactMap { $0 } }
            for step in 0...20 {
                let time = layout.start.addingTimeInterval(Double(step) / 20 * layout.end.timeIntervalSince(layout.start))
                if let readout = layout.readout(at: time) { words += [readout.first, readout.second] }
            }
        }
        return (words, layout)
    }

    private func assertSensible(_ report: HistoryReport, file: StaticString = #filePath, line: UInt = #line) {
        let (words, layout) = everythingSaid(report)
        for word in words {
            XCTAssertNil(word.range(of: #"-\d"#, options: .regularExpression), "a negative number is said: \(word)", file: file, line: line)
            for nonsense in ["nan", "inf", "NaN", "Inf", "9223372036854775807", "2099"] {
                XCTAssertFalse(word.contains(nonsense), "\(nonsense) is said: \(word)", file: file, line: line)
            }
        }
        guard let layout else { return }
        let block = CGRect(x: 0, y: 0, width: layout.width, height: HistoryChartLayout.height)
        let plot = layout.plot.insetBy(dx: -0.01, dy: -0.01)
        var points = layout.lines.flatMap { $0 } + layout.dots + layout.readings.map(\.point)
        points += layout.rises.flatMap { [CGPoint(x: $0.x, y: $0.fromY), CGPoint(x: $0.x, y: $0.toY)] }
        for point in points {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite && plot.contains(point), "drawn outside the plot: \(point)", file: file, line: line)
        }
        for label in layout.valueLabels + layout.timeLabels + [layout.nowLabel].compactMap({ $0 }) + layout.gaps.compactMap(\.label) {
            XCTAssertTrue(label.x.isFinite && label.y.isFinite && block.insetBy(dx: -1, dy: -1).contains(CGPoint(x: label.x, y: label.y)),
                          "a word placed outside the chart: \(label)", file: file, line: line)
        }
    }

    func testATamperedHistoryIsDrawnWithoutNonsense() throws {
        let report = try tampered().report()
        XCTAssertGreaterThan(report.ignoredEntries, 0, "the reader left the worst of it out")
        assertSensible(report)
        let face = HistoryPresentation(report: report, historyEnabled: true, now: now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale, home: "/Users/test")
        XCTAssertFalse(face.rows.listed.contains { $0.finishedAt > now }, "nothing from the future is listed")
        XCTAssertTrue(face.rows.listed.allSatisfy { $0.groupsText?.isEmpty != true }, "a group without a name is left out, not said as nothing")
        XCTAssertEqual(face.rows.footnote.map { $0.hasSuffix("could not be read.") }, true, "the lines that were left out are counted, quietly")
    }

    func testTenThousandCleaningsAreDrawnWithoutNonsense() throws {
        let report = try tenThousand().report()
        assertSensible(report)
    }

    func testATamperedHistoryAndTenThousandCleaningsDrawInTheWindowWithoutTrouble() async throws {
        for (name, json) in [("tampered", tampered()), ("ten-thousand", tenThousand())] {
            let report = try json.report()
            let model = AppModel(client: FakeCmmClient(plan: try TestPlans.fixture("plan-c.json")), now: { HistoryBoard.now })
            await model.scan()
            let history = HistoryModel(fetch: { report })
            let started = Date()
            await history.load()
            let hosting = NSHostingView(
                rootView: RootView(model: model, window: WindowState(detailsOpen: true, face: .history), env: HistoryViewsTests.env)
                    .environment(history)
                    .environment(HistoryFaceState(expanded: Set(HistoryPresentation(
                        report: report, historyEnabled: true, now: now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale, home: "/Users/test"
                    ).rows.listed.prefix(3).map(\.id))))
                    .frame(width: 1100, height: 720)
            )
            let window = OffscreenWindow(size: CGSize(width: 1100, height: 720))
            window.contentView = hosting
            window.orderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            window.contentView = nil
            window.orderOut(nil)
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, "\(name) took too long to draw")
            var colours = Set<String>()
            for x in stride(from: 660, to: 1080, by: 4) {
                for y in stride(from: 90, to: 700, by: 4) {
                    guard let c = bitmap.colorAt(x: x * bitmap.pixelsWide / 1100, y: y * bitmap.pixelsHigh / 720)?.usingColorSpace(.deviceRGB) else { continue }
                    colours.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent))
                }
            }
            XCTAssertGreaterThan(colours.count, 8, "\(name): the face drew something")
        }
    }
}
