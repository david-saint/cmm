import XCTest
@testable import CmmKit

/// Which tests may run a real cmm binary, and what they may do with it.
///
///  - `CMM_BIN=/path/to/cmm` allows the read-only test that decodes a real `cmm plan --json`.
///  - A real *apply* needs a second, explicit opt-in (`CMM_SANDBOX_APPLY=1`) and a cmm that has `--select-file`.
///
/// Both run only inside a `Sandbox`; see there for why that is not enough on its own and what else is checked.
enum RealCmm {
    static func binary(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["CMM_BIN"], !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static func sandboxedApplyBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportsSelectFile: (URL) -> Bool = RealCmm.supportsSelectFile
    ) -> URL? {
        guard environment["CMM_SANDBOX_APPLY"] == "1", let binary = binary(environment: environment) else { return nil }
        return supportsSelectFile(binary) ? binary : nil
    }

    /// Asks `cmm apply --help` (which only prints help) whether `--select-file` exists yet.
    static func supportsSelectFile(_ binary: URL) -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["apply", "--help"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).contains("--select-file")
    }
}

/// A fake home for a real cmm: HOME and TMPDIR inside a temporary folder, and fake `brew`, `xcrun` and `docker`
/// first on PATH.
///
/// That keeps cmm's HOME-based rules inside the sandbox, but not everything: cmm appends Homebrew's folders to
/// PATH itself (so the fakes must come first, which they do), and its temp-folder rules ask `getconf
/// DARWIN_USER_TEMP_DIR` for the real per-user temp folder, ignoring TMPDIR. So the real-apply test additionally
/// refuses to run unless cmm's fresh plan is nothing but sandbox `delete` items (see there).
struct Sandbox {
    let root: URL
    let home: URL
    let tmp: URL
    let bin: URL

    /// What a real cmm finds under the fake home: two caches it knows (npm and bun) and a bystander. cmm leaves
    /// caches under 50 MB out of its plan silently, so `populateCaches()` writes a little more than that into each.
    let cacheFolders = [".npm/_cacache", ".bun/install/cache"]
    var bystander: URL { home.appendingPathComponent("Documents/keep.txt") }

