import Foundation

/// Everything that can go wrong between the app and the cmm program. Each case reads well in a window: `title` is
/// the headline and `detail` says what happened and what to do about it.
public enum CmmError: Error, Equatable, Sendable {
    /// The cmm program is not where the app expects it.
    case binaryNotFound(path: String)
    /// The operating system refused to start cmm.
    case launchFailed(String)
    /// A second cmm was requested while one is still running.
    case busy
    /// `cmm plan --json` exited with a non-zero status.
    case planFailed(status: Int32, stderr: String)
    /// The plan is not the JSON the app expects.
    case malformedPlan(String)
    /// The plan is valid JSON of a schema this app does not read.
    case unsupportedSchema(found: Int)
    /// The file that carries the ticked paths to cmm could not be written.
    case selectionFileFailed(String)
    /// `cmm apply` ended with an error and without a summary.
    case applyFailed(status: Int32, stderr: String)
    /// `cmm apply` ended (cleanly, as far as its exit status goes) without the final summary event.
    case endedWithoutSummary(status: Int32, stderr: String)
}

extension CmmError {
    public var title: String {
        switch self {
        case .binaryNotFound: "cmm was not found"
        case .launchFailed: "cmm could not be started"
        case .busy: "cmm is already running"
        case .planFailed: "cmm could not make a plan"
        case .malformedPlan: "cmm's plan could not be read"
        case .unsupportedSchema: "This app cannot read cmm's plan"
        case .selectionFileFailed: "Nothing was cleaned"
        case .applyFailed: "cmm stopped with an error"
        case .endedWithoutSummary: "cmm ended without a summary"
        }
    }

    public var detail: String {
        switch self {
        case .binaryNotFound(let path):
            "Looked for it at \(path). The app carries its own copy inside Cmm.app (Contents/Resources/cmm); "
                + "while developing, set CMM_BIN to a built cmm."
        case .launchFailed(let reason):
            reason
        case .busy:
            "Wait for the current scan or clean to finish."
        case .planFailed(let status, let stderr):
            Self.joined("Exit status \(status).", stderr)
        case .malformedPlan(let reason):
            reason
        case .unsupportedSchema(let found):
            "The plan uses schema \(found), but this app reads schema 1. Update the app and cmm so they match."
        case .selectionFileFailed(let reason):
            "The list of ticked items could not be handed to cmm (\(reason)). Nothing was removed."
        case .applyFailed(let status, let stderr):
            Self.joined("Exit status \(status). What cmm reported before it stopped is listed below; scan again to see what is left.", stderr)
        case .endedWithoutSummary(let status, let stderr):
            Self.joined("Exit status \(status). The results listed below may be incomplete; scan again to see what is left.", stderr)
        }
    }

    private static func joined(_ headline: String, _ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? headline : "\(headline)\n\(text)"
    }
}

extension CmmError: LocalizedError {
    public var errorDescription: String? {
        detail.isEmpty ? title : "\(title). \(detail)"
    }
}
