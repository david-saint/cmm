import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// What VoiceOver finds on the History face (spec R11), read from the accessibility tree the hosted window really has (as
/// `MapAccessibilityTests` reads the map's): the chart is one element that says the paragraph, the list is its equivalent in
/// words, a row says itself as one line and whether it is open, pressing a row opens it, and Retry reads again.
@MainActor
final class HistoryAccessibilityTests: XCTestCase {
    /// One node of the tree, read through the accessibility API and nothing else.
    private struct Node {
        let object: NSObject

        var role: String { (object.value(forKey: "accessibilityRole") as? String) ?? "" }
        var label: String { (object.value(forKey: "accessibilityLabel") as? String) ?? "" }
        var value: String {
            let value = object.value(forKey: "accessibilityValue")
            return value.map { String(describing: $0) } ?? ""
        }
        var help: String { (object.value(forKey: "accessibilityHelp") as? String) ?? "" }
        var children: [Node] { ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(Node.init) } }

        func find(label: String) -> Node? {
            if self.label == label { return self }
            for child in children { if let found = child.find(label: label) { return found } }
            return nil
        }

        func all(where test: (Node) -> Bool) -> [Node] {
            (test(self) ? [self] : []) + children.flatMap { $0.all(where: test) }
        }

        /// What VoiceOver does when the person activates the element (VO-Space).
        @discardableResult
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        }
    }

    private struct Rig {
        let face: HistoryFaceState
        let history: HistoryModel
        let client: FakeCmmClient
        let hosting: NSView
        var root: Node { Node(object: hosting) }
    }

    private let size = CGSize(width: 1100, height: 720)

    /// - Parameter hold: the History's reads are held until the test ends, so a read that is taking a while can be heard.
    private func rig(
        histories: [Result<HistoryReport, CmmError>]? = nil, face: HistoryFaceState? = nil, hold: Bool = false
    ) async throws -> Rig {
        _ = NSApplication.shared
        // an assistive app asking for the tree is what makes SwiftUI build it
        func ask(_ on: Bool) {
            let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
            for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                _ = NSApp.perform(selector, with: NSNumber(value: on), with: attribute as NSString)
            }
        }
        ask(true)
        addTeardownBlock { @MainActor in ask(false) }

        let board = try HistoryBoard.report()
        let client = FakeCmmClient(plans: [.success(try TestPlans.fixture("plan-c.json"))], histories: histories ?? [.success(board)])
        if hold {
            let gate = client.holdHistories()
            addTeardownBlock { gate.open() }
        }
        let model = AppModel(client: client, now: { HistoryBoard.now })
        await model.scan()
        let history = HistoryModel(client: client)
        let faceState = face ?? HistoryFaceState()
        let hosting = NSHostingView(
            rootView: RootView(model: model, window: WindowState(detailsOpen: true, face: .history), env: HistoryViewsTests.env)
                .environment(history)
                .environment(faceState)
                .frame(width: size.width, height: size.height)
        )
        let window = OffscreenWindow(size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }
        try? await Task.sleep(for: .seconds(0.6))
        return Rig(face: faceState, history: history, client: client, hosting: hosting)
    }

    private func boardRows() throws -> [RunRows.Row] {
        RunRows(report: try HistoryBoard.report(), now: HistoryBoard.now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale,
                home: "/Users/test").listed
    }

    private let summary = "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago."

    // MARK: the chart

    func testTheChartIsOneElementThatSaysTheParagraphAndNothingElse() async throws {
        let rig = try await rig()
        let chart = try XCTUnwrap(rig.root.find(label: summary), "the chart reads the paragraph")
        XCTAssertEqual(chart.role, "AXImage")
        XCTAssertTrue(chart.children.isEmpty, "no element per reading, per day or per rise")
        let saying = rig.root.all { $0.label == summary || $0.value == summary }
        XCTAssertEqual(saying.count, 1, "the paragraph itself is silent while the chart says it: it is heard once")
        // the chart's own words (the axes, the gap, the value now) are not elements of their own
        for word in ["No samples", "50 GB", "0", "29 Sep", "6 Oct", "13 Oct", "now", "19.8 GB"] {
            XCTAssertTrue(rig.root.all { $0.label == word || $0.value == word }.isEmpty, "\(word) is an element")
        }
    }

    func testWithoutAParagraphTheChartSaysTheWordsUnderTheLine() async throws {
        let samples = HistoryBoard.hourly(from: HistoryBoard.at(10, 12, 18, 0), to: HistoryBoard.at(10, 14, 14, 0)) { _ in 20 }
        let rig = try await rig(histories: [.success(try HistoryBoard.report(runs: [], samples: samples))])
        let chart = try XCTUnwrap(rig.root.find(label: "History fills in as cmm runs: 2 days so far."))
        XCTAssertEqual(chart.role, "AXImage")
    }

    // MARK: the list

    func testEachCleaningIsAButtonThatSaysItselfAsOneLineAndWhetherItIsOpen() async throws {
        let rig = try await rig()
        let rows = try boardRows()
        let buttons = rig.root.all { $0.role == "AXButton" && $0.label.contains(" freed") }
        XCTAssertEqual(buttons.map(\.label), rows.map(\.spoken), "in the order of the list")
        XCTAssertEqual(buttons.map(\.value), ["collapsed", "collapsed", "collapsed", "collapsed"])
        XCTAssertEqual(
            buttons.map(\.label),
            [
                "Tue 14 Oct 14:20, 0 GB freed, Docker, 9.0 GB inside Docker's disk image, not counted",
                "Tue 14 Oct 14:06, 5.4 GB freed, Idle lane dependencies, uv cache, Go build cache",
                "Thu 9 Oct 09:41, 2.2 GB freed, Homebrew old versions, npm cache, 1 failed",
                "Mon 29 Sep 10:02, 36.4 GB freed, Unavailable simulators, idle lane dependencies, old CLI versions and 4 more",
            ]
        )
    }

    func testTheWeeksAreHeadingsThatSayWhatTheyGaveBack() async throws {
        let rig = try await rig()
        let headings = rig.root.all { $0.role == "AXHeading" && $0.label.hasSuffix("freed") }.map(\.label)
        XCTAssertEqual(headings, ["This week, 5.4 GB freed", "Last week, 2.2 GB freed", "29 Sep \u{2013} 5 Oct, 36.4 GB freed"])
    }

    func testPressingACleaningAsVoiceOverDoesOpensItAndItsItemsAreRead() async throws {
        let rig = try await rig()
        let failed = try XCTUnwrap(try boardRows().first { $0.failedText != nil })
        let button = try XCTUnwrap(rig.root.find(label: failed.spoken))
        XCTAssertTrue(button.press())
        try? await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(rig.face.expanded, [failed.id])
        XCTAssertEqual(rig.root.find(label: failed.spoken)?.value, "expanded")
        for item in ["~/Library/Caches/go-build, permission denied, 1.2 GB", "homebrew: cleanup, deleted, 0.7 GB", "~/.npm/_cacache, deleted, 0.3 GB"] {
            XCTAssertNotNil(rig.root.find(label: item), "the open cleaning's item is read: \(item)")
        }
        XCTAssertTrue(rig.root.find(label: failed.spoken)?.press() ?? false)
        try? await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(rig.face.expanded, [])
        XCTAssertEqual(rig.root.find(label: failed.spoken)?.value, "collapsed")
    }

    func testEveryButtonOnTheFaceSaysWhatItIs() async throws {
        let rig = try await rig()
        let nameless = rig.root.all { $0.role == "AXButton" && $0.label.isEmpty }
        XCTAssertTrue(nameless.isEmpty, "\(nameless.count) buttons without a name")
    }

    // MARK: a failed read and Retry

    func testAFailedReadIsOneSentenceAndRetryReadsAgain() async throws {
        let failure = CmmError.historyFailed(status: 1, stderr: "cmm: cannot read /Users/test/.local/state/cmm/history.jsonl")
        let rig = try await rig(histories: [.failure(failure), .failure(failure), .success(try HistoryBoard.report())])
        // the face read once when it appeared, and failed
        XCTAssertEqual(rig.client.historyCalls, 1)
        let sentence = "cmm could not read the history."
        XCTAssertEqual(rig.root.all { $0.label == sentence || $0.value == sentence }.count, 1, "the failure is said once")
        XCTAssertEqual(rig.root.all { $0.role == "AXButton" && $0.label == "Retry" }.count, 1, "with one Retry")
        let retry = try XCTUnwrap(rig.root.find(label: "Retry"))
        XCTAssertEqual(retry.role, "AXButton")
        XCTAssertEqual(retry.help, "Reads the history again")
        XCTAssertTrue(retry.press())
        let deadline = Date().addingTimeInterval(3)
        while rig.client.historyCalls < 2, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.client.historyCalls, 2, "Retry read the history once more")
        // the second try failed too; the third works
        try? await Task.sleep(for: .seconds(0.3))
        XCTAssertTrue(try XCTUnwrap(rig.root.find(label: "Retry")).press())
        while rig.history.report == nil, Date() < deadline.addingTimeInterval(3) { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(rig.history.report, "and the report came in")
        try? await Task.sleep(for: .seconds(0.4))
        XCTAssertNotNil(rig.root.find(label: summary), "the face shows it")
        XCTAssertNil(rig.root.find(label: "Retry"), "and Retry is gone with the failure")
    }

    func testAReadThatIsTakingAWhileIsSaidOnce() async throws {
        // no report yet, and the moment is over at once: the face says only that it is reading
        let rig = try await rig(face: HistoryFaceState(wait: { _ in }), hold: true)
        XCTAssertEqual(rig.client.historyCalls, 1, "the read is out")
        let reading = HistoryReadStatus.readingText
        XCTAssertEqual(rig.root.all { $0.label == reading || $0.value == reading }.count, 1, "and it is said once")
        XCTAssertTrue(rig.root.all { $0.role == "AXButton" && $0.label == "Retry" }.isEmpty, "with nothing to retry")
    }
}
