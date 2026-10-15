import Foundation
import XCTest
@testable import CmmKit

/// The fake cmm script (Fixtures/fake-cmm.sh), copied into a private temporary folder, plus the folder it records
/// into and the folder the client is told to use for its own temporary files.
struct FakeCmm: Sendable {
    let root: URL
    let script: URL
    /// Where the fake writes what it was asked (invocations.log, env.txt, pid, selection.*).
    let records: URL
    /// What the client is given as its temporary folder: a selection file must never be left in here.
    let temporaryFolder: URL

    var releaseFile: URL { records.appendingPathComponent("release") }

    /// A client wired to the fake. `mode` picks the behaviour, see the header of fake-cmm.sh.
    func client(
        mode: String = "normal",
        plan: String = "plan-v1.json",
        environment extra: [String: String] = [:],
        path: String? = nil
    ) -> ProcessCmmClient {
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CMM_DIR"] = records.path
        env["FAKE_CMM_PLAN"] = Fixture.url(plan).path
        env["FAKE_CMM_MODE"] = mode
        env["FAKE_CMM_RELEASE"] = releaseFile.path
        for (key, value) in extra { env[key] = value }

        var configuration = ProcessCmmClient.Configuration()
        configuration.binaryURL = script
        configuration.environment = env
        configuration.temporaryDirectory = temporaryFolder
        if let path { configuration.path = path }
        return ProcessCmmClient(configuration: configuration)
    }

    /// Lets a `slow` or `plan-hang` run continue.
    func release() {
        FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
    }

    func record(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: records.appendingPathComponent(name)) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One entry per run, in order, for example `plan --json`.
    func invocations() -> [String] {
        (record("invocations.log") ?? "").split(separator: "\n").map(String.init)
    }

    var pid: Int32? { record("pid").flatMap { Int32($0) } }

    /// True while the process the fake recorded is still alive.
    func processIsAlive() -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0
    }

    /// Everything the client left behind in its temporary folder.
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: temporaryFolder.path)) ?? []).sorted()
    }

    /// A last resort for a test that failed half way: end the fake if it is still running. It checks the command
    /// line first, so a recycled process id can never make this touch an unrelated process.
    func killStragglers() {
        guard let pid, kill(pid, 0) == 0 else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        if text.contains(root.path) { kill(pid, SIGKILL) }
    }
}

extension XCTestCase {
    func makeFakeCmm() throws -> FakeCmm {
        let root = try makeTempDirectory("fake-cmm")
        let records = root.appendingPathComponent("records", isDirectory: true)
        let temporaryFolder = root.appendingPathComponent("client-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)

        let script = root.appendingPathComponent("cmm")
        try FileManager.default.copyItem(at: Fixture.url("fake-cmm.sh"), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let fake = FakeCmm(root: root, script: script, records: records, temporaryFolder: temporaryFolder)
        addTeardownBlock { fake.killStragglers() }
        return fake
    }

    /// Polls until `condition` holds or the time is up.
    @discardableResult
    func eventually(timeout: Double = 10, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Collects every event of a stream.
func collect(_ stream: AsyncThrowingStream<ApplyEvent, any Error>) async throws -> [ApplyEvent] {
    var events: [ApplyEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

extension ApplyEvent {
    var isDone: Bool { if case .done = self { true } else { false } }
    var isItem: Bool { if case .item = self { true } else { false } }
    var isUnreadable: Bool { if case .unreadable = self { true } else { false } }
    var item: ItemEvent? { if case .item(let item) = self { item } else { nil } }
    var done: DoneEvent? { if case .done(let done) = self { done } else { nil } }
}
