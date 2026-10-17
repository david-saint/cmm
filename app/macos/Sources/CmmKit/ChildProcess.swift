import Foundation

/// One run of the cmm program: started with pipes for stdout and stderr (stdin is /dev/null, so nothing can wait
/// for a keypress), read incrementally on helper threads, and signalled safely.
///
/// Two traps of `Foundation.Process` are avoided on purpose. Sending `interrupt()` or `terminate()` to a task that
/// is not running raises an Objective-C exception, which would crash the app, so signals go through `kill(2)` and
/// only while this object knows the process is running. And both pipes are read to the end on their own threads
/// while the process runs; a child that writes more than a pipe holds would otherwise block forever.
final class ChildProcess: @unchecked Sendable {
    /// After the process has ended, how long to wait for its pipes to reach the end. A grandchild that inherited a
    /// pipe and outlives cmm would otherwise keep the run open for ever.
    static let pipeGrace: DispatchTimeInterval = .seconds(2)

    private enum State {
        case idle, running, exited
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var state = State.idle
    private var pid: pid_t = 0

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// Starts the process. `onStdout` and `onStderr` receive chunks from helper threads, in order. `onExit` runs
    /// once, after the process ended and both pipes were read to the end (or after `pipeGrace`).
    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32, Process.TerminationReason) -> Void
    ) throws {
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()

        process.terminationHandler = { [self] finished in
            lock.lock()
            state = .exited
            lock.unlock()
            _ = readers.wait(timeout: .now() + Self.pipeGrace)
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            finished.terminationHandler = nil  // breaks the reference cycle through this closure
            onExit(status, reason)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            readers.leave()
            readers.leave()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw CmmError.launchFailed(error.localizedDescription)
        }

        lock.lock()
        pid = process.processIdentifier
        if state == .idle { state = .running }  // the handler may already have run for a very short process
        lock.unlock()

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        Thread.detachNewThread {
            Self.drain(outHandle, into: onStdout)
            readers.leave()
        }
        Thread.detachNewThread {
            Self.drain(errHandle, into: onStderr)
            readers.leave()
        }
    }

    /// Asks the process to stop cleanly (SIGINT, the same as Ctrl+C in a terminal). No-op unless it is running.
    func interrupt() {
        send(SIGINT)
    }

    /// Asks the process to end (SIGTERM). No-op unless it is running. Used for read-only work (a plan).
    func terminate() {
        send(SIGTERM)
    }

    private func send(_ signalNumber: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running, pid > 0 else { return }
        kill(pid, signalNumber)
    }

    /// Reads a pipe until its end with plain `read(2)`: no exceptions, no waiting for a full buffer.
    private static func drain(_ handle: FileHandle, into sink: @Sendable (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                sink(Data(buffer[0..<count]))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        try? handle.close()
    }
}
