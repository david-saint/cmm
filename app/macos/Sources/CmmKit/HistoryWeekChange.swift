import Foundation

/// "Free space is 3.1 GB lower than a week ago." (spec R2)
///
/// The free space now against the note nearest to exactly a week ago, within a day of that moment. With no such note
/// there is nothing to say: the app never guesses, never extrapolates.
public struct WeekChange: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case lower
        case higher
        case aboutTheSame
    }

    /// How far from "a week ago" a note may be and still stand for it.
    public static let reach: TimeInterval = 24 * 3_600
    /// A difference under this is "about the same".
    public static let sameBelowBytes: Int64 = 500_000_000

    public let direction: Direction
    /// How much the free space moved, in bytes, never negative.
    public let difference: Int64
    /// The note it is compared with.
    public let comparedWith: FreeSample
    public let text: String

    public init?(report: HistoryReport, now: Date) {
        let report = report.asOf(now)
        // Nothing to compare when cmm could not read the disk now.
        guard let freeNow = report.host.freeBytes else { return nil }

        // The note nearest to a week ago, and only one within `reach` of it. The notes are oldest first and a tie keeps
        // the earlier one.
        let target = now.addingTimeInterval(-7 * 86_400)
        var nearest: FreeSample?
        var distance = TimeInterval.infinity
        for sample in report.samples {
            let away = abs(sample.t.timeIntervalSince(target))
            if away <= Self.reach, away < distance {
                nearest = sample
                distance = away
            }
        }
        guard let reference = nearest else { return nil }

        let moved = freeNow - reference.freeBytes
        let size = SizeText.string(abs(moved))
        comparedWith = reference
        difference = abs(moved)
        if abs(moved) < Self.sameBelowBytes {
            direction = .aboutTheSame
            text = "Free space is about the same as a week ago."
        } else if moved < 0 {
            direction = .lower
            text = "Free space is \(size) lower than a week ago."
        } else {
            direction = .higher
            text = "Free space is \(size) higher than a week ago."
        }
    }
}
