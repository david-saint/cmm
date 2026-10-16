import Foundation

/// How loudly a notification may speak. There is one level: the weekly reminder is never "time sensitive", which would break
/// through a person's Focus for a note about disk space.
public enum NotificationLevel: Sendable {
    case active
}

/// What the weekly reminder says (the board `C-Notification`): a number first, plain words, nothing else. It is made of two
/// numbers and nothing that names anything, so it cannot hold a path, a group or Docker's figure.
public struct WeeklyNotification: Equatable, Sendable {
    /// The same one every week, so each Monday's note replaces last week's in Notification Center instead of piling up.
    public static let identifier = "cmm.weekly-reminder"
    /// It speaks only when at least this much can go (and something can)...
    public static let atLeastBytes: Int64 = 2_000_000_000
    /// ... or when free space is under this and something can go.
    public static let freeBelowBytes: Int64 = 15_000_000_000
    /// `Only` before the free space under this: the amber dot of the menu bar, in a notification that is plain text.
    public static let onlyBelowBytes: Int64 = 10_000_000_000

    public let identifier: String
    /// `19.8 GB free`, or `Only 8.1 GB free` under 10 GB.
    public let title: String
    /// `8 GB can go.`: whole gigabytes rounded down, and `Under 1 GB can go.` below one, never `0 GB`.
    public let body: String
    public let level: NotificationLevel

    /// The note for this much free and this much that can go, or nil when there is nothing to say: nothing can go (no
    /// notification at all, not even an all clear), or less than 2 GB can go and there is room to spare.
    public init?(free: Int64, canGo: Int64) {
        guard canGo > 0, canGo >= Self.atLeastBytes || free < Self.freeBelowBytes else { return nil }
        let size = SizeText.string(free)
        let gigabytes = canGo / 1_000_000_000
        identifier = Self.identifier
        title = free < Self.onlyBelowBytes ? "Only \(size) free" : "\(size) free"
        body = gigabytes >= 1 ? "\(gigabytes) GB can go." : "Under 1 GB can go."
        level = .active
    }
}
