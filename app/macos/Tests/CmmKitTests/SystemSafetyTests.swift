import XCTest
@testable import CmmKit

/// The tripwires of the second phase's system side (the menu bar item, Settings, the one-time card, the notification, the
/// background services and the lifecycle), in a file of their own so that the first milestone's (`SafetyRulesTests`) and the
/// first phase's (`BackgroundSafetyTests`) stay as they were.
///
/// They read the app's own source, as those do, and are blunt on purpose: when one trips, read the rule, then change the check
/// together with a reason. What they pin: the system's own services are reached through one thin adaptor each, which no test
/// ever makes (so no test can touch the person's login items, notifications or preferences); and the parts that run when the
/// window is closed can look and say, and never clean.
@MainActor
final class SystemSafetyTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CmmKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app/macos

    struct SourceFile {
        let name: String
        let raw: String
        /// Without `//` comments.
        let code: String
    }

    static func files(in folder: String) throws -> [SourceFile] {
        let url = packageRoot.appendingPathComponent(folder)
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "no sources found in \(url.path): these checks would pass for the wrong reason")
        return try urls.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            return SourceFile(name: url.lastPathComponent, raw: text, code: strippingComments(text))
        }
    }

    static func sources() throws -> [SourceFile] {
        try files(in: "Sources/CmmKit") + files(in: "Sources/Cmm")
    }

    static func source(_ name: String) throws -> SourceFile {
        try XCTUnwrap(try sources().first { $0.name == name }, name)
    }

    /// Drops `// ...` comments (not inside string literals).
    static func strippingComments(_ text: String) -> String {
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

    static func matches(_ pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (text as NSString).substring(with: match.range(at: match.numberOfRanges > 1 ? 1 : 0))
        }
    }

    /// The files that pin tokens as strings: they name what they forbid.
    static let tripwireFiles: Set<String> = ["SafetyRulesTests.swift", "BackgroundSafetyTests.swift", "SystemSafetyTests.swift"]

    // MARK: the system's services, through one adaptor each

    /// Each of the system's services that can change something of the person's (login items, notifications, what the system runs
    /// in the background, the launch's Apple event) is named in one file of the app and nowhere else.
    func testTheSystemsOwnServicesAreReachedOnlyThroughTheirAdaptors() throws {
        let files = try Self.sources()
        let homes: [String: String] = [
            "SMAppService": "SystemAdaptors.swift",
            "NSAppleEventManager": "SystemAdaptors.swift",
            "UNUserNotificationCenter": "SystemNotifications.swift",
            "UNMutableNotificationContent": "SystemNotifications.swift",
            "NSBackgroundActivityScheduler": "SystemSchedulers.swift",
            "DispatchWallTime": "SystemSchedulers.swift",
        ]
        for (token, home) in homes {
            XCTAssertEqual(files.filter { $0.code.contains(token) }.map(\.name), [home], "`\(token)` is used outside \(home)")
        }
        for (framework, home) in ["import ServiceManagement": "SystemAdaptors.swift", "import UserNotifications": "SystemNotifications.swift"] {
            XCTAssertEqual(files.filter { $0.code.contains(framework) }.map(\.name), [home], "`\(framework)` outside \(home)")
        }
    }

    /// No test makes the services of the running app or one of the real adaptors, and no test names the system's services: every
    /// test runs against fakes, so none can touch the person's login items, notifications or preferences.
    func testNoTestMakesTheRealAdaptorsOrTheAppsServices() throws {
        let tests = try Self.files(in: "Tests/CmmKitTests").filter { !Self.tripwireFiles.contains($0.name) }
        XCTAssertGreaterThan(tests.count, 20, "the tests were found")
        for token in [
            "AppServices", "SystemLoginItem", "SystemNotificationPermission", "AppleEventLaunchSource", "SystemBundle",
            "SystemNotificationPoster", "SystemActivityScheduler", "SystemWallClock",
            "SMAppService", "UNUserNotificationCenter", "NSBackgroundActivityScheduler", "NSAppleEventManager",
            "UserDefaults", "Settings.standard", "UserDefaultsSettingsStore", "FacePreference",
        ] {
            XCTAssertEqual(tests.filter { $0.code.contains(token) }.map(\.name), [], "a test uses `\(token)`")
        }
    }

    // MARK: the background

    /// The reminder's scan is the window's own and nothing else: it reads the window's phase, card and plan, and asks it to scan.
    /// The background services hold no model and no client: they start and stop the sampler and the reminder, nothing more.
    func testTheReminderOnlyScansAndTheBackgroundHoldsNoWayToClean() throws {
        let scan = try Self.source("WeeklyScan.swift").code
        let asked = Set(try Self.matches(#"model\.(\w+)"#, in: scan))
        XCTAssertEqual(asked, ["phase", "confirmation", "plan", "scan"], "the reminder's scan asks the window for \(asked.sorted())")
        let background = try Self.source("BackgroundServices.swift").code
        for token in ["AppModel", "model.", "CmmClient", "client", "Clean", "confirm", "toggle"] {
            XCTAssertFalse(background.contains(token), "BackgroundServices uses `\(token)`")
        }
        XCTAssertEqual(Set(try Self.matches(#"sampler\.(\w+)"#, in: background)), ["start", "stop", "trigger"])
        XCTAssertEqual(Set(try Self.matches(#"reminder\.(\w+)"#, in: background)), ["check", "nextCheck"])
        // the identifiers the system schedules them under, one each
        let app = try Self.source("CmmApp.swift").code + (try Self.source("AppServices.swift").code)
        XCTAssertTrue(app.contains("SystemActivityScheduler(identifier: \"com.davidsaint.cmm.sampler\")"))
        XCTAssertTrue(app.contains("SystemActivityScheduler(identifier: \"com.davidsaint.cmm.weekly\")"))
    }

    // MARK: the lifecycle

    /// What the services ask of the window's model: to read its phase and its card, to scan when the window first opens (as
    /// before), to stop a cleaning and to cancel the card when the window closes, and to stop what runs when the app quits.
    /// Never to ask for a cleaning, to confirm one, or to tick.
    func testTheLifecycleOnlyStopsCancelsAndScansAsBefore() throws {
        for name in ["AppServices.swift", "CmmApp.swift"] {
            let code = try Self.source(name).code
            let asked = Set(try Self.matches(#"model\??\.(\w+)"#, in: code))
            XCTAssertTrue(
                asked.isSubset(of: ["phase", "confirmation", "scan", "stop", "cancelClean", "shutdown"]),
                "\(name) asks the model for \(asked.sorted())"
            )
            for token in ["confirmClean", "requestClean", "toggle("] {
                XCTAssertFalse(code.contains(token), "\(name) uses `\(token)`")
            }
        }
        let services = try Self.source("AppServices.swift").code
        XCTAssertTrue(services.contains("case .stopCleaning: model.stop()"), "closing the window asks a cleaning to stop, as Stop does")
        XCTAssertTrue(services.contains("case .cancelConfirmation: model.cancelClean()"))
        XCTAssertFalse(services.contains("model.shutdown()"), "closing a window is not quitting: a scan is left to finish")
        let app = try Self.source("CmmApp.swift").code
        XCTAssertTrue(app.contains("services?.model.shutdown()"), "quitting stops what runs, as before")
        XCTAssertTrue(app.contains("services?.lifecycle.terminatesAfterLastWindowClosed ?? true"), "the menu bar switch decides whether closing quits")
    }

    // MARK: the menu bar item

    /// The popover and the item can look, open the window or Settings, and quit; nothing in their files can ask for a cleaning
    /// (spec R5, R10: "the popover never offers Clean"), whatever a comment says.
    func testThePopoverAndTheItemHaveNoWayToClean() throws {
        let files = try Self.files(in: "Sources/Cmm").filter { $0.name.hasPrefix("MenuBar") }
        XCTAssertEqual(files.map(\.name), ["MenuBarLabel.swift", "MenuBarPopoverView.swift", "MenuBarScene.swift"])
        for file in files {
            for token in ["requestClean", "confirmClean", "cancelClean", "apply", "toggle(", "Clean", "Delete"] {
                XCTAssertFalse(file.raw.contains(token), "\(file.name) mentions `\(token)`")
            }
            XCTAssertFalse(file.code.contains("model."), "\(file.name) reaches the window's model itself")
        }
        // every action the popover can take is one of the five, and each one goes to a named place
        let scene = try Self.source("MenuBarScene.swift").code
        for line in [
            "case .scan: services.scanFromMenuBar()", "case .openWindow: services.openMainWindow()",
            "case .openHistory: services.openHistory()", "case .openSettings: services.openSettings(openSettings)",
            "case .quit: NSApp.terminate(nil)",
        ] {
            XCTAssertTrue(scene.contains(line), "the popover's action is wired as `\(line)`")
        }
        XCTAssertEqual(scene.components(separatedBy: "case .").count - 1, 5)
        // and its Scan is the window's own scan, asked again at the moment of the click
        let services = try Self.source("AppServices.swift").code
        let scan = try XCTUnwrap(services.range(of: "func scanFromMenuBar()"))
        let body = services[scan.upperBound...].prefix(240)
        XCTAssertTrue(body.contains("guard menuBarScanEnabled(menuBarPresentation()) else { return }"))
        XCTAssertTrue(body.contains("Task { await model.scan() }"))
    }

    // MARK: the weekly note

    /// What macOS is handed is the note as `WeeklyNotification` wrote it, and nothing else: its title and body (made of two numbers,
    /// never a path, a group or Docker), its one identifier, interruption level active, no sound, no buttons, no category, no
    /// extra data, delivered now.
    func testTheNoteIsPostedAsWrittenWithNoButtonsAndNoCategory() throws {
        let adaptor = try Self.source("SystemNotifications.swift").code
        let post = try XCTUnwrap(adaptor.range(of: "func post(_ note: WeeklyNotification) async {"))
        let end = try XCTUnwrap(adaptor[post.upperBound...].range(of: "\n    }\n"))
        let body = String(adaptor[post.upperBound..<end.lowerBound])
        XCTAssertEqual(Set(try Self.matches(#"content\.(\w+) ="#, in: body)), ["title", "body", "interruptionLevel"])
        XCTAssertTrue(body.contains("content.title = note.title"))
        XCTAssertTrue(body.contains("content.body = note.body"))
        XCTAssertTrue(body.contains("UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)"), "now, under its one identifier")
        XCTAssertTrue(adaptor.contains("case .active: .active"))
        let files = try Self.sources()
        for token in [
            "UNNotificationCategory", "UNNotificationAction", "UNTextInputNotificationAction", "setNotificationCategories",
            "categoryIdentifier", "timeSensitive", ".critical", "UNNotificationSound", "UNTimeIntervalNotificationTrigger",
            "UNCalendarNotificationTrigger",
        ] {
            XCTAssertEqual(files.filter { $0.code.contains(token) }.map(\.name), [], "`\(token)` is used")
        }
        for token in ["userInfo", "subtitle", "attachments", "threadIdentifier", "sound", "badge"] {
            XCTAssertFalse(adaptor.contains(token), "the notification adaptor uses `\(token)`")
        }
    }

    /// The note is shown even when cmm is in front, and a click on it (and nothing else that comes back) opens the window at rest.
    func testAClickOnTheNoteOpensTheWindowAtRestAndNothingElseDoes() throws {
        let adaptor = try Self.source("SystemNotifications.swift").code
        XCTAssertTrue(adaptor.contains("[.banner, .list]"))
        XCTAssertTrue(adaptor.contains("guard NotificationClick.opensWindow(identifier: response.notification.request.identifier, action: response.actionIdentifier) else {"))
        XCTAssertTrue(adaptor.contains("UNUserNotificationCenter.current().delegate = handler"))
        let services = try Self.source("AppServices.swift").code
        XCTAssertTrue(services.contains("notificationClicks = NotificationClickHandler.install { [weak self] in self?.openMainWindow() }"))
        let app = try Self.source("CmmApp.swift").code
        XCTAssertTrue(app.contains("func applicationWillFinishLaunching(_ notification: Notification) {\n        services?.willFinishLaunching()"),
                      "installed before the launch's own events, so a click that launched cmm is not lost")
    }

    // MARK: Settings and the permission

    /// macOS is asked about notifications in one place: the settings model's reminder switch (which the card's Turn on goes
    /// through). The system's question is put by one adaptor, from that one method; nothing else asks, and nothing asks at launch.
    func testMacOSIsAskedAboutNotificationsOnlyFromTheSettingsModel() throws {
        let files = try Self.sources()
        XCTAssertEqual(files.filter { $0.code.contains("requestAuthorization") }.map(\.name), ["SystemNotifications.swift"])
        let adaptor = try Self.source("SystemNotifications.swift").code
        XCTAssertEqual(adaptor.components(separatedBy: "requestAuthorization").count - 1, 1)
        let request = try XCTUnwrap(adaptor.range(of: "func request() async -> NotificationAuthorization {"))
        let asking = try XCTUnwrap(adaptor.range(of: "requestAuthorization"))
        XCTAssertTrue(request.upperBound <= asking.lowerBound, "the question is put inside `request()`")
        // `request()` of the permission is called by the settings model alone
        let callers = files.filter { $0.code.range(of: #"(permission|notifications)\.request\(\)"#, options: .regularExpression) != nil }
        XCTAssertEqual(callers.map(\.name), ["Settings.swift"])
        XCTAssertFalse(adaptor.contains(".sound") || adaptor.contains(".badge") || adaptor.contains("timeSensitive"), "banners only, never time sensitive")
    }

    /// Nothing is switched on, and macOS is not asked about notifications, except by the person: through the one-time card's two
    /// answers and Settings' own switches (and the menu bar item's binding, which the system sets when the person takes the item
    /// out of the menu bar). The app's services, the menu bar and the background read the switches and never set them, so a
    /// launch can turn nothing on and cannot put macOS's question. (The review's mutants that turned everything on at launch,
    /// or asked through the reminder's switch at launch, were caught by nothing before this check.)
    func testOnlyThePersonSwitchesThingsOnOrHasMacOSAsked() throws {
        let files = try Self.sources().filter { $0.name != "Settings.swift" }
        func callers(_ call: String) -> [String] { files.filter { $0.code.contains(call) }.map(\.name) }
        XCTAssertEqual(callers("turnOnEverything("), ["OptInCard.swift"])
        XCTAssertEqual(callers("declineOptIn("), ["OptInCard.swift"])
        XCTAssertEqual(callers("setWeeklyReminder("), ["SettingsView.swift"])
        XCTAssertEqual(callers("setOpenAtLogin("), ["SettingsView.swift"])
        var setters: [String] = []
        for file in files {
            let assigned = try Self.matches(#"settings\.(menuBarEnabled|historyEnabled|optInAnswered|weeklyReminderEnabled)\s*=[^=]"#, in: file.code)
            let bound = try Self.matches(#"\$settings\.(\w+)"#, in: file.code)
            setters += assigned.map { "\(file.name): \($0)" } + bound.map { "\(file.name): $\($0)" }
        }
        XCTAssertEqual(
            setters.sorted(),
            ["CmmApp.swift: menuBarEnabled", "SettingsView.swift: $historyEnabled", "SettingsView.swift: $menuBarEnabled"],
            "only the menu bar item's own binding and Settings' switches set a switch"
        )
    }

    /// The Settings window opens two places and nothing else: Login Items through the system's own call, and the Notifications
    /// pane through its address, by way of SwiftUI's `openURL` (no workspace).
    func testSettingsOpensOnlyTheTwoPlacesOfSystemSettings() throws {
        let view = try Self.source("SettingsView.swift").code
        XCTAssertTrue(view.contains("case .loginItems:\n                openLoginItems()\n                return .handled"))
        XCTAssertTrue(view.contains("case .notifications:\n                return .systemAction"))
        XCTAssertTrue(view.contains("case nil:\n                return .discarded"), "any other link does nothing")
        XCTAssertFalse(view.contains("NSWorkspace"))
        let app = try Self.source("CmmApp.swift").code
        XCTAssertTrue(app.contains("openLoginItems: { SystemLoginItem.openSystemSettings() }"))
        let asked = Set(try Self.matches(#"settings\.(\w+)"#, in: view))
        XCTAssertTrue(
            asked.isSubset(of: [
                "menuBarEnabled", "historyEnabled", "weeklyReminderEnabled", "openAtLogin", "openAtLoginFailed", "reminderIsSilenced",
                "weeklySchedule", "setOpenAtLogin", "setWeeklyReminder", "refresh",
            ]),
            "Settings uses \(asked.sorted())"
        )
    }

    // MARK: the one-time card

    /// The card is placed by one line of the window's root view, and its two answers are the settings model's two answers.
    func testTheCardIsOneLineInTheWindowAndItsAnswersAreTheSettingsOwn() throws {
        let files = try Self.files(in: "Sources/Cmm")
        XCTAssertEqual(files.filter { $0.code.contains("OptInSlot(") }.map(\.name), ["RootView.swift"])
        let root = try Self.source("RootView.swift").code
        XCTAssertEqual(root.components(separatedBy: "OptInSlot(").count - 1, 1)
        XCTAssertTrue(root.contains(".overlay(alignment: .topLeading) { OptInSlot(model: model, window: window, pill: pillFrame) }"))
        let card = try Self.source("OptInCard.swift").code
        XCTAssertTrue(card.contains("turnOn: { Task { await settings.turnOnEverything() } }"))
        XCTAssertTrue(card.contains("notNow: { settings.declineOptIn() }"))
        let asked = Set(try Self.matches(#"settings\.(\w+)"#, in: card))
        XCTAssertEqual(asked, ["optInAnswered", "turnOnEverything", "declineOptIn"], "the card reads its answer and gives one")
        XCTAssertFalse(card.contains("model.scan") || card.contains("model.toggle"), "the card does nothing to the window's work")
    }

    /// The Dock icon is the lifecycle's to change, in one place.
    func testTheActivationPolicyIsSetInOnePlace() throws {
        let files = try Self.sources()
        XCTAssertEqual(files.filter { $0.code.contains("setActivationPolicy") }.map(\.name), ["AppServices.swift"])
        let services = try Self.source("AppServices.swift").code
        XCTAssertEqual(services.components(separatedBy: "setActivationPolicy").count - 1, 1)
    }
}
