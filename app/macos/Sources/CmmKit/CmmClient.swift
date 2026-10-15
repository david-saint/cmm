import Foundation

/// The app's only way to reach the cmm engine. The real implementation starts the cmm program
/// (`ProcessCmmClient`); the tests use a fake that never starts anything.
public protocol CmmClient: Sendable {
    /// Asks cmm what it would clean (`cmm plan --json`). Read-only, but it can take a minute because big folders
    /// are sized.
    func plan() async throws -> Plan

    /// Starts `cmm apply` for exactly the paths in `selection` and streams what it reports, one event at a time.
    /// The stream ends after the `done` event, or throws if cmm ended without one. Only the person's confirmation
    /// may lead to a call of this method (see `AppModel`).
    func apply(selection: ApplySelection) -> AsyncThrowingStream<ApplyEvent, any Error>

    /// Asks the running cmm to stop cleanly after the item in progress (SIGINT). Does nothing when nothing runs.
    func stop()
}
