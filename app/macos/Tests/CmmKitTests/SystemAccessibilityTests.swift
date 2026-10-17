import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The menu bar item, its popover, the one-time card and Settings as VoiceOver and the keyboard find them (spec R11): one sentence
/// for the top of the popover, a label on every control, presses that do what clicks do, Esc that closes the popover and nothing
/// else, and Reduce Motion that stops the spinner.
///
/// Tab is not exercised: without Full Keyboard Access (off on the Mac that ran these tests, and a setting of the person's that a
/// test must not change) macOS takes no button into the keyboard loop. What Tab would reach is what is checked here: every control
/// is an enabled, labelled accessibility element.
@MainActor
final class SystemAccessibilityTests: XCTestCase {
    final class Pressed {
        var actions: [MenuBarAction] = []
    }

    private func popover(_ shown: MenuBarScenes.Shown, pressed: Pressed) async throws -> HostedForAccessibility {
        let (presentation, enabled) = try MenuBarScenes.scene(shown)
        let view = MenuBarPopoverView(presentation: presentation, scanEnabled: enabled, perform: { pressed.actions.append($0) })
        return await HostedForAccessibility(view, size: CGSize(width: 320, height: 420), test: self)
    }

    // MARK: the popover

    func testTheTopOfThePopoverIsOneSentenceThatSaysTheNumberFirst() async throws {
        let ready = try await popover(.ready, pressed: Pressed())
        XCTAssertNotNil(ready.root.find(label: "8.4 GB can go. 19.8 GB free."), "\(ready.root.labels)")
        let cleaned = try await popover(.justCleaned, pressed: Pressed())
        XCTAssertNotNil(cleaned.root.find(label: "Freed 5.4 GB. 25.2 GB free."), "the board's order: \(cleaned.root.labels)")
        let low = try await popover(.low, pressed: Pressed())
        XCTAssertNotNil(low.root.find(label: "Low on space. 12.3 GB can go. 8.1 GB free."), "the dot is said in words: \(low.root.labels)")
        XCTAssertNil(ready.root.find(label: "8.4"), "the number is not read twice")
    }

    func testTheGroupsAreReadAsANameAndASize() async throws {
        let hosted = try await popover(.ready, pressed: Pressed())
        for label in ["Idle lane dependencies, 3.6 GB", "uv cache, 2.5 GB", "Go build cache, 1.2 GB"] {
            XCTAssertNotNil(hosted.root.find(label: label), "\(label) in \(hosted.root.labels)")
        }
    }

    func testEveryControlHasALabelAndAPressIsTheClick() async throws {
        let pressed = Pressed()
        let hosted = try await popover(.ready, pressed: pressed)
        let buttons = hosted.root.all { $0.role == "AXButton" || $0.role == "AXPopUpButton" || $0.role == "AXMenuButton" }
        XCTAssertGreaterThanOrEqual(buttons.count, 4, "\(buttons.map { "\($0.role) \($0.label)" })")
        XCTAssertTrue(buttons.allSatisfy { !$0.label.isEmpty }, "every control is labelled: \(buttons.map(\.label))")
        for (label, action) in [("Scan", MenuBarAction.scan), ("Last cleaned Tue, 5.4 GB", .openHistory), ("Open cmm", .openWindow)] {
            let node = try XCTUnwrap(hosted.root.find(label: label), "\(label) in \(hosted.root.labels)")
            XCTAssertTrue(node.press(), label)
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(pressed.actions.last, action, label)
        }
        XCTAssertNotNil(hosted.root.find(label: "More"), "the ... menu")
    }

    func testNothingInThePopoverOffersToClean() async throws {
        for shown in MenuBarScenes.Shown.allCases {
            let hosted = try await popover(shown, pressed: Pressed())
            let controls = hosted.root.all { ["AXButton", "AXPopUpButton", "AXMenuButton", "AXLink"].contains($0.role) }
            XCTAssertFalse(controls.isEmpty, "\(shown)")
            for control in controls {
                for words in [control.label, control.help] {
                    XCTAssertFalse(words.contains("Clean") || words.contains("Delete") || words.contains("Remove"), "\(shown): \(words)")
                }
            }
        }
    }