    @MainActor
    static func make(in test: XCTestCase) throws -> Sandbox {
        let root = try test.makeTempDirectory("cmm-sandbox").resolvingSymlinksInPath()
        let sandbox = Sandbox(
            root: root,
            home: root.appendingPathComponent("home", isDirectory: true),
            tmp: root.appendingPathComponent("tmp", isDirectory: true),
            bin: root.appendingPathComponent("bin", isDirectory: true)
        )
        let fm = FileManager.default
        for folder in [sandbox.home, sandbox.tmp, sandbox.bin, sandbox.bystander.deletingLastPathComponent()] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for tool in ["brew", "xcrun", "docker"] {  // tools that would reach outside the sandbox report nothing
            let url = sandbox.bin.appendingPathComponent(tool)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for folder in sandbox.cacheFolders {
            try fm.createDirectory(at: sandbox.home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("not a cache".utf8).write(to: sandbox.bystander)
        return sandbox
    }

    /// Fills the cache folders with real data (about 51 MB each, in the sandbox's temporary folder).
    func populateCaches() throws {
        let block = Data(repeating: 0x41, count: 51 * 1024 * 1024)
        for folder in cacheFolders {
            try block.write(to: home.appendingPathComponent(folder).appendingPathComponent("blob.bin"))
        }
    }

    /// The only way the real binary is ever started by a test: HOME and TMPDIR in the sandbox, the fakes first on
    /// PATH, and nothing else of the real environment.
    func makeClient(binary: URL) -> ProcessCmmClient {
        var configuration = ProcessCmmClient.Configuration()
        configuration.binaryURL = binary
        configuration.environment = ["HOME": home.path, "TMPDIR": tmp.path + "/", "LANG": "en_US.UTF-8"]
        configuration.path = "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        configuration.temporaryDirectory = tmp
        return ProcessCmmClient(configuration: configuration)
    }

    func contains(_ path: String) -> Bool {
        path.hasPrefix(root.path + "/")
    }
}

@MainActor
final class RealCmmTests: XCTestCase {
    func testTheSandboxPutsHomeAndTmpInsideATemporaryFolderAndTheFakesFirst() throws {
        let sandbox = try Sandbox.make(in: self)
        XCTAssertTrue(sandbox.home.path.hasPrefix(sandbox.root.path + "/"))
        XCTAssertTrue(sandbox.tmp.path.hasPrefix(sandbox.root.path + "/"))
        XCTAssertNotEqual(sandbox.home.path, NSHomeDirectory(), "the sandbox must not be the real home")
        XCTAssertFalse(NSHomeDirectory().hasPrefix(sandbox.root.path), "and not inside it either way round")
        for tool in ["brew", "xcrun", "docker"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.bin.appendingPathComponent(tool).path))
        }
        for folder in sandbox.cacheFolders {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(folder).path), folder)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.bystander.path))
        XCTAssertEqual(sandbox.makeClient(binary: URL(fileURLWithPath: "/bin/echo")).configuration.path.split(separator: ":").first.map(String.init), sandbox.bin.path)
    }

    /// Read-only: runs the real `cmm plan --json` under the fake home and decodes it. Skipped unless CMM_BIN is set.
    func testARealPlanDecodesThroughTheClient() async throws {
        guard let binary = RealCmm.binary() else { throw XCTSkip("set CMM_BIN to a built cmm to run this") }
        let sandbox = try Sandbox.make(in: self)
        try sandbox.populateCaches()
        let client = sandbox.makeClient(binary: binary)

        let plan = try await client.plan()

        XCTAssertEqual(plan.schemaVersion, 1)
        XCTAssertGreaterThan(plan.host.freeBytes, 0)
        XCTAssertFalse(plan.host.volume.isEmpty)
        let ours = plan.items.filter { sandbox.contains($0.path) }
        if ours.isEmpty {
            throw XCTSkip("cmm planned nothing under the fake home; its guards held back: \(plan.skipped.map(\.summary))")
        }
        XCTAssertTrue(ours.allSatisfy { $0.action == .delete && $0.tier == .safe })
        XCTAssertTrue(ours.allSatisfy { $0.bytes > 0 })
        XCTAssertEqual(plan.totalBytes, plan.items.reduce(0) { $0 + $1.bytes }, "the real total agrees with its items")
    }

    /// Read-only apart from cmm's own note in the fake home's state folder: the real `cmm sample --json` and `cmm history
    /// --json --limit 0 --days 90`, decoded through the client. Skipped unless CMM_BIN is set.
    func testARealSampleAndHistoryDecodeThroughTheClient() async throws {
        guard let binary = RealCmm.binary() else { throw XCTSkip("set CMM_BIN to a built cmm to run this") }
        let sandbox = try Sandbox.make(in: self)
        let client = sandbox.makeClient(binary: binary)

        let before = try await client.history()
        XCTAssertTrue(before.runs.isEmpty, "a fake home has no cleanups")
        XCTAssertTrue(before.samples.isEmpty, "and no notes yet")
        XCTAssertEqual(before.unreadableLines, 0)

        let first = try await client.sample()
        XCTAssertTrue(first.recorded, "the first note is always due")
        XCTAssertGreaterThan(first.freeBytes, 0)
        XCTAssertNotNil(first.t)

        _ = try await client.sample()  // usually "not due"; the engine decides, the app only asks

        let after = try await client.history()
        XCTAssertEqual(after.schemaVersion, 1)
        XCTAssertGreaterThanOrEqual(after.samples.count, 1)
        XCTAssertEqual(after.samples.first?.t, first.t)
        XCTAssertEqual(after.samples.first?.freeBytes, first.freeBytes)
        XCTAssertNotNil(after.host.freeBytes, "the volume could be read")
        XCTAssertGreaterThan(after.host.freeBytes ?? 0, 0)
        XCTAssertEqual(after.ignoredEntries, 0, "everything cmm wrote, the app can read")
        let written = sandbox.home.appendingPathComponent(".local/state/cmm/free.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path), "the note went to the fake home, not the real one")
    }

    /// A real apply, in the sandbox, through the Swift client. Off unless CMM_BIN and CMM_SANDBOX_APPLY=1 are set and
    /// the cmm has `--select-file`.
    func testASandboxedRealApplyDeletesExactlyTheSelectedItems() async throws {
        guard let binary = RealCmm.sandboxedApplyBinary() else {
            throw XCTSkip("set CMM_BIN and CMM_SANDBOX_APPLY=1 (and use a cmm with apply --select-file) to run this")
        }
        let sandbox = try Sandbox.make(in: self)
        try sandbox.populateCaches()
        let client = sandbox.makeClient(binary: binary)
        let plan = try await client.plan()

        // The sandbox must be airtight, or nothing is applied. cmm re-plans before it applies, so anything in the
        // fresh plan that is not a delete inside the sandbox (a Homebrew or simulator command, or a folder of the
        // real temp dir) is something an engine bug could widen the selection to. Fail, do not skip, and do not apply.
        let outsiders = plan.items.filter { !($0.action == .delete && sandbox.contains($0.path)) }
        guard outsiders.isEmpty else {
            XCTFail("the sandbox is not airtight, so no apply was started. Items outside it: \(outsiders.map(\.path))")
            return
        }
        let candidates = plan.items.filter { sandbox.contains($0.path) }
        guard candidates.count >= 2 else {
            throw XCTSkip("cmm planned fewer than two sandbox items (its guards held back: \(plan.skipped.map(\.summary)))")
        }

        // Tick all but one, so the run also proves that the selection narrows the fresh plan.
        let spared = candidates[0]
        let selected = candidates.dropFirst()
        let selection = ApplySelection(plan: plan, ticked: Set(selected.map(\.path)))
        XCTAssertEqual(selection.count, selected.count)
        XCTAssertTrue(selection.paths.allSatisfy(sandbox.contains), "every path handed to cmm is inside the sandbox")
        let commandPaths = Set(plan.items.filter { $0.action == .command }.map(\.path))
        XCTAssertTrue(commandPaths.isDisjoint(with: selection.paths), "no command item (brew, simulators) is selected")

        let events = try await collect(client.apply(selection: selection))

        let done = try XCTUnwrap(events.last?.done)
        XCTAssertEqual(done.deleted, selected.count)
        XCTAssertEqual(done.failed, 0)
        XCTAssertFalse(done.stopped)
        let reported = Dictionary(uniqueKeysWithValues: events.compactMap(\.item).map { ($0.path, $0.status) })
        for item in selected {
            XCTAssertEqual(reported[item.path], .deleted, item.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), "\(item.path) should be gone")
        }
        XCTAssertNil(reported[spared.path], "an item that was not selected is not even mentioned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spared.path), "the item that was not selected is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.bystander.path), "nothing else in the fake home was touched")
        if let log = done.log {
            XCTAssertTrue(sandbox.contains(log), "the record of the cleanup went to the fake home, not the real one: \(log)")
        }
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: sandbox.tmp.path)) ?? [], [],
            "no selection file is left behind"
        )
    }
}
