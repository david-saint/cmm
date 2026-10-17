import UserNotifications
import XCTest
@testable import CmmKit

/// The weekly note (the board `C-Notification`): what it says on the board's three Mondays, and that a click on it, the one thing
/// a person can do with it, is what opens the window.
final class NotificationTests: XCTestCase {
    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }
    private let planner = WeeklyPlanner(calendar: TestCalendars.rome)

    private func plan(free: Double, safe: [Double], docker: Double = 0) -> Plan {
        var items = safe.enumerated().map { TestPlans.item("/Users/test/safe\($0.offset)", rule: "r\($0.offset)", bytes: gb($0.element)) }
        if docker > 0 {
            items.append(TestPlans.item("docker: unused images", group: "Docker", rule: "docker", bytes: gb(docker), tier: .review, action: .command, freesInside: "Docker's disk image"))
        }
        return TestPlans.plan(items, freeBytes: gb(free), capacityBytes: gb(228))
    }

    func testTheBoardsThreeMondays() throws {
        guard case .notify(let weekly) = planner.outcome(for: try TestPlans.fixture("plan-c.json")) else { return XCTFail("8.4 GB can go") }
        XCTAssertEqual(weekly.title, "19.8 GB free")
        XCTAssertEqual(weekly.body, "8 GB can go.")

        guard case .notify(let low) = planner.outcome(for: plan(free: 8.1, safe: [6.1, 3.4, 1.6, 1.2], docker: 9)) else { return XCTFail("low") }
        XCTAssertEqual(low.title, "Only 8.1 GB free", "Only carries what the amber dot carries in the menu bar")
        XCTAssertEqual(low.body, "12 GB can go.", "whole gigabytes, rounded down, Docker's never counted")

        XCTAssertEqual(planner.outcome(for: plan(free: 28.4, safe: [], docker: 9)), .quiet, "nothing can go: no note at all")
    }

    func testTheBoardsWordingBetweenTenAndFifteenAndUnderOneGigabyte() {
        guard case .notify(let between) = planner.outcome(for: plan(free: 13.6, safe: [1.2])) else { return XCTFail("under 15 GB free") }
        XCTAssertEqual(between.title, "13.6 GB free", "the normal words from 10 to 15 GB")
        XCTAssertEqual(between.body, "1 GB can go.")
        guard case .notify(let small) = planner.outcome(for: plan(free: 13.6, safe: [0.4])) else { return XCTFail("something can go") }
        XCTAssertEqual(small.body, "Under 1 GB can go.", "never 0 GB")
        XCTAssertEqual(planner.outcome(for: plan(free: 40, safe: [1.5])), .quiet, "less than 2 GB with room to spare says nothing")
    }

    func testEveryWeeksNoteHasTheSameIdentifierSoItReplacesTheLast() {
        let notes = [(19.8, 8.4), (8.1, 12.3), (13.6, 1.2)].compactMap { WeeklyNotification(free: gb($0.0), canGo: gb($0.1)) }
        XCTAssertEqual(Set(notes.map(\.identifier)), [WeeklyNotification.identifier])
        XCTAssertTrue(notes.allSatisfy { $0.level == .active }, "interruption level active, never time sensitive")
    }

    // MARK: the click

    func testTheClickIsTheSystemsOwnDefaultAction() {
        XCTAssertEqual(NotificationClick.defaultAction, UNNotificationDefaultActionIdentifier)
    }

    func testOnlyAClickOnTheWeeklyNoteOpensTheWindow() {
        XCTAssertTrue(NotificationClick.opensWindow(identifier: WeeklyNotification.identifier, action: UNNotificationDefaultActionIdentifier))
        XCTAssertFalse(NotificationClick.opensWindow(identifier: WeeklyNotification.identifier, action: UNNotificationDismissActionIdentifier))
        XCTAssertFalse(NotificationClick.opensWindow(identifier: "someone.else", action: UNNotificationDefaultActionIdentifier))
    }
}
