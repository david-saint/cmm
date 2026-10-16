import Foundation

/// The app's only way to reach the cmm engine. The real implementation starts the cmm program
/// (`ProcessCmmClient`); the tests use a fake that never starts anything.
public protocol CmmClient: Sendable {
    /// Asks cmm what it would clean (`cmm plan --json`). Read-only, but it can take a minute because big folders
    /// are sized.
    func plan() async throws -> Plan

    /// Reads what past cleanups freed and how the free space has moved (`cmm history --json --limit 0 --days 90`).
    /// Read-only and quick. It never takes the place of a scan or a cleanup: all three may run at the same time.
    func history() async throws -> HistoryReport

    /// Asks cmm to note the free space for the history (`cmm sample --json`). cmm reads the free space only (no scan) and
    /// decides whether a note is due, so this may be called as often as the app likes. It writes nothing but cmm's own
    /// note in cmm's own state folder, and, like `history`, may run beside a scan or a cleanup.
    func sample() async throws -> SampleResult

    /// Starts `cmm apply` for exactly the paths in `selection` and streams what it reports, one event at a time.
    /// The stream ends after the `done` event, or throws if cmm ended without one. Only the person's confirmation
    /// may lead to a call of this method (see `AppModel`).
    func apply(selection: ApplySelection) -> AsyncThrowingStream<ApplyEvent, any Error>

    /// Asks the running cmm to stop cleanly after the item in progress (SIGINT). Does nothing when nothing runs.
    func stop()
}
