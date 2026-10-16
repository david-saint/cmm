import Foundation

/// What the History face says about reading the history, apart from the history itself (the boards do not draw it, so it is
/// the quietest it can be): nothing; that it is reading, once a read has taken longer than a moment; or, in one sentence, that
/// it could not, with Retry. Without a report to show, this is all the face says; with one, the report stays and this is a
/// quiet line at its foot.
public enum HistoryReadStatus: Equatable, Sendable {
    case quiet
    case reading
    /// `cmm could not read the history.` The detail (cmm's own words, which can name paths) is kept for the tooltip only.
    case failed(sentence: String, detail: String)

    public static let readingText = "Reading the history\u{2026}"
    public static let retryTitle = "Retry"
    public static let retryHint = "Reads the history again"

    /// A read that is out says so before an old failure does: after Retry, the face says it is reading.
    public init(phase: HistoryModel.Phase, showsReading: Bool) {
        if showsReading {
            self = .reading
        } else if case .failed(let title, let detail) = phase {
            self = .failed(sentence: title.hasSuffix(".") ? title : title + ".", detail: detail)
        } else {
            self = .quiet
        }
    }
}