    func testScanIsOffWhileItScansAndAPressDoesNothing() async throws {
        let pressed = Pressed()
        let hosted = try await popover(.scanning, pressed: pressed)
        let scan = try XCTUnwrap(hosted.root.find(label: "Scanning"), "\(hosted.root.labels)")
        XCTAssertFalse(scan.isEnabled)
        scan.press()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pressed.actions, [])
    }

    // MARK: the keyboard

    func testEscClosesThePopoverAndDoesNothingElse() async throws {
        let pressed = Pressed()
        let hosted = try await popover(.ready, pressed: pressed)
        XCTAssertTrue(hosted.window.isVisible)
        await hosted.press(keyCode: 53, characters: "\u{1B}", modifiers: [.command])
        XCTAssertTrue(hosted.window.isVisible, "⌘Esc is somebody else's")
        await hosted.press(keyCode: 53, characters: "\u{1B}")
        XCTAssertFalse(hosted.window.isVisible, "Esc closes the popover")
        XCTAssertEqual(pressed.actions, [], "and asks for nothing")
    }

    func testOpeningTheWindowOrHistoryFromThePopoverPutsThePopoverAway() async throws {
        for (label, action) in [("Open cmm", MenuBarAction.openWindow), ("Last cleaned Tue, 5.4 GB", .openHistory)] {
            let pressed = Pressed()
            let hosted = try await popover(.ready, pressed: pressed)
            try XCTUnwrap(hosted.root.find(label: label)).press()
            try? await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(pressed.actions, [action])
            XCTAssertFalse(hosted.window.isVisible, "\(label): the popover went away")
        }
        let pressed = Pressed()
        let hosted = try await popover(.ready, pressed: pressed)
        try XCTUnwrap(hosted.root.find(label: "Scan")).press()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(hosted.window.isVisible, "Scan stays, to show it scanning")
    }

    // MARK: motion

    func testTheSpinnerHoldsStillWithReduceMotion() throws {
        let (presentation, enabled) = try MenuBarScenes.scene(.scanning)
        func picture() throws -> NSBitmapImageRep {
            try SystemRendering.render(
                MenuBarPopoverView(presentation: presentation, scanEnabled: enabled, perform: { _ in })
                    .environment(\._accessibilityReduceMotion, true),
                size: CGSize(width: 320, height: 300), appearance: .aqua
            )
        }
        let first = try picture()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let second = try picture()
        XCTAssertEqual(first.tiffRepresentation, second.tiffRepresentation, "nothing turned")
    }

    // MARK: the item

    func testTheItemSaysTheFreeSpaceAndLowInWords() async throws {
        let low = MenuBarItem(title: "8.1 GB", isLow: true, accessibilityLabel: "8.1 GB free, low on space")
        let hosted = await HostedForAccessibility(MenuBarLabel(item: low), size: CGSize(width: 120, height: 24), test: self)
        XCTAssertNotNil(hosted.root.find(label: "8.1 GB free, low on space"), "\(hosted.root.labels)")
        XCTAssertNil(hosted.root.find(label: "8.1 GB"), "read once, as one sentence")
    }

    // MARK: the one-time card

    func testTheCardIsAGroupWithItsQuestionAndTwoLabelledButtons() async throws {
        let store = MemorySettingsStore()
        let settings = SettingsModel(settings: Settings(store: store), loginItem: FakeLoginItem(), notifications: FakeNotificationPermission())
        let card = OptInCard(turnOn: { Task { await settings.turnOnEverything() } }, notNow: { settings.declineOptIn() })
        let hosted = await HostedForAccessibility(card.padding(20), size: CGSize(width: 360, height: 240), test: self)
        XCTAssertNotNil(hosted.root.find(label: "Keep an eye on your disk?"))
        let turnOn = try XCTUnwrap(hosted.root.find(label: "Turn on"))
        XCTAssertTrue(turnOn.help.contains("menu bar") && turnOn.help.contains("login"), "the hint names what it switches on: \(turnOn.help)")
        try XCTUnwrap(hosted.root.find(label: "Not now")).press()
        await eventuallyOnMain(timeout: 3) { settings.optInAnswered }
        XCTAssertTrue(settings.optInAnswered)
        XCTAssertFalse(settings.menuBarEnabled)
    }

    // MARK: Settings

    private func settingsWindow() async -> (HostedForAccessibility, SettingsModel, Locked<Int>) {
        let store = MemorySettingsStore([.optInAnswered: true, .weeklyReminderEnabled: true])
        let settings = SettingsModel(settings: Settings(store: store), loginItem: FakeLoginItem(), notifications: FakeNotificationPermission(.allowed))
        let opened = Locked(0)
        let view = SettingsView(
            settings: settings, openLoginItems: { opened.withLock { $0 += 1 } }, calendar: TestCalendars.rome, locale: Locale(identifier: "en_GB")
        )
        let hosted = await HostedForAccessibility(view, size: CGSize(width: SettingsView.width, height: 460), test: self)
        return (hosted, settings, opened)
    }

    func testTheFourSwitchesAreLabelledByTheirTitlesAndSayTheirSentence() async throws {
        let (hosted, settings, _) = await settingsWindow()
        func control(_ label: String) throws -> AXNode {
            let found = hosted.root.all { $0.label == label && $0.role != "AXStaticText" }
            return try XCTUnwrap(found.first, "\(label): \(hosted.root.all { $0.label == label }.map(\.role))")
        }
        for copy in SettingsCopy.switches {
            let node = try control(copy.title)
            XCTAssertEqual(node.role, "AXCheckBox", "\(copy.title) is a switch")
            XCTAssertEqual(node.help, copy.detail.text, copy.title)
        }
        XCTAssertEqual(try control("Weekday").role, "AXPopUpButton")
        XCTAssertEqual(try control("Time").role, "AXPopUpButton")

        // a click on a switch, where the accessibility tree says it is, switches it
        await hosted.click(try control("Show in the menu bar"))
        await eventuallyOnMain(timeout: 3) { settings.menuBarEnabled }
        XCTAssertTrue(settings.menuBarEnabled, "the switch found by its label is the one that switches the menu bar item")
        await hosted.click(try control("Keep a free-space history"))
        await eventuallyOnMain(timeout: 3) { settings.historyEnabled }
        XCTAssertTrue(settings.historyEnabled)
        XCTAssertEqual(try control("Show in the menu bar").value, "1", "and VoiceOver hears it is on")
    }
}
