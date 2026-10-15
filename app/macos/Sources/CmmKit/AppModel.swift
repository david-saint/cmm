import Foundation
import Observation

/// The question the confirmation sheet asks: the frozen selection, its count and its size.
///
/// Only the model makes one (`AppModel.requestClean`), and `confirmClean` accepts only the one that is currently
/// pending for the current plan. That is safety rule 3: `cmm apply` cannot start without the person having seen
/// exactly this item count and size and answering "Clean".
public struct CleanConfirmation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let selection: ApplySelection
    /// Which plan this was asked about; a rescan makes it stale.
    let generation: Int

    init(selection: ApplySelection, generation: Int) {
        self.id = UUID()
        self.selection = selection
        self.generation = generation
    }

    public var itemCount: Int { selection.count }
    public var bytes: Int64 { selection.bytes }

    /// `Delete 4 items (3.1 GB)?`
    public var prompt: String { "Delete \(Plural.items(itemCount)) (\(ByteFormat.string(bytes)))?" }
    public var detail: String { "Each item is checked again right before it is removed." }
}

/// What a running cleanup has reported so far.
public struct CleanProgress: Equatable, Sendable {
    /// How many items the person confirmed.
    public internal(set) var expected: Int
    /// From cmm's `start` event.
    public internal(set) var selected: Int?
    public internal(set) var matched: Int?
    public internal(set) var items: [ItemEvent] = []
    public internal(set) var stopRequested = false
    /// Lines cmm printed that could not be understood.
    public internal(set) var unreadableLines = 0

    init(expected: Int) {
        self.expected = expected
    }

    public var deleted: Int { items.filter { $0.status == .deleted }.count }
    public var skipped: Int { items.filter { $0.status == .skipped }.count }
    public var failed: Int { items.filter { $0.status == .failed }.count }
    public var freedBytes: Int64 { items.reduce(0) { $0 + $1.freedBytes } }

    /// How many items cmm will report on: its own count once the `start` event is in, the confirmed count before.
    public var total: Int { selected ?? expected }

    /// 0...1. Clamped, because paths that were not in cmm's fresh plan come back as extra skipped items and the
    /// number of reports can differ from what was expected.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(items.count) / Double(total)))
    }
}

/// What a finished cleanup reports: cmm's own `done` event and the items it reported on the way.
public struct CleanSummary: Equatable, Sendable {
    public let done: DoneEvent
    public let items: [ItemEvent]
    public let unreadableLines: Int

    public var stopped: Bool { done.stopped }
}

/// Why the window shows an error: a headline, what happened and whether it was a scan or a cleanup.
public struct AppFailure: Equatable, Sendable {
    public enum Stage: Sendable {
        case scan
        case clean
    }

    public let stage: Stage
    public let title: String
    public let detail: String
}

