import Foundation

/// A value guarded by a lock, for the few places where the process client's reader threads and the caller share
/// state. (`NSLock` rather than `Synchronization.Mutex`, which needs macOS 15; the app supports macOS 14.)
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
