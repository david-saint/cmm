import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The Settings window (the board `C-Settings`, spec R8): exactly four switches with the board's sentences, the reminder's
/// pickers, the two places in System Settings, what is said when macOS will not show the reminder, and the window drawn in light
/// and dark.
@MainActor
final class SettingsViewTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")

    // MARK: the words

    func testExactlyFourSwitchesWithTheBoardsSentences() {
        XCTAssertEqual(SettingsCopy.switches.map(\.title), ["Show in the menu bar", "Open at login", "Weekly reminder", "Keep a free-space history"])
        XCTAssertEqual(SettingsCopy.menuBar.detail.text, "Free space next to the clock; click it to see what can go.")
        XCTAssertEqual(
            SettingsCopy.openAtLogin.detail.text,
            "Starts cmm when you log in, so the menu bar item, the reminder and the history keep working. You can also turn it off in System Settings > General > Login Items."
        )
        XCTAssertEqual(
            SettingsCopy.reminder.detail.text,
            "A notification once a week, only when at least 2 GB can go, or when free space is under 15 GB and something can go."
        )
        XCTAssertEqual(SettingsCopy.reminderSilence.text, "macOS can also silence it in System Settings > Notifications > cmm.")
        XCTAssertEqual(SettingsCopy.history.detail.text, "Records one number every 30 minutes, nothing else.")
    }

    func testThePlacesInSystemSettingsAreLinksToThem() {
        XCTAssertEqual(SettingsCopy.openAtLogin.detail.destination, .loginItems)
        XCTAssertEqual(SettingsCopy.openAtLogin.detail.link, "System Settings > General > Login Items")
        XCTAssertEqual(SettingsCopy.reminderSilence.destination, .notifications)
        XCTAssertEqual(SettingsCopy.reminderSilenced.destination, .notifications)
        for destination in [SettingsCopy.Destination.loginItems, .notifications] {
            XCTAssertEqual(SettingsCopy.Destination(url: destination.url), destination, "a link finds its way back")
        }
        XCTAssertEqual(SettingsCopy.Destination.notifications.url.scheme, "x-apple.systempreferences", "the system's own address for the pane")
        XCTAssertNil(SettingsCopy.Destination(url: URL(string: "https://example.com")!), "the window opens nothing else")
    }

    func testTheSilencedLineIsOneShortSentenceThatSaysWhereToChangeIt() {
        let line = SettingsCopy.reminderSilenced
        XCTAssertEqual(line.text, "Notifications are off for cmm in System Settings > Notifications.")
        XCTAssertLessThanOrEqual(line.text.count, 72, "one line at the row's width")
    }

    func testTheWeekdaysStartWhereThePersonsWeekStartsAndKeepTheCalendarsNumbers() {
        let monday = SettingsCopy.weekdays(calendar: TestCalendars.make("Europe/Rome", firstWeekday: 2), locale: british)
        XCTAssertEqual(monday.map(\.title), ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"])
        XCTAssertEqual(monday.map(\.value), [2, 3, 4, 5, 6, 7, 1])
        let sunday = SettingsCopy.weekdays(calendar: TestCalendars.make("America/New_York", firstWeekday: 1), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(sunday.first?.title, "Sunday")
        XCTAssertEqual(sunday.first?.value, 1)
    }

    func testTheTimesAreEveryHalfHourInThePersonsOwnWayAndKeepAnOddOne() {
        let times = SettingsCopy.times(chosen: 600, calendar: TestCalendars.rome, locale: british)
        XCTAssertEqual(times.count, 48)
        XCTAssertEqual(times.first { $0.minuteOfDay == 600 }?.title, "10:00")
        XCTAssertEqual(times.first?.title, "00:00")
        let american = SettingsCopy.times(chosen: 600, calendar: TestCalendars.make("America/New_York", firstWeekday: 1), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(american.first { $0.minuteOfDay == 600 }?.title.replacingOccurrences(of: "\u{202F}", with: " "), "10:00 AM")
        let odd = SettingsCopy.times(chosen: 605, calendar: TestCalendars.rome, locale: british)
        XCTAssertEqual(odd.count, 49, "a time set some other way is still shown")
        XCTAssertEqual(odd.map(\.minuteOfDay), odd.map(\.minuteOfDay).sorted())
        XCTAssertEqual(odd.first { $0.minuteOfDay == 605 }?.title, "10:05")
    }

    // MARK: the window

    private struct Rig {
        let settings: SettingsModel
        let store: MemorySettingsStore
        let login: FakeLoginItem
        let permission: FakeNotificationPermission
    }

    private func rig(
        _ values: [SettingsKey: Any] = [.menuBarEnabled: true, .weeklyReminderEnabled: true, .historyEnabled: true, .optInAnswered: true],
        login: LoginItemState = .on, notifications: NotificationAuthorization = .allowed
    ) -> Rig {
        let store = MemorySettingsStore(values)
        let loginItem = FakeLoginItem(login)
        let permission = FakeNotificationPermission(notifications)
        return Rig(
            settings: SettingsModel(settings: Settings(store: store), loginItem: loginItem, notifications: permission),
            store: store, login: loginItem, permission: permission
        )
    }

    private func view(_ rig: Rig, openLoginItems: @escaping () -> Void = {}) -> some View {
        SettingsView(settings: rig.settings, openLoginItems: openLoginItems, calendar: TestCalendars.rome, locale: british)
    }

    func testTheWindowIsTheBoardsWidthAndTallEnoughForEveryRow() {
        let hosting = NSHostingView(rootView: view(rig()))
        XCTAssertEqual(hosting.fittingSize.width, SettingsView.width, accuracy: 0.5)
        XCTAssertGreaterThan(hosting.fittingSize.height, 300, "the four rows, as the form lays them out")
        XCTAssertLessThan(hosting.fittingSize.height, 600)
    }

    func testTheWindowDrawsInLightAndDarkAndInItsOtherStates() async throws {
        let cases: [(String, Rig)] = [
            ("settings", rig()),
            ("settings-off", rig([.optInAnswered: true], login: .off, notifications: .notAsked)),
            ("settings-silenced", rig(notifications: .denied)),
            ("settings-approval", rig(login: .needsApproval)),
        ]
        for (name, rig) in cases {
            await rig.settings.refresh()
            let size = NSHostingView(rootView: view(rig)).fittingSize
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let bitmap = try SystemRendering.render(view(rig), size: size, appearance: appearance, name: name)
                XCTAssertGreaterThan(SystemRendering.distinctColors(bitmap), 8, "\(name) looks blank")
                if appearance == .aqua {
                    XCTAssertGreaterThan(SystemRendering.brightness(bitmap), 0.6, "\(name) is not light")
                } else {
                    XCTAssertLessThan(SystemRendering.brightness(bitmap), 0.4, "\(name) is not dark")
                }
            }
        }
    }

    func testTheSystemsStateIsReadWhenTheWindowAppears() async throws {
        let rig = rig(login: .on, notifications: .denied)
        XCTAssertEqual(rig.settings.notifications, .notAsked, "not read before")
        let hosting = NSHostingView(rootView: view(rig).frame(width: SettingsView.width, height: 500))
        let window = OffscreenWindow(size: CGSize(width: SettingsView.width, height: 500))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }
        await eventuallyOnMain(timeout: 3) { rig.settings.notifications == .denied }
        XCTAssertEqual(rig.settings.notifications, .denied)
        XCTAssertTrue(rig.settings.reminderIsSilenced)
        XCTAssertEqual(rig.permission.requestCalls, 0, "reading is not asking")

        // the person changes it in System Settings and comes back
        rig.permission.current = .allowed
        rig.login.state = .off
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await eventuallyOnMain(timeout: 3) { rig.settings.notifications == .allowed && rig.settings.openAtLogin == .off }
        XCTAssertEqual(rig.settings.openAtLogin, .off)
        XCTAssertEqual(rig.store.writes.filter { $0.contains("login") || $0.contains("otification") }, [], "the system's state is never kept")
    }
}
