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
            "SMAppService", "UNUserNotificationCenter", "NSBackgroundActivityScheduler", "NSAppleEventManager",
            "UserDefaults", "Settings.standard", "UserDefaultsSettingsStore", "FacePreference",
        ] {
            XCTAssertEqual(tests.filter { $0.code.contains(token) }.map(\.name), [], "a test uses `\(token)`")
        }
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

    /// The Dock icon is the lifecycle's to change, in one place.
    func testTheActivationPolicyIsSetInOnePlace() throws {
        let files = try Self.sources()
        XCTAssertEqual(files.filter { $0.code.contains("setActivationPolicy") }.map(\.name), ["AppServices.swift"])
        let services = try Self.source("AppServices.swift").code
        XCTAssertEqual(services.components(separatedBy: "setActivationPolicy").count - 1, 1)
    }
}
