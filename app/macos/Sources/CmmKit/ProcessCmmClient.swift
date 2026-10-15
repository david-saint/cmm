import Foundation

/// Talks to the real cmm program: `cmm plan --json` and `cmm apply --yes --json --select-file FILE`.
///
/// The client only starts cmm and reads what it prints; it never deletes, moves or writes anything except the
/// selection file it creates for one `apply` and removes again (see `SelectionFile`). One cmm runs at a time.
public final class ProcessCmmClient: CmmClient, @unchecked Sendable {
    /// A Finder-launched app gets a minimal PATH, and the Homebrew rule needs `brew`, so cmm is started with this.
    public static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// A plan is a few hundred kilobytes; anything beyond this is not a plan.
    static let maxPlanBytes = 64 * 1024 * 1024
    /// How much of cmm's stderr is kept for error messages.
    static let stderrTailBytes = 8 * 1024

    public struct Configuration: Sendable {
        /// An explicit cmm program. Wins over `CMM_BIN` and the copy inside the app.
        public var binaryURL: URL?
        /// The environment cmm is started with; nil passes on this process's own. `PATH` is replaced either way.
        public var environment: [String: String]?
        public var path: String
        /// Where the copy of cmm inside the app lives: `Cmm.app/Contents/Resources`.
        public var resourceDirectory: URL?
        /// Where the selection file is written.
        public var temporaryDirectory: URL
        /// The environment of the app itself, where `CMM_BIN` is looked up.
        public var appEnvironment: [String: String]

        public init(
            binaryURL: URL? = nil,
            environment: [String: String]? = nil,
            path: String = ProcessCmmClient.defaultPath,
            resourceDirectory: URL? = Bundle.main.resourceURL,
            temporaryDirectory: URL = FileManager.default.temporaryDirectory,
            appEnvironment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.binaryURL = binaryURL
            self.environment = environment
            self.path = path
            self.resourceDirectory = resourceDirectory
            self.temporaryDirectory = temporaryDirectory
            self.appEnvironment = appEnvironment
        }
    }

    /// The cmm that is running now and, for an `apply`, the selection file it was given.
    private struct Running {
        let child: ChildProcess
        let selectionFile: SelectionFile?
    }

    let configuration: Configuration
    private let running = Locked<Running?>(nil)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: finding cmm

    /// The cmm to run: an explicit URL, else `CMM_BIN`, else the copy inside the app. A `CMM_BIN` that does not
    /// work is an error, not a reason to quietly run a different cmm.
    func resolveBinary() throws -> URL {
        let candidate: URL
        if let explicit = configuration.binaryURL {
            candidate = explicit
        } else if let override = configuration.appEnvironment["CMM_BIN"], !override.isEmpty {
            candidate = URL(fileURLWithPath: override)
        } else if let resources = configuration.resourceDirectory {
            candidate = resources.appendingPathComponent("cmm")
        } else {
            throw CmmError.binaryNotFound(path: "Cmm.app/Contents/Resources/cmm")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: candidate.path)
        else {
            throw CmmError.binaryNotFound(path: candidate.path)
        }
        return candidate
    }

    private func makeChild(binary: URL, arguments: [String]) -> ChildProcess {
        var environment = configuration.environment ?? ProcessInfo.processInfo.environment
        environment["PATH"] = configuration.path
        return ChildProcess(executable: binary, arguments: arguments, environment: environment)
    }

    private func register(_ child: ChildProcess, selectionFile: SelectionFile? = nil) throws {
        try running.withLock { slot in
            guard slot == nil else { throw CmmError.busy }
            slot = Running(child: child, selectionFile: selectionFile)
        }
    }

    private func unregister(_ child: ChildProcess) {
        running.withLock { slot in
            if slot?.child === child { slot = nil }
        }
    }

    // MARK: CmmClient

    public func stop() {
        guard let current = running.withLock({ $0 }) else { return }
        current.child.interrupt()
        // cmm is being asked to end, so it has no further use for the selection file. Removing it here (and not
        // only when the run ends) matters when the app quits: the app can be gone before the run's exit handler
        // would have cleaned up.
        current.selectionFile?.remove()
    }

    public func plan() async throws -> Plan {
        let binary = try resolveBinary()
        try Task.checkCancellation()

        let child = makeChild(binary: binary, arguments: ["plan", "--json"])
        try register(child)
        defer { unregister(child) }

        let output = Locked(Data())
        let errors = Locked(Data())
        let tooBig = Locked(false)

        let exit: (status: Int32, reason: Process.TerminationReason) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try child.start(
                        onStdout: { chunk in
                            let overflow = output.withLock { data -> Bool in
                                data.append(chunk)
                                return data.count > Self.maxPlanBytes
                            }
                            if overflow {
                                tooBig.withLock { $0 = true }
                                child.terminate()
                            }
                        },
                        onStderr: { chunk in errors.withLock { Self.appendTail(&$0, chunk) } },
                        onExit: { status, reason in continuation.resume(returning: (status, reason)) }
                    )
                    if Task.isCancelled { child.terminate() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            child.terminate()
        }

        if Task.isCancelled { throw CancellationError() }
        if tooBig.withLock({ $0 }) {
            throw CmmError.malformedPlan("cmm printed more than \(Self.maxPlanBytes / 1024 / 1024) MB, which is not a plan")
        }
        let stderr = Self.text(errors.withLock { $0 })
        guard exit.reason == .exit, exit.status == 0 else {
            throw CmmError.planFailed(
                status: exit.status,
                stderr: Self.joined(Self.describe(exit.status, exit.reason), stderr)
            )
        }
        return try Plan.parse(output.withLock { $0 })
    }

