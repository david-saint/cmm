import XCTest
@testable import CmmKit

/// One group of tests per safety rule of the spec (conductor/tracks/app_v0_20261015/spec.md):
///
///  1. The app never deletes, moves or writes outside its own temporary files; it only starts cmm.
///  2. It passes only paths that appeared in the last `cmm plan --json` result, never typed or constructed ones.
///  3. `cmm apply --yes` runs only after the person clicked Clean and then confirmed in a sheet that names the item
///     count and the total size; Cancel runs nothing.
///  4. The selection file is created with mode 0600 in the app's temporary folder and removed afterwards.
///  5. The app shows metadata (paths, sizes, notes), never file contents.
///  6. Tests never run a real clean on the real disk.
///
/// Some rules are about what the code is able to do at all, so part of this file reads the app's own source and
/// fails if a new line of code could break a rule. Those checks are blunt on purpose: when one trips, read the rule,
/// then change the check together with a reason.
@MainActor
final class SafetyRulesTests: XCTestCase {
    // MARK: reading the app's source

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CmmKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app/macos

    private struct SourceFile {
        let name: String
        let code: String  // without comments
    }

    private func sources(_ target: String) throws -> [SourceFile] {
        let folder = Self.packageRoot.appendingPathComponent("Sources/\(target)")
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "no sources found in \(folder.path): these checks would pass for the wrong reason")
        return try urls.map { SourceFile(name: $0.lastPathComponent, code: Self.strippingComments(try String(contentsOf: $0, encoding: .utf8))) }
    }

    /// Drops `// ...` comments (not inside string literals) so documentation can mention a forbidden call.
    private static func strippingComments(_ text: String) -> String {
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var inString = false
            var previous: Character = " "
            var iterator = line.makeIterator()
            while let character = iterator.next() {
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

    private func occurrences(of token: String, in files: [SourceFile]) -> [String] {
        files.filter { $0.code.contains(token) }.map(\.name)
    }

    /// Files that call a free function or initializer named `name` (not a method, so `.system(size:)` of a SwiftUI
    /// font is not `system(`).
    private func calls(_ name: String, in files: [SourceFile]) -> [String] {
        let pattern = "(^|[^A-Za-z_.@])" + NSRegularExpression.escapedPattern(for: name) + #"\("#
        return files.filter { $0.code.range(of: pattern, options: .regularExpression) != nil }.map(\.name)
    }

    // MARK: rule 1: only starts cmm, touches no files of the person's

    func testRule1_NothingThatChangesTheFileSystemExistsOutsideTheSelectionFile() throws {
        let files = try sources("CmmKit") + sources("Cmm")

        let forbiddenEverywhere = [
            "removeItem", "trashItem", "moveItem", "copyItem", "linkItem", "createSymbolicLink", "replaceItem",
            "createFile", "createDirectory", "setAttributes", "write(to:", "FileHandle(forWriting",
            "FileHandle(forUpdating", "NSWorkspace", "NSSavePanel", "posix_spawn", "NSTask",
            "NSAppleScript", "osascript", "remove(atPath",
        ]
        for token in forbiddenEverywhere {
            XCTAssertEqual(occurrences(of: token, in: files), [], "`\(token)` appears in the app's source")
        }
        for function in ["popen", "system", "truncate", "ftruncate", "symlink", "link", "execv", "execve", "fork"] {
            XCTAssertEqual(calls(function, in: files), [], "`\(function)(` is called in the app's source")
        }

        // The one place that creates and removes anything: the app's own selection file.
        for function in ["unlink", "rmdir", "mkdir", "chmod", "fchmod", "rename", "open"] {
            XCTAssertTrue(
                calls(function, in: files).allSatisfy { $0 == "SelectionFile.swift" },
                "`\(function)(` is called outside SelectionFile.swift: \(calls(function, in: files))"
            )
        }
        XCTAssertEqual(calls("unlink", in: files), ["SelectionFile.swift"], "the selection file is what gets removed")
        XCTAssertEqual(occurrences(of: "O_CREAT", in: files), ["SelectionFile.swift"])
    }

    func testRule1_FileManagerIsUsedOnlyToLookAtThingsAndToFindTheTemporaryFolder() throws {
        let files = try sources("CmmKit") + sources("Cmm")
        let allowed: Set<String> = ["fileExists", "isExecutableFile", "temporaryDirectory"]
        for file in files {
            let pattern = try NSRegularExpression(pattern: #"FileManager\.default\.(\w+)"#)
            let range = NSRange(file.code.startIndex..., in: file.code)
            for match in pattern.matches(in: file.code, range: range) {
                let member = (file.code as NSString).substring(with: match.range(at: 1))
                XCTAssertTrue(allowed.contains(member), "\(file.name) calls FileManager.default.\(member)")
            }
        }
    }

    func testRule1_TheWindowCodeDoesNotTouchFilesAtAll() throws {
        let files = try sources("Cmm")
        for token in ["FileManager", "FileHandle", "NSOpenPanel", "NSSavePanel", "Process()", "ProcessInfo", "Pipe(", "unlink", "URL(fileURLWithPath"] {
            XCTAssertEqual(occurrences(of: token, in: files), [], "the SwiftUI target uses `\(token)`")
        }
    }

    func testRule1_CmmIsTheOnlyProgramTheAppStarts() throws {
        let files = try sources("CmmKit") + sources("Cmm")
        XCTAssertEqual(occurrences(of: "Process()", in: files), ["ChildProcess.swift"], "one place makes processes")
        XCTAssertEqual(occurrences(of: "executableURL", in: files), ["ChildProcess.swift"])
        XCTAssertEqual(occurrences(of: "ChildProcess(", in: files), ["ProcessCmmClient.swift"], "and one place asks for one")

        // What is run is whatever `resolveBinary()` found (an explicit URL, CMM_BIN, or the copy inside the app),
        // with fixed arguments: `plan --json` or `apply --yes --json --select-file FILE`.
        let client = try XCTUnwrap(files.first { $0.name == "ProcessCmmClient.swift" }).code
        XCTAssertEqual(client.components(separatedBy: "makeChild(").count - 1, 3, "its definition, plan and apply")
        XCTAssertEqual(client.components(separatedBy: "resolveBinary()").count - 1, 3, "its definition, plan and apply")
        XCTAssertTrue(client.contains(#"arguments: ["plan", "--json"]"#))
        XCTAssertTrue(client.contains(#"arguments: ["apply", "--yes", "--json", "--select-file", file.url.path]"#))
    }

    // MARK: rule 2: only paths from the last plan

    func testRule2_TheWindowCodeCannotBuildAPlanASelectionOrAConfirmation() throws {
        let files = try sources("Cmm")
        for token in ["ApplySelection(", "CleanConfirmation(", "Plan(", "PlanItem(", "(unchecked", "Plan.parse", "JSONDecoder"] {
            XCTAssertEqual(occurrences(of: token, in: files), [], "the SwiftUI target uses `\(token)`")
        }
        let kit = try sources("CmmKit")
        XCTAssertEqual(occurrences(of: "(unchecked", in: kit), ["Selection.swift"], "the unchecked initializer exists in one place")
    }

    func testRule2_PlanAndItemsCanOnlyComeOutOfADecoder() throws {
        // A public memberwise or convenience initializer would let the app assemble a plan and hand its paths to
        // `apply`. The only public initializers are the Decodable ones (and the tier/action/status enums).
        for name in ["Plan.swift", "ApplyEvent.swift"] {
            let code = try XCTUnwrap(sources("CmmKit").first { $0.name == name }).code
            let pattern = try NSRegularExpression(pattern: #"public init\(([^)]*)\)"#)
            let range = NSRange(code.startIndex..., in: code)
            for match in pattern.matches(in: code, range: range) {
                let arguments = (code as NSString).substring(with: match.range(at: 1))
                XCTAssertTrue(arguments.hasPrefix("from decoder"), "\(name) has `public init(\(arguments))`")
            }
        }
        // `Plan` and `PlanItem` are structs with `let` properties, so there is no setter either.
        let plan = try XCTUnwrap(sources("CmmKit").first { $0.name == "Plan.swift" }).code
        let storedVars = plan.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("public var ") && !$0.contains("{")
        }
        XCTAssertTrue(storedVars.isEmpty, "no public mutable state in the plan model: \(storedVars)")
        XCTAssertFalse(plan.contains("public init(schemaVersion"))
    }

    func testRule2_ApplyIsCalledFromExactlyOnePlace() throws {
        let kit = try sources("CmmKit")
        let calls = kit.filter { $0.code.contains(".apply(selection:") }.map(\.name)
        XCTAssertEqual(calls, ["AppModel.swift"], "only the view model starts a cleanup")
        let model = try XCTUnwrap(kit.first { $0.name == "AppModel.swift" })
        XCTAssertEqual(model.code.components(separatedBy: ".apply(selection:").count - 1, 1)
        XCTAssertEqual(occurrences(of: "apply(", in: try sources("Cmm")), [], "the window code never calls apply")
    }

    func testRule2_AfterARescanOnlyThePathsOfTheNewPlanAreSent() async throws {
        let planA = try TestPlans.fixture("plan-v1.json")
        let planB = TestPlans.plan([
            TestPlans.item("/Users/test/new/only-in-b", bytes: 5_000),
            TestPlans.item("/Users/test/new/also-in-b", bytes: 4_000),
        ])
        let fake = FakeCmmClient(plans: [.success(planA), .success(planB)])
        fake.script(.replay([Events.done(deleted: 2)], error: nil))
        let model = AppModel(client: fake)
        await model.scan()
        await model.scan()  // plan B replaces plan A

        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        let sent = try XCTUnwrap(fake.applyCalls.first).paths
        XCTAssertEqual(Set(sent), ["/Users/test/new/only-in-b", "/Users/test/new/also-in-b"])
        XCTAssertTrue(Set(sent).isDisjoint(with: planA.items.map(\.path)), "nothing of plan A survives a rescan")
    }

    func testRule2_EverythingSentIsAnItemOfThePlanItCameFrom() async throws {
        let plan = try TestPlans.fixture("plan-mixed-tiers.json")
        let fake = FakeCmmClient(plan: plan)
        fake.script(.replay([Events.done()], error: nil))
        let model = AppModel(client: fake)
        await model.scan()
        // Tick everything, including the tiers that are not preselected.
        for group in model.selection?.groups ?? [] where model.selection?.state(of: group) != .on { model.toggle(group) }
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        let sent = try XCTUnwrap(fake.applyCalls.first).paths
        XCTAssertEqual(Set(sent), Set(plan.items.map(\.path)))
        XCTAssertTrue(sent.allSatisfy { path in plan.items.contains { $0.path == path } })
    }

    // MARK: rule 3: only after Clean and the confirmation

    func testRule3_TheSheetMakesCancelTheDefaultAndGivesCleanNoShortcut() throws {
        let sheet = try XCTUnwrap(sources("Cmm").first { $0.name == "ConfirmSheet.swift" }).code
        let cancel = try XCTUnwrap(sheet.range(of: #"Button("Cancel""#))
        let clean = try XCTUnwrap(sheet.range(of: #"Button("Clean""#))
        let defaultAction = try XCTUnwrap(sheet.range(of: ".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(cancel.upperBound <= defaultAction.lowerBound && defaultAction.upperBound <= clean.lowerBound,
                      "the default action belongs to the Cancel button")
        XCTAssertEqual(sheet.components(separatedBy: "keyboardShortcut").count - 1, 1, "no other shortcut in the sheet")
        XCTAssertFalse(sheet[clean.lowerBound...].contains("keyboardShortcut"), "Clean has no shortcut")
        XCTAssertTrue(sheet.contains("role: .destructive"), "Clean is marked as the destructive action")
    }

    func testRule3_TheSheetIsOurOwnNotAnAlertThatChoosesItsOwnDefault() throws {
        let files = try sources("Cmm")
        for token in [".alert(", ".confirmationDialog(", "NSAlert"] {
            XCTAssertEqual(occurrences(of: token, in: files), [], "`\(token)` picks its own default button")
        }
        XCTAssertEqual(occurrences(of: ".sheet(item:", in: files), ["RootView.swift"])
    }

    func testRule3_ConfirmCleanIsCalledOnlyFromTheSheetsCleanButton() throws {
        let files = try sources("Cmm")
        XCTAssertEqual(occurrences(of: "confirmClean(", in: files), ["RootView.swift"])
        XCTAssertEqual(occurrences(of: "requestClean()", in: files), ["FooterView.swift"])
        let root = try XCTUnwrap(files.first { $0.name == "RootView.swift" })
        XCTAssertTrue(root.code.contains("clean: { Task { await model.confirmClean(pending) } }"))
    }

    func testRule3_EndToEnd_NothingRunsUntilTheSheetIsAnswered() async throws {
        let fake = try makeFakeCmm()
        let model = AppModel(client: fake.client())

        await model.scan()
        XCTAssertEqual(fake.invocations(), ["plan --json"])

        model.requestClean()  // "Clean N items…"
        XCTAssertNotNil(model.confirmation)
        XCTAssertEqual(fake.invocations(), ["plan --json"], "the sheet is open and cmm has been asked nothing")

        model.cancelClean()  // Cancel
        XCTAssertEqual(fake.invocations(), ["plan --json"], "Cancel runs nothing")
        XCTAssertEqual(model.phase, .ready)

        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))  // Clean
        XCTAssertEqual(fake.invocations().count, 2)
        XCTAssertTrue(fake.invocations()[1].hasPrefix("apply --yes --json --select-file "), fake.invocations()[1])
        XCTAssertEqual(model.phase, .done)
    }

    func testRule3_EndToEnd_TheSheetNamesWhatCmmThenReceives() async throws {
        let fake = try makeFakeCmm()
        let model = AppModel(client: fake.client())
        await model.scan()
        let brew = try XCTUnwrap(model.selection?.groups.flatMap(\.items).first { $0.action == .command })
        model.toggle(brew)

        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.itemCount, 3)
        XCTAssertEqual(confirmation.bytes, 2_377_535_488)
        await model.confirmClean(confirmation)

        let sent = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(fake.record("selection.json")).utf8))
        XCTAssertEqual(sent.count, confirmation.itemCount, "cmm received as many items as the sheet said")
        XCTAssertEqual(sent, confirmation.selection.paths)
        XCTAssertFalse(sent.contains("homebrew: cleanup"), "the item that was unticked is not sent")
    }

    // MARK: rule 4: the selection file

    func testRule4_EndToEnd_PrivateWhileCmmReadsItAndGoneWhenTheCleanEnds() async throws {
        let fake = try makeFakeCmm()
        let model = AppModel(client: fake.client())
        await model.scan()
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        XCTAssertEqual(fake.record("selection.mode"), "600")
        XCTAssertEqual(fake.record("selection.dir.mode"), "700")
        XCTAssertEqual(fake.leftovers(), [], "nothing of the app's is left in its temporary folder")
        XCTAssertEqual(model.phase, .done)
    }

    // MARK: rule 5: metadata only

    func testRule5_NoCodeReadsTheContentsOfFiles() throws {
        let files = try sources("CmmKit") + sources("Cmm")
        for token in ["contentsOf", "contentsOfFile", "FileHandle(forReading", "InputStream", "fopen(", "fread(", "mmap("] {
            XCTAssertEqual(occurrences(of: token, in: files), [], "`\(token)` could read a file's contents")
        }
        // The one `read(` is the pipe from cmm.
        let reads = files.filter { $0.code.range(of: #"(^|[^A-Za-z_.])read\("#, options: .regularExpression) != nil }
        XCTAssertEqual(reads.map(\.name), ["ChildProcess.swift"])
    }

    func testRule5_ThePlanModelHoldsMetadataOnly() throws {
        let plan = try XCTUnwrap(sources("CmmKit").first { $0.name == "Plan.swift" }).code
        // Every stored field of an item is a name, a size, a tier, an action or a note.
        for field in ["let rule: String", "let group: String", "let path: String", "let bytes: Int64", "let tier: Tier",
                      "let action: ItemAction", "let note: String?"] {
            XCTAssertTrue(plan.contains(field), field)
        }
        XCTAssertFalse(plan.contains("let contents"))
        XCTAssertFalse(plan.contains("Data?"))
    }

    // MARK: rule 6: tests never clean the real disk

    func testRule6_TheRealBinaryTestsAreOffUnlessAskedForTwice() throws {
        let nothing: [String: String] = [:]
        XCTAssertNil(RealCmm.binary(environment: nothing))
        XCTAssertNil(RealCmm.sandboxedApplyBinary(environment: nothing, supportsSelectFile: { _ in true }))

        let fake = URL(fileURLWithPath: "/bin/echo")
        let onlyBinary = ["CMM_BIN": fake.path]
        XCTAssertEqual(RealCmm.binary(environment: onlyBinary)?.path, fake.path, "CMM_BIN alone allows the read-only plan test")
        XCTAssertNil(
            RealCmm.sandboxedApplyBinary(environment: onlyBinary, supportsSelectFile: { _ in true }),
            "but never an apply: that needs its own opt-in"
        )

        let both = ["CMM_BIN": fake.path, "CMM_SANDBOX_APPLY": "1"]
        XCTAssertNil(
            RealCmm.sandboxedApplyBinary(environment: both, supportsSelectFile: { _ in false }),
            "and a cmm that has no --select-file cannot be asked to apply a selection"
        )
        XCTAssertEqual(RealCmm.sandboxedApplyBinary(environment: both, supportsSelectFile: { _ in true })?.path, fake.path)
        XCTAssertNil(RealCmm.sandboxedApplyBinary(environment: ["CMM_BIN": fake.path, "CMM_SANDBOX_APPLY": "yes"], supportsSelectFile: { _ in true }))
    }

    func testRule6_NoTestStartsTheRealCmmWithoutASandboxedEnvironment() throws {
        // The only places that run a binary named by CMM_BIN build their environment with `Sandbox`, which sets
        // HOME and TMPDIR inside a temporary folder and puts fake brew and xcrun first on PATH.
        let tests = Self.packageRoot.appendingPathComponent("Tests/CmmKitTests")
        let urls = try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for url in urls where url.lastPathComponent != "SafetyRulesTests.swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            if code.contains("RealCmm.binary(") || code.contains("RealCmm.sandboxedApplyBinary(") {
                XCTAssertEqual(url.lastPathComponent, "RealCmmTests.swift", "only RealCmmTests.swift may use the real binary")
            }
        }
        let real = try String(contentsOf: tests.appendingPathComponent("RealCmmTests.swift"), encoding: .utf8)
        XCTAssertEqual(real.components(separatedBy: "ProcessCmmClient(").count - 1, 1, "one client is built: Sandbox.makeClient")
        let clientLines = real.split(separator: "\n").filter { $0.contains("let client =") }
        XCTAssertFalse(clientLines.isEmpty)
        XCTAssertTrue(clientLines.allSatisfy { $0.contains("sandbox.makeClient(binary: binary)") }, "every real client is the sandboxed one: \(clientLines)")
        XCTAssertTrue(real.contains(#"configuration.environment = ["HOME": home.path, "TMPDIR": tmp.path + "/", "LANG": "en_US.UTF-8"]"#),
                      "which never inherits the real environment")
    }
}