/// The brain of the window. It owns the last plan, the ticks, the confirmation and the state of a scan or a
/// cleanup, and it is the only thing that calls `apply` on the client.
///
///     idle -> scanning -> ready | empty | failed
///     ready -> cleaning -> done | failed        (cleaning needs requestClean, then the person's confirmClean)
///     done | failed | ready | empty -> scanning (rescan)
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case scanning
        case ready
        case empty
        case cleaning
        case done
        case failed
    }

    public private(set) var phase = Phase.idle
    /// The last plan from cmm. Gone while a rescan runs, and after a failed one.
    public private(set) var plan: Plan?
    public private(set) var selection: SelectionModel?
    /// Non-nil while the confirmation sheet is open.
    public private(set) var confirmation: CleanConfirmation?
    public private(set) var progress = CleanProgress(expected: 0)
    public private(set) var summary: CleanSummary?
    public private(set) var failure: AppFailure?

    @ObservationIgnored private let client: any CmmClient
    /// Counts plans. A confirmation belongs to one plan; internal so tests can age one.
    @ObservationIgnored var planGeneration = 0

    public init(client: any CmmClient) {
        self.client = client
    }

    // MARK: scanning

    /// Asks cmm for a fresh plan. Ignored while a scan or a cleanup is running.
    public func scan() async {
        guard phase != .scanning, phase != .cleaning else { return }

        planGeneration += 1
        plan = nil
        selection = nil
        confirmation = nil
        summary = nil
        failure = nil
        progress = CleanProgress(expected: 0)
        phase = .scanning

        do {
            let fresh = try await client.plan()
            plan = fresh
            selection = SelectionModel(plan: fresh)
            phase = fresh.items.isEmpty ? .empty : .ready
        } catch {
            failure = Self.makeFailure(error, stage: .scan, progress: nil)
            phase = .failed
        }
    }

    // MARK: ticking

    public func toggle(_ item: PlanItem) {
        guard canTick else { return }
        selection?.toggle(item)
    }

    public func toggle(_ group: PlanGroup) {
        guard canTick else { return }
        selection?.toggle(group)
    }

    private var canTick: Bool { phase == .ready && confirmation == nil }

    // MARK: cleaning

    /// "Clean N items…": freezes the current selection into a confirmation for the sheet. Starts nothing.
    public func requestClean() {
        guard phase == .ready, let selection, selection.selectedCount > 0 else { return }
        confirmation = CleanConfirmation(selection: selection.applySelection, generation: planGeneration)
    }

    /// Cancel on the sheet. Runs nothing.
    public func cancelClean() {
        confirmation = nil
    }

    /// Clean on the sheet. The only way `apply` is ever started, and only for the confirmation that is pending for
    /// the current plan: a forged, replayed or stale one does nothing.
    public func confirmClean(_ confirmation: CleanConfirmation) async {
        guard phase == .ready,
              let pending = self.confirmation,
              pending == confirmation,
              confirmation.generation == planGeneration
        else { return }

        self.confirmation = nil
        summary = nil
        failure = nil
        progress = CleanProgress(expected: confirmation.selection.count)
        phase = .cleaning

        var finished: DoneEvent?
        do {
            for try await event in client.apply(selection: confirmation.selection) {
                switch event {
                case .start(let start):
                    progress.selected = start.selected
                    progress.matched = start.matched
                case .item(let item):
                    progress.items.append(item)
                case .done(let done):
                    finished = done
                case .unreadable:
                    progress.unreadableLines += 1
                }
            }
        } catch {
            failure = Self.makeFailure(error, stage: .clean, progress: progress)
            phase = .failed
            return
        }

        guard let finished else {
            // The stream ended without cmm's own summary. The app does not make one up.
            failure = Self.makeFailure(
                CmmError.endedWithoutSummary(status: 0, stderr: ""), stage: .clean, progress: progress
            )
            phase = .failed
            return
        }
        summary = CleanSummary(done: finished, items: progress.items, unreadableLines: progress.unreadableLines)
        phase = .done
    }

    /// The Stop button: asks cmm to stop after the item in progress. cmm answers with a `done` event that says
    /// `stopped`, which ends the run in the normal way.
    public func stop() {
        guard phase == .cleaning, !progress.stopRequested else { return }
        progress.stopRequested = true
        client.stop()
    }

    /// Called when the app quits: a running scan or cleanup is asked to stop (a cleanup finishes the item it is on).
    public func shutdown() {
        guard phase == .scanning || phase == .cleaning else { return }
        client.stop()
    }

    // MARK: errors

    private static func makeFailure(_ error: any Error, stage: AppFailure.Stage, progress: CleanProgress?) -> AppFailure {
        var title: String
        var detail: String
        if let error = error as? CmmError {
            title = error.title
            detail = error.detail
        } else if error is CancellationError {
            title = "Cancelled"
            detail = "The operation was cancelled before it finished."
        } else {
            title = stage == .scan ? "Scanning failed" : "Cleaning failed"
            detail = error.localizedDescription
        }

        if let progress {
            var lines: [String] = []
            if progress.stopRequested {
                lines.append("You stopped the cleanup, and cmm ended before it reported a summary.")
            }
            lines.append(detail)
            if !progress.items.isEmpty {
                lines.append("So far: \(progress.deleted) deleted, \(progress.skipped) skipped, \(progress.failed) failed.")
            }
            detail = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return AppFailure(stage: stage, title: title, detail: detail)
    }
}