    public func apply(selection: ApplySelection) -> AsyncThrowingStream<ApplyEvent, any Error> {
        AsyncThrowingStream { continuation in
            let binary: URL
            do {
                binary = try resolveBinary()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let file: SelectionFile
            do {
                file = try SelectionFile.create(paths: selection.paths, in: configuration.temporaryDirectory)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let child = makeChild(
                binary: binary,
                arguments: ["apply", "--yes", "--json", "--select-file", file.url.path]
            )
            do {
                try register(child, selectionFile: file)
            } catch {
                file.remove()
                continuation.finish(throwing: error)
                return
            }

            let session = ApplySession()

            // If the app stops listening (the task is cancelled, the loop is left), cmm is asked to stop cleanly
            // after the item in progress. A normal end also reports `.finished`; by then nothing is running and
            // `interrupt` does nothing.
            continuation.onTermination = { termination in
                if case .cancelled = termination { child.interrupt() }
            }

            do {
                try child.start(
                    onStdout: { chunk in
                        for event in session.feed(chunk) {
                            // `start` says how many paths cmm read from the file, so cmm has it in memory now. The
                            // file goes at once: if the app quits mid-clean, no exit handler is left to remove it.
                            if case .start = event { file.remove() }
                            continuation.yield(event)
                        }
                    },
                    onStderr: { chunk in session.addStderr(chunk) },
                    onExit: { [self] status, reason in
                        for event in session.finish() { continuation.yield(event) }
                        unregister(child)
                        file.remove()  // before the stream ends, so "finished" always means "cleaned up"
                        continuation.finish(throwing: session.failure(status: status, reason: reason))
                    }
                )
            } catch {
                unregister(child)
                file.remove()
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: helpers

    private static func appendTail(_ data: inout Data, _ chunk: Data) {
        data.append(chunk)
        if data.count > stderrTailBytes { data.removeFirst(data.count - stderrTailBytes) }
    }

    fileprivate static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func joined(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "cmm was ended by signal 2 (SIGINT)." for a signal; empty for a plain exit.
    fileprivate static func describe(_ status: Int32, _ reason: Process.TerminationReason) -> String {
        guard reason == .uncaughtSignal else { return "" }
        let names: [Int32: String] = [SIGINT: "SIGINT", SIGTERM: "SIGTERM", SIGKILL: "SIGKILL", SIGHUP: "SIGHUP", SIGSEGV: "SIGSEGV"]
        let name = names[status].map { " (\($0))" } ?? ""
        return "cmm was ended by signal \(status)\(name)."
    }
}

/// What one `apply` run accumulates on its helper threads: the parser (a line can span reads), whether the final
/// `done` event was seen, and the tail of stderr for error messages.
private final class ApplySession: @unchecked Sendable {
    private struct State {
        var parser = NDJSONParser()
        var sawDone = false
        var stderr = Data()
    }

    private let state = Locked(State())

    func feed(_ chunk: Data) -> [ApplyEvent] {
        state.withLock { state in
            let events = state.parser.feed(chunk)
            Self.note(events, in: &state)
            return events
        }
    }

    func finish() -> [ApplyEvent] {
        state.withLock { state in
            let events = state.parser.finish()
            Self.note(events, in: &state)
            return events
        }
    }

    func addStderr(_ chunk: Data) {
        state.withLock { state in
            state.stderr.append(chunk)
            if state.stderr.count > ProcessCmmClient.stderrTailBytes {
                state.stderr.removeFirst(state.stderr.count - ProcessCmmClient.stderrTailBytes)
            }
        }
    }

    /// The error that ends the stream, or nil when it ended properly. A `done` event is a proper end even if the
    /// exit status is 1: cmm exits with 1 when an item failed, after reporting it.
    func failure(status: Int32, reason: Process.TerminationReason) -> (any Error)? {
        let (sawDone, stderr) = state.withLock { ($0.sawDone, ProcessCmmClient.text($0.stderr)) }
        if sawDone { return nil }
        let detail = ProcessCmmClient.joined(ProcessCmmClient.describe(status, reason), stderr)
        if reason == .exit, status == 0 {
            return CmmError.endedWithoutSummary(status: status, stderr: detail)
        }
        return CmmError.applyFailed(status: status, stderr: detail)
    }

    private static func note(_ events: [ApplyEvent], in state: inout State) {
        for event in events {
            if case .done = event { state.sawDone = true }
        }
    }
}
