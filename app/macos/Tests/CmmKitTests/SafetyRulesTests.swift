import XCTest
@testable import CmmKit

/// One group of tests per safety rule of the spec (conductor/tracks/app_v0_20261015/spec.md):
///
///  1. The app never deletes, moves or writes outside its own temporary files; it only starts cmm.
///  2. It passes only paths that appeared in the last `cmm plan --json` result, never typed or constructed ones.
///  3. `cmm apply --yes` runs only after the person clicked Clean and then confirmed on a card that names the item
///     count and the total size; Cancel (the default, so Return and Esc) runs nothing.
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
            "FileHandle(forUpdating", "NSSavePanel", "posix_spawn", "NSTask",
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

    func testRule1_TheOnlyThingTheWorkspaceIsAskedIsToShowAFileInFinder() throws {
        let files = try sources("CmmKit") + sources("Cmm")
        XCTAssertEqual(occurrences(of: "NSWorkspace", in: files), ["FinderReveal.swift"], "one file talks to the workspace")
        let reveal = try XCTUnwrap(files.first { $0.name == "FinderReveal.swift" }).code
        XCTAssertEqual(reveal.components(separatedBy: "NSWorkspace").count - 1, 1)
        XCTAssertTrue(reveal.contains("NSWorkspace.shared.activateFileViewerSelecting("), "it selects a file in Finder")
        for token in ["open(", "openApplication", "launchApplication", "recycle(", "duplicate(", "setIcon", "unmount", "perform(", "selectFile("] {
            XCTAssertFalse(reveal.contains(token), "FinderReveal.swift uses `\(token)`")
        }
        // and it is handed only what the done screen shows: a path cmm reported, or the cleanup log
        let screens = try XCTUnwrap(files.first { $0.name == "StatusScreens.swift" }).code
        XCTAssertEqual(screens.components(separatedBy: "env.reveal(").count - 1, 2, "a failed item's path and the log")
        XCTAssertEqual(occurrences(of: "FinderReveal", in: files).sorted(), ["FinderReveal.swift", "ViewEnvironment.swift"])
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
        for token in ["FileManager", "FileHandle", "NSOpenPanel", "NSSavePanel", "Process()", "ProcessInfo", "Pipe(", "unlink"] {
            XCTAssertEqual(occurrences(of: token, in: files), [], "the SwiftUI target uses `\(token)`")
        }
        // A file URL is made in one place only: to ask Finder to show a path cmm reported.
        XCTAssertEqual(occurrences(of: "URL(fileURLWithPath", in: files), ["FinderReveal.swift"])
    }

    func testRule1_TheWindowCodeNeverTalksToTheClient() throws {
        let files = try sources("Cmm")
        // The client is made once, where the app starts, and handed to the model; no view calls it.
        XCTAssertEqual(occurrences(of: "ProcessCmmClient", in: files), ["CmmApp.swift"])
        XCTAssertEqual(occurrences(of: "CmmClient", in: files), ["CmmApp.swift"], "views see the model, not the client")
        for token in [".plan()", ".apply(", "client."] {
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
        // Try to tick everything, including the tiers that are not preselected.
        for group in model.selection?.groups ?? [] where model.selection?.state(of: group) != .on { model.toggle(group) }
        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))

        let sent = try XCTUnwrap(fake.applyCalls.first).paths
        // Safe items (preselected) and review items (ticked on purpose) go; manual and unknown tiers never can.
        let tickable = plan.items.filter { $0.tier == .safe || $0.tier == .review }
        XCTAssertEqual(Set(sent), Set(tickable.map(\.path)))
        XCTAssertEqual(tickable.count, 3)
        XCTAssertTrue(sent.allSatisfy { path in plan.items.contains { $0.path == path } })
    }

    // MARK: rule 3: only after Clean and the confirmation

    func testRule3_TheCardMakesCancelTheDefaultAndGivesDeleteNoShortcut() throws {
        let card = try XCTUnwrap(sources("Cmm").first { $0.name == "ConfirmCard.swift" }).code
        let cancel = try XCTUnwrap(card.range(of: "Button(action: cancel)"))
        let delete = try XCTUnwrap(card.range(of: "Button(role: .destructive, action: delete)"))
        let defaultAction = try XCTUnwrap(card.range(of: ".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(cancel.upperBound <= defaultAction.lowerBound && defaultAction.upperBound <= delete.lowerBound,
                      "the default action belongs to the Cancel button, which comes first")
        XCTAssertEqual(card.components(separatedBy: "keyboardShortcut").count - 1, 1, "no other shortcut on the card")
        XCTAssertFalse(card[delete.lowerBound...].contains("keyboardShortcut"), "Delete has no shortcut")
        XCTAssertTrue(card.contains("cancelFocused = true"), "Cancel has the focus when the card opens")
        XCTAssertTrue(card.contains(".accessibilityAddTraits(.isModal)"), "VoiceOver treats the card as modal")
    }

    func testRule3_TheCardIsOurOwnNotAnAlertThatChoosesItsOwnDefault() throws {
        let files = try sources("Cmm")
        for token in [".alert(", ".confirmationDialog(", "NSAlert", ".sheet(", ".popover(", ".fullScreenCover("] {
            XCTAssertEqual(occurrences(of: token, in: files), [], "`\(token)` picks its own default button or focus")
        }
        XCTAssertEqual(occurrences(of: "ConfirmCard(", in: files), ["RootView.swift"], "one place shows the card")
    }

    func testRule3_TheScreenBehindTheCardCannotBeReachedAndEscCancels() throws {
        let root = try XCTUnwrap(sources("Cmm").first { $0.name == "RootView.swift" }).code
        // The focus trap: while the card is up the screen is dimmed, disabled and hidden from VoiceOver.
        XCTAssertTrue(root.contains(".opacity(model.confirmation == nil ? 1 : 0.28)"))
        XCTAssertTrue(root.contains(".disabled(model.confirmation != nil)"))
        XCTAssertTrue(root.contains(".accessibilityHidden(model.confirmation != nil)"))
        // Esc cancels, through the one rule that says what Esc does (tested in WindowBehaviourTests).
        XCTAssertTrue(root.contains("window.escape(confirmationOpen: model.confirmation != nil, cancelConfirmation: { model.cancelClean() })"))
        XCTAssertTrue(root.contains("cancel: { model.cancelClean() }"))
    }

    /// Found in the running window: `onExitCommand` only fires for a focused view, and on a Mac without Full Keyboard
    /// Access no button can take the focus, so Esc did nothing. Esc is a key equivalent now, which needs no focus.
    func testRule3_EscIsAKeyEquivalentNotSomethingThatNeedsFocus() throws {
        let files = try sources("Cmm")
        XCTAssertEqual(occurrences(of: ".onExitCommand", in: files), [], "it only fires for a focused view")
        XCTAssertEqual(occurrences(of: ".keyboardShortcut(.cancelAction)", in: files), ["RootView.swift"], "one place binds Esc")
        let root = try XCTUnwrap(files.first { $0.name == "RootView.swift" }).code
        let shortcut = try XCTUnwrap(root.range(of: ".keyboardShortcut(.cancelAction)"))
        let button = try XCTUnwrap(root.range(of: #"Button("Close") {"#))
        let escape = try XCTUnwrap(root.range(of: "window.escape(confirmationOpen:"))
        XCTAssertTrue(button.upperBound <= escape.lowerBound && escape.upperBound <= shortcut.lowerBound,
                      "the Esc button's whole action is window.escape, which only cancels or closes")
        let action = root[button.upperBound..<shortcut.lowerBound]
        XCTAssertFalse(action.contains("confirmClean"), "Esc can never confirm")
        XCTAssertFalse(action.contains("requestClean"), "nor ask")
        // it sits outside the dimmed, disabled screen, or the open card would switch it off
        let screenModifiers = try XCTUnwrap(root.range(of: ".disabled(model.confirmation != nil)"))
        XCTAssertTrue(screenModifiers.upperBound <= button.lowerBound, "the button is not part of `screen`")
    }

    func testRule3_ConfirmCleanIsCalledOnlyFromTheCardsDeleteButton() throws {
        let files = try sources("Cmm")
        XCTAssertEqual(occurrences(of: "confirmClean(", in: files), ["RootView.swift"])
        XCTAssertEqual(files.map { $0.code.components(separatedBy: "confirmClean(").count - 1 }.reduce(0, +), 1)
        XCTAssertEqual(occurrences(of: "requestClean()", in: files), ["RestScreen.swift"], "only the pill asks for the card")
        let root = try XCTUnwrap(files.first { $0.name == "RootView.swift" })
        XCTAssertTrue(root.code.contains("delete: { Task { await model.confirmClean(confirmation) } }"))
        let rest = try XCTUnwrap(files.first { $0.name == "RestScreen.swift" })
        XCTAssertTrue(rest.code.contains("clean: { model.requestClean() }"))
    }

    func testRule3_EndToEnd_NothingRunsUntilTheCardIsAnswered() async throws {
        let fake = try makeFakeCmm()
        let model = AppModel(client: fake.client())

        await model.scan()
        XCTAssertEqual(fake.invocations(), ["plan --json"])

        model.requestClean()  // "Clean N GB…"
        XCTAssertNotNil(model.confirmation)
        XCTAssertEqual(fake.invocations(), ["plan --json"], "the card is open and cmm has been asked nothing")

        model.cancelClean()  // Cancel
        XCTAssertEqual(fake.invocations(), ["plan --json"], "Cancel runs nothing")
        XCTAssertEqual(model.phase, .ready)

        model.requestClean()
        await model.confirmClean(try XCTUnwrap(model.confirmation))  // Delete
        XCTAssertEqual(fake.invocations().count, 2)
        XCTAssertTrue(fake.invocations()[1].hasPrefix("apply --yes --json --select-file "), fake.invocations()[1])
        XCTAssertEqual(model.phase, .done)
    }

    func testRule3_EndToEnd_TheCardNamesWhatCmmThenReceives() async throws {
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
        XCTAssertEqual(sent.count, confirmation.itemCount, "cmm received as many items as the card said")
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

    // MARK: what the window says about the numbers is not cut

    func testTheNoteOfACommandItemIsNeverClipped() throws {
        // A command's note says what runs and, for Docker, that the space is freed inside Docker's disk image: the one
        // caveat that keeps "free space afterwards" honest. It must wrap completely, however long it is.
        let rows = try XCTUnwrap(sources("Cmm").first { $0.name == "DetailsRows.swift" }).code
        let start = try XCTUnwrap(rows.range(of: "Text(detail)"))
        let statement = rows[start.lowerBound...].prefix { $0 != "}" }
        for token in ["lineLimit", "truncationMode", "minimumScaleFactor", ".clipped", ".frame(height", ".frame(maxHeight"] {
            XCTAssertFalse(statement.contains(token), "a command's note carries `\(token)`")
        }
        XCTAssertTrue(statement.contains(".fixedSize(horizontal: false, vertical: true)"), "it takes the height it needs")
    }

    // MARK: what the app remembers

    func testTheOnlyThingTheAppRemembersIsWhichFaceOfTheDetailsWasLast() throws {
        let files = try sources("CmmKit") + sources("Cmm")
        for token in [
            "UserDefaults", "@AppStorage", "NSUserDefaults", "@SceneStorage", "SceneStorage", "NSUbiquitousKeyValueStore",
            "CFPreferences", "NSKeyedArchiver", "PropertyListEncoder", "NSPersistentContainer", "SwiftData",
        ] {
            XCTAssertEqual(occurrences(of: token, in: files), token == "UserDefaults" ? ["FacePreference.swift"] : [],
                           "`\(token)` is used outside the one file that remembers the face")
        }

        let store = try XCTUnwrap(files.first { $0.name == "FacePreference.swift" }).code
        XCTAssertEqual(store.components(separatedBy: "UserDefaults.standard").count - 1, 2, "one read and one write")
        XCTAssertEqual(store.components(separatedBy: ".string(forKey: key)").count - 1, 1)
        XCTAssertEqual(store.components(separatedBy: ".set(face.rawValue, forKey: key)").count - 1, 1, "what is written is a face's word")
        XCTAssertTrue(store.contains(#"static let key = "detailsFace""#), "one key")
        XCTAssertEqual(store.components(separatedBy: "\"").count - 1, 2, "no other string in the file: the key's two quotes")
        for token in ["removeObject", "synchronize", "register(", "dictionaryRepresentation", "setPersistentDomain", "addSuite", "suiteName"] {
            XCTAssertFalse(store.contains(token), "FacePreference.swift uses `\(token)`")
        }
    }

    func testTheRememberedFaceIsReadOnceAtStartAndWrittenOnlyWhenTheFaceChanges() throws {
        let files = try sources("Cmm")
        XCTAssertEqual(occurrences(of: "FacePreference", in: files), ["CmmApp.swift", "FacePreference.swift", "RootView.swift"])
        XCTAssertEqual(calls("FacePreference.load", in: files), ["CmmApp.swift"], "read once, when the window is made")
        XCTAssertEqual(calls("FacePreference.save", in: files), ["RootView.swift"], "written when the face changes")
        let app = try XCTUnwrap(files.first { $0.name == "CmmApp.swift" }).code
        XCTAssertTrue(app.contains("WindowState(face: FacePreference.load())"))
        let root = try XCTUnwrap(files.first { $0.name == "RootView.swift" }).code
        XCTAssertTrue(root.contains(".onChange(of: window.face) { _, face in FacePreference.save(face) }"))
    }

    // MARK: the map and the band

    private func code(_ name: String) throws -> String {
        try XCTUnwrap(sources("Cmm").first { $0.name == name }, name).code
    }

    /// The map and the band are a way to tick and to look: a click or a key on them ticks (through the same `toggle` the
    /// list uses), focuses, hovers or opens the pane, and nothing else. They hold no way to start a clean.
    func testTheMapAndTheBandCanOnlyTickFocusHoverAndOpenThePane() throws {
        let views = ["MapFace.swift", "MapTileView.swift", "BandViews.swift", "FlightOverlay.swift"]
        for name in views {
            let source = try code(name)
            for token in ["confirmClean", "requestClean", "cancelClean", ".scan(", "client", "Client", "selection?.", "apply"] {
                XCTAssertFalse(source.contains(token), "\(name) uses `\(token)`")
            }
        }
        // what the map asks of the model: to tick or untick, and nothing else
        let face = try code("MapFace.swift")
        let asked = try NSRegularExpression(pattern: #"model\.(\w+)"#).matches(in: face, range: NSRange(face.startIndex..., in: face))
            .map { (face as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(Set(asked), ["toggle"], "the map only ticks and unticks, through the model that guards it")
        XCTAssertFalse(try code("BandViews.swift").contains("model."), "the band does not touch the model: it opens the pane")
        // a click on a slice is a button that opens the map on its tile
        XCTAssertTrue(try code("BandViews.swift").contains("Button { doorway.open(slice.id) }"))
        let rest = try code("RestScreen.swift")
        XCTAssertTrue(rest.contains("open: { id in withAnimation(motion.animation) { window.openMap(focusing: id) } }"))
    }

    /// Found by pressing keys through a real window: a disabled view that already has the keyboard still gets its key
    /// presses, so the map and the list leave them alone themselves while the card has disabled the screen. And the arrows are
    /// key equivalents of the map alone, so they work without a click and are as disabled as the screen they are in.
    func testTheKeysOfTheMapAndTheListStopBehindTheCardAndTheMapsArrowsNeedNoFocus() throws {
        let files = try sources("Cmm")
        XCTAssertEqual(occurrences(of: ".onKeyPress", in: files), ["DetailsPane.swift", "MapFace.swift"])
        for name in ["DetailsPane.swift", "MapFace.swift"] {
            let source = try code(name)
            XCTAssertTrue(source.contains("@Environment(\\.isEnabled)") && source.contains("guard isEnabled"), "\(name) ignores keys while disabled")
        }
        XCTAssertEqual(
            occurrences(of: ".keyboardShortcut(", in: files), ["CmmApp.swift", "ConfirmCard.swift", "MapFace.swift", "RootView.swift"],
            "the only key equivalents: the menu's ⌘R and ⌘I, the card's default, Esc, and the map's arrows"
        )
        let face = try code("MapFace.swift")
        XCTAssertEqual(face.components(separatedBy: ".keyboardShortcut(").count - 1, 6, "up, down, left, right, home, end")
        XCTAssertEqual(face.components(separatedBy: "modifiers: [])").count - 1, 6, "plain keys: a modifier is somebody else's shortcut")
        for token in [".keyboardShortcut(.space", ".keyboardShortcut(.return", ".keyboardShortcut(.escape", ".keyboardShortcut(.cancelAction", ".keyboardShortcut(.defaultAction"] {
            XCTAssertFalse(face.contains(token), "the map takes `\(token)`, which belongs to the control that has the focus")
        }
    }

    /// The band's flights are only paint: they take no clicks, say nothing to VoiceOver, and are off with Reduce Motion.
    func testTheFlightsArePaintOnlyAndFollowReduceMotion() throws {
        let overlay = try code("FlightOverlay.swift")
        XCTAssertTrue(overlay.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(overlay.contains(".accessibilityHidden(true)"))
        let root = try code("RootView.swift")
        XCTAssertTrue(root.contains("window.flightsEnabled = MotionStyle.resolve(reduceMotion: reduce).flies"))
        let band = try code("BandViews.swift")
        XCTAssertEqual(band.components(separatedBy: "motion.animatesMagnifier").count - 1, 2, "the enlarging is animated only with motion")
        // the tiles under a flight cannot be hit
        XCTAssertTrue(try code("MapFace.swift").contains(".allowsHitTesting(!inTheAir)"))
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
