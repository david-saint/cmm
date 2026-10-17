import Foundation
import Observation

/// What the History face holds between one look and the next: the last report cmm gave, and whether the last try worked.
/// The report is read when the face is opened and again when a cleaning ends; the face asks nothing else of cmm.
@MainActor
@Observable
public final class HistoryModel {
    public enum Phase: Equatable, Sendable {
        /// Nothing has been asked yet.
        case idle
        case loaded
        /// The last try failed; `report` is still the last good one, if there was one.
        case failed(title: String, detail: String)
    }

    public private(set) var phase = Phase.idle
    public private(set) var report: HistoryReport?
    /// A report is being read.
    public private(set) var isLoading = false

    @ObservationIgnored private let fetch: @Sendable () async throws -> HistoryReport
    /// The one task that is reading, for as long as someone has asked and it has not finished.
    @ObservationIgnored private var flight: Task<Void, Never>?
    /// Someone asked while a read was out, or asked and the read has not begun.
    @ObservationIgnored private var pending = false

    public init(fetch: @escaping @Sendable () async throws -> HistoryReport) {
        self.fetch = fetch
    }

    /// Asks cmm for the history through the client, and for nothing else.
    public convenience init(client: any CmmClient) {
        self.init(fetch: { try await client.history() })
    }

    /// Gets the report. Asked while a try is out, it tries once more when that one is done (a cleaning may have ended since it
    /// began), however many times it is asked.
    public func load() async {
        pending = true
        if let flight {
            await flight.value
            return
        }
        let flight = Task { await drain() }
        self.flight = flight
        await flight.value
    }

    private func drain() async {
        isLoading = true
        while pending {
            pending = false
            do {
                report = try await fetch()
                phase = .loaded
            } catch {
                let cmm = error as? CmmError
                phase = .failed(title: cmm?.title ?? "cmm could not read the history", detail: cmm?.detail ?? "")
            }
        }
        isLoading = false
        flight = nil
    }

    /// The face, or nil before a report has been read.
    public func presentation(historyEnabled: Bool, now: Date, calendar: Calendar, locale: Locale, home: String) -> HistoryPresentation? {
        guard let report else { return nil }
        return HistoryPresentation(report: report, historyEnabled: historyEnabled, now: now, calendar: calendar, locale: locale, home: home)
    }
}
