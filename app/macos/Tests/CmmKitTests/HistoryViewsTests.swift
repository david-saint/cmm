import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The History face drawn in the real window, offscreen, in light and dark, for each state the boards draw (`C-History`,
/// `C-History-Dark`, `C-History-States`) and the two they do not. Set CMM_SNAPSHOT_DIR to a folder to keep the pictures
/// (`history-<state>-light.png`, `-dark.png`), to set them beside the boards' own renders.
///
/// What a picture cannot show (the words of each part, what VoiceOver reads, what a key does) is tested on the pure types the
/// face draws and through the hosted window (`HistoryInteractionTests`, `HistoryAccessibilityTests`).
@MainActor
final class HistoryViewsTests: XCTestCase {
    static let size = CGSize(width: 1100, height: 720)

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    nonisolated static let env = ViewEnvironment(
        home: "/Users/test",
        volumeName: { _ in "Macintosh HD" },
        now: { HistoryBoard.now },
        calendar: HistoryBoard.calendar,
        locale: HistoryBoard.locale,
        reveal: { _ in },
        shadowDirection: -1,  // cacheDisplay draws layer shadows upside down; see ViewEnvironment
        showsFocusWithoutKeyboard: true
    )

    // MARK: rendering

    func render<V: View>(
        _ view: V, name: String, appearance: NSAppearance.Name, increasedContrast: Bool = false, size: CGSize = HistoryViewsTests.size
    ) async throws -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view.environment(\.cmmIncreasedContrast, increasedContrast).frame(width: size.width, height: size.height)
        )
        // A window that is really ordered in (far off every screen), and waits that let go of the main actor (spinning the run
        // loop from inside this test would not), so the face's own work runs as it does in the app: its read when it appears,
        // and what it says while the read is out.
        let window = OffscreenWindow(size: size)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["CMM_SNAPSHOT_DIR"], !directory.isEmpty {
            let label = (appearance == .darkAqua ? "dark" : "light") + (increasedContrast ? "-contrast" : "")
            let url = URL(fileURLWithPath: directory).appendingPathComponent("history-\(name)-\(label).png")
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url) }
        }
        return bitmap
    }

    /// Mean brightness (0 black ... 1 white) over a grid of pixels.
    func brightness(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0.0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 20) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 20) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
    }

    /// How many distinct colours a region has (top-left origin, in points of a 1x bitmap); a blank region has one.
    func distinctColors(_ bitmap: NSBitmapImageRep, in rect: CGRect? = nil) -> Int {
        let scale = Double(bitmap.pixelsWide) / Self.size.width
        let area = rect ?? CGRect(origin: .zero, size: Self.size)
        var seen = Set<String>()
        for x in stride(from: area.minX, to: area.maxX, by: 3) {
            for y in stride(from: area.minY, to: area.maxY, by: 3) {
                guard let c = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return seen.count
    }

    /// The pane, where the face is: right of x = 640 in a 1100 pt window, under its header.
    static let face = CGRect(x: 650, y: 86, width: 430, height: 620)

    // MARK: the states

    enum Scenario: String, CaseIterable {
        /// C-History: the four cleanings, the one with the failed item open (panel 4 of C-History-States too), the pointer on
        /// the board's reading.
        case board
        /// Panel 1: nothing cleaned yet.
        case firstRun
        /// Panel 2: two and a bit days of notes and one cleaning.
        case fewSamples
        /// Panel 3: a gap of two days, the pointer in it.
        case gap
        /// Panel 5: a run that was stopped after two of nine, open.
        case stopped
        /// Panel 6: a run that only pruned Docker, open.
        case dockerOnly
        /// The line under the panels: "Keep a free-space history" is off.
        case historyOff
        /// Not on the boards: no report yet, and a read that is taking a while.
        case reading
        /// Not on the boards: the last report, and a new read that is taking a while.
        case readingAgain
        /// Not on the boards: cmm could not be read, and there is no report to show.
        case readFailed
        /// Not on the boards: the last report kept, and the failure of the read after it.
        case readFailedAgain
        /// Two lines of the history could not be read.
        case unreadable
    }

    struct Rig {
        let model: AppModel
        let window: WindowState
        let history: HistoryModel
        let state: HistoryFaceState
        var settings: SettingsModel?
        var env = HistoryViewsTests.env
        /// Lets go of whatever the scenario holds (a read that is kept waiting).
        var finish: () -> Void = {}

        @MainActor
        func view() -> some View {
            RootView(model: model, window: window, env: env)
                .environment(history)
                .environment(state)
                .environment(settings)
        }
    }

    /// The window at rest on the board's plan, with the pane open on History.
    func rig(history: HistoryModel, state: HistoryFaceState? = nil) async throws -> Rig {
        let model = AppModel(client: FakeCmmClient(plan: try TestPlans.fixture("plan-c.json")), now: { HistoryBoard.now })
        await model.scan()
        return Rig(
            model: model, window: WindowState(detailsOpen: true, face: .history), history: history, state: state ?? HistoryFaceState()
        )
    }

    /// The same, with a History model that has read this report.
    func rig(report: HistoryReport, state: HistoryFaceState? = nil) async throws -> Rig {
        let history = HistoryModel(fetch: { report })
        await history.load()
        return try await rig(history: history, state: state)
    }

    func rig(for scenario: Scenario) async throws -> Rig {
        let ninthOctober = HistoryBoard.runID(HistoryBoard.at(10, 9, 9, 41))
        let failure = CmmError.historyFailed(status: 1, stderr: "cmm: cannot read /Users/test/.local/state/cmm/history.jsonl")
        switch scenario {
        case .board:
            return try await rig(
                report: try HistoryBoard.report(),
                state: HistoryFaceState(expanded: [ninthOctober], pointerTime: HistoryBoard.at(10, 7, 15, 0))
            )
        case .firstRun:
            return try await rig(report: try HistoryBoard.report(runs: [], samples: []))
        case .fewSamples:
            return try await rig(report: try HistoryBoard.report(runs: [HistoryBoard.lanes], samples: HistoryBoard.fewSamples))
        case .gap:
            var rig = try await rig(
                report: try HistoryBoard.report(runs: [], samples: HistoryBoard.gapSamples, now: HistoryBoard.gapNow, freeNow: 21.6),
                state: HistoryFaceState(pointerTime: HistoryBoard.at(10, 4, 12, 0))
            )
            rig.env.now = { HistoryBoard.gapNow }
            return rig
        case .stopped:
            return try await rig(
                report: try HistoryBoard.report(runs: [HistoryBoard.stopped], samples: []),
                state: HistoryFaceState(expanded: [HistoryBoard.runID(HistoryBoard.at(10, 11, 16, 40))])
            )
        case .dockerOnly:
            return try await rig(
                report: try HistoryBoard.report(runs: [HistoryBoard.dockerOnly], samples: []),
                state: HistoryFaceState(expanded: [HistoryBoard.runID(HistoryBoard.at(10, 14, 14, 20))])
            )
        case .historyOff:
            var rig = try await rig(report: try HistoryBoard.report(), state: HistoryFaceState(expanded: [ninthOctober]))
            rig.settings = SettingsModel(
                settings: Settings(store: MemorySettingsStore([.historyEnabled: false])), loginItem: FakeLoginItem(),
                notifications: FakeNotificationPermission()
            )
            return rig
        case .reading, .readingAgain:
            let fake = FakeCmmClient(plans: [], histories: [.success(try HistoryBoard.report())])
            let history = HistoryModel(client: fake)
            if scenario == .readingAgain { await history.load() }
            let gate = fake.holdHistories()
            // the moment is over at once, so the picture shows what is said after it
            var rig = try await rig(history: history, state: HistoryFaceState(wait: { _ in }))
            rig.finish = { gate.open() }
            return rig
        case .readFailed, .readFailedAgain:
            let fake = FakeCmmClient(
                plans: [], histories: scenario == .readFailed ? [.failure(failure)] : [.success(try HistoryBoard.report()), .failure(failure)]
            )
            let history = HistoryModel(client: fake)
            await history.load()
            return try await rig(history: history)
        case .unreadable:
            return try await rig(report: try HistoryBoard.report(unreadable: 2))
        }
    }

    // MARK: tests

    func testEveryStateDrawsInLightAndDark() async throws {
        for scenario in Scenario.allCases {
            let rig = try await rig(for: scenario)
            let light = try await render(rig.view(), name: scenario.rawValue, appearance: .aqua)
            let dark = try await render(rig.view(), name: scenario.rawValue, appearance: .darkAqua)
            rig.finish()
            XCTAssertGreaterThan(distinctColors(light, in: Self.face), 8, "\(scenario) draws nothing in the pane in light mode")
            XCTAssertGreaterThan(distinctColors(dark, in: Self.face), 8, "\(scenario) draws nothing in the pane in dark mode")
            XCTAssertGreaterThan(brightness(light), 0.6, "\(scenario) is not light in light mode")
            XCTAssertLessThan(brightness(dark), 0.4, "\(scenario) is not dark in dark mode")
        }
    }

    func testIncreaseContrastDrawsToo() async throws {
        for scenario in [Scenario.board, .gap] {
            let rig = try await rig(for: scenario)
            let light = try await render(rig.view(), name: scenario.rawValue, appearance: .aqua, increasedContrast: true)
            let dark = try await render(rig.view(), name: scenario.rawValue, appearance: .darkAqua, increasedContrast: true)
            rig.finish()
            XCTAssertGreaterThan(distinctColors(light, in: Self.face), 8, "\(scenario)")
            XCTAssertGreaterThan(distinctColors(dark, in: Self.face), 8, "\(scenario)")
        }
    }

    func testEachStateIsWhatItClaims() async throws {
        func face(_ rig: Rig) -> HistoryPresentation? {
            rig.history.presentation(
                historyEnabled: rig.settings?.historyEnabled ?? true, now: rig.env.now(), calendar: HistoryBoard.calendar,
                locale: HistoryBoard.locale, home: "/Users/test"
            )
        }
        for scenario in Scenario.allCases {
            let rig = try await rig(for: scenario)
            defer { rig.finish() }
            let shown = face(rig)
            switch scenario {
            case .firstRun:
                XCTAssertEqual(shown?.emptyMessage, HistoryPresentation.emptyMessage)
                XCTAssertNil(shown?.summary)
            case .fewSamples:
                XCTAssertEqual(shown?.timeline?.caption, "History fills in as cmm runs: 3 days so far.")
                XCTAssertNotNil(shown?.timeline?.chart)
            case .gap:
                XCTAssertEqual(shown?.timeline?.chart?.gaps.count, 1)
                XCTAssertNotNil(shown?.emptyMessage, "a line and no cleaning")
            case .stopped:
                XCTAssertEqual(shown?.rows.weeks.first?.rows.first?.stoppedText, "Stopped after 2 of 9")
            case .dockerOnly:
                XCTAssertEqual(shown?.rows.weeks.first?.rows.first?.freedText, "0 GB freed")
                XCTAssertNil(shown?.summary, "nothing came back to the disk")
            case .historyOff:
                XCTAssertNil(shown?.timeline)
                XCTAssertEqual(shown?.summary, "Freed 44.0 GB in 3 cleanings since 29 Sep.")
            case .reading:
                XCTAssertNil(rig.history.report)
            case .readingAgain:
                XCTAssertNotNil(rig.history.report)
            case .readFailed:
                XCTAssertNil(rig.history.report)
                XCTAssertEqual(HistoryReadStatus(phase: rig.history.phase, showsReading: false),
                               .failed(sentence: "cmm could not read the history.", detail: "Exit status 1.\ncmm: cannot read /Users/test/.local/state/cmm/history.jsonl"))
            case .readFailedAgain:
                XCTAssertNotNil(rig.history.report)
            case .unreadable:
                XCTAssertEqual(shown?.rows.footnote, "2 lines of the history could not be read.")
            case .board:
                XCTAssertNotNil(shown?.timeline?.chart)
            }
        }
    }

    func testTheBoardsDataReadsAsTheBoardSaysIt() async throws {
        let rig = try await rig(for: .board)
        let face = try XCTUnwrap(rig.history.presentation(
            historyEnabled: true, now: HistoryBoard.now, calendar: HistoryBoard.calendar, locale: HistoryBoard.locale, home: "/Users/test"
        ))
        XCTAssertEqual(face.summary, "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago.")
        XCTAssertEqual(face.rows.weeks.map(\.title), ["This week", "Last week", "29 Sep \u{2013} 5 Oct"])
        XCTAssertEqual(face.rows.weeks.map(\.totalText), ["5.4 GB", "2.2 GB", "36.4 GB"])
        let rows = face.rows.weeks.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.dateText), ["Tue 14 Oct", "Tue 14 Oct", "Thu 9 Oct", "Mon 29 Sep"])
        XCTAssertEqual(rows.map(\.timeText), ["14:20", "14:06", "09:41", "10:02"])
        XCTAssertEqual(rows.map(\.freedText), ["0 GB freed", "5.4 GB freed", "2.2 GB freed", "36.4 GB freed"])
        guard rows.count == 4 else { return XCTFail("the board has four cleanings") }
        XCTAssertEqual(rows[0].insideText, "9.0 GB inside Docker's disk image, not counted")
        XCTAssertEqual(rows[1].groupsText, "Idle lane dependencies, uv cache, Go build cache")
        XCTAssertEqual(rows[2].failedText, "1 failed")
        XCTAssertEqual(rows[2].footnote, "Freed is what the disk got back: 17.0 \u{2192} 19.2 GB free.")
        XCTAssertEqual(rows[3].groupsText, "Unavailable simulators, idle lane dependencies, old CLI versions and 4 more")
        XCTAssertEqual(face.timeline?.chart?.gaps.map { $0.rangeText(calendar: HistoryBoard.calendar, locale: HistoryBoard.locale) },
                       ["Fri 3 \u{2013} Sun 5 Oct"])
    }
}
