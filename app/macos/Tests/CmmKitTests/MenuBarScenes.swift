import Foundation
import XCTest
@testable import CmmKit

/// The menu bar's seven states as the tests draw them and read them: the menu bar model told what each state needs (the boards'
/// numbers), and the window's phase at that moment.
@MainActor
enum MenuBarScenes {
    enum Shown: String, CaseIterable {
        case ready, nothingToClean, low, scanning, cleaning, justCleaned, unknown
    }

    /// Thursday 15 October 2026, 15:30 in Berlin (the window's boards' afternoon).
    static let now = BoardClock.now
    static let calendar = BoardClock.calendar
    static let british = Locale(identifier: "en_GB")

    static func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    /// A history with one cleaning: Tuesday's 5.4 GB, or one more than a week ago.
    static func history(lastCleaned: String = "2026-10-13T12:06:00Z") throws -> HistoryReport {
        var json = HistoryJSON()
        json.generatedAt = "2026-10-15T13:00:00Z"
        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":19800000000,"capacity_bytes":228000000000}"#
        json.runs = [HistoryJSON.run(finished: lastCleaned, freed: gb(5.4), before: gb(14.4))]
        return try json.report()
    }

    static func lowPlan() -> Plan {
        TestPlans.plan(
            [
                TestPlans.item("/Users/test/lane-builds/lane-a/node_modules", group: "Idle lane dependencies", rule: "lane-deps", bytes: gb(4.0)),
                TestPlans.item("/Users/test/lane-builds/lane-b/node_modules", group: "Idle lane dependencies", rule: "lane-deps", bytes: gb(2.1)),
                TestPlans.item("/Users/test/.cache/uv", group: "uv cache", rule: "uv-cache", bytes: gb(3.4)),
                TestPlans.item("/Users/test/Library/Caches/go-build", group: "Go build cache", rule: "go-build", bytes: gb(1.6)),
                TestPlans.item("/Users/test/.npm/_cacache", group: "npm cache", rule: "npm-cache", bytes: gb(1.2)),
                TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gb(9.0), tier: .review, action: .command, freesInside: "Docker's disk image"),
            ],
            freeBytes: gb(8.1), capacityBytes: gb(228)
        )
    }

    static func cleaned() -> CleanSummary {
        CleanSummary(
            done: DoneEvent(
                deleted: 7, skipped: 1, failed: 1, freedBytes: gb(5.4), freedInsideBytes: 0, freeBefore: gb(19.8), freeAfter: gb(25.2),
                stopped: false, warnings: [], log: nil
            ),
            items: [], unreadableLines: 0, reviewHeld: 0, finishedAt: now.addingTimeInterval(-600)
        )
    }

    /// The menu bar model told what the state needs, and the window's phase at that moment.
    static func scene(_ shown: Shown) throws -> (MenuBarPresentation, scanEnabled: Bool) {
        let clock = now
        let scanned = now.addingTimeInterval(-1_800)
        let scannedAt = Locked(scanned)
        let model = MenuBarModel(now: { scannedAt.withLock { $0 } }, calendar: calendar, sleep: { _ in })
        let phase: AppModel.Phase
        switch shown {
        case .ready:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            phase = .ready
        case .nothingToClean:
            model.recordHistory(try history())
            model.recordScan(TestPlans.plan([], freeBytes: gb(28.4), capacityBytes: gb(228)))
            phase = .empty
        case .low:
            model.recordHistory(try history(lastCleaned: "2026-10-07T08:41:00Z"))
            model.recordScan(lowPlan())
            phase = .ready
        case .scanning:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            phase = .scanning
        case .cleaning:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            phase = .cleaning
        case .justCleaned:
            model.recordHistory(try history())
            model.recordScan(try TestPlans.fixture("plan-c.json"))
            scannedAt.withLock { $0 = clock }
            model.recordCleaning(cleaned())
            phase = .done
        case .unknown:
            model.recordSample(SampleResult(recorded: true, t: nil, freeBytes: gb(19.8), capacityBytes: gb(228)), receivedAt: scanned)
            phase = .idle
        }
        scannedAt.withLock { $0 = clock }
        let presentation = model.presentation(
            phase: phase, confirmationOpen: false, volumeName: { _ in "Macintosh HD" }, calendar: calendar, locale: british
        )
        let enabled = MenuBarModel.scanEnabled(presentation.popover, phase: phase, confirmationOpen: false, mainWindowOpen: false)
        return (presentation, enabled)
    }

}
