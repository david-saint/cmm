import Foundation

/// What the rest screen's headline says.
///
/// While everything safe is ticked and nothing from review is, it is the headline the app has always had: how much is
/// safe to remove ("8.4 GB is safe to remove."), whatever happens to be ticked. With any other selection it follows what
/// is ticked, the number the pill carries ("3.9 GB will go."), and says what else is there: the safe bytes that are not
/// ticked, and what is left to review. A clause that would say nothing (zero bytes) is left out.
///
/// What will go includes what is freed inside another program's storage (Docker's prunes), as the pill does; what the
/// disk gets back, which is what "after" says, never does (that is `RestCopy`'s caption).
public struct Headline: Equatable, Sendable {
    /// The big number.
    public let number: SizeText.Parts
    /// `is safe to remove.` or `will go.`
    public let sentence: String
    /// The line under it, or nil when there is nothing to say.
    public let body: String?
    /// False in the first state described above.
    public let followsSelection: Bool

    public init(selection: SelectionModel) {
        let selected = selection.selectedBytes
        let safeTicked = selected - selection.selectedReviewBytes
        followsSelection = !(safeTicked == selection.plannedBytes && selection.selectedReviewBytes == 0)

        guard followsSelection else {
            number = SizeText.parts(selection.plannedBytes)
            sentence = "is safe to remove."
            body = HeroBody.text(for: selection)
                ?? (selection.reviewBytes > 0 ? "Nothing regenerable was found. What cmm offers for review is your call." : nil)
            return
        }

        number = SizeText.parts(selected)
        sentence = "will go."

        var clauses: [String] = []
        let safeLeft = selection.plannedBytes - safeTicked
        if safeLeft > 0 {
            clauses.append("\(SizeText.string(safeLeft)) more is safe to remove.")
        }
        // what is still to review, by group, so one group can be named and several cannot
        var leftToReview: [(name: String, bytes: Int64)] = []
        for group in selection.groups(in: .review) {
            let left = group.items.reduce(Int64(0)) { selection.isTicked($1) ? $0 : $0 + $1.bytes }
            if left > 0 { leftToReview.append((RuleCatalog.mapTitle(rule: group.rule, label: group.name), left)) }
        }
        let reviewLeft = leftToReview.reduce(Int64(0)) { $0 + $1.bytes }
        if reviewLeft > 0 {
            let size = SizeText.string(reviewLeft)
            if leftToReview.count == 1, let only = leftToReview.first {
                clauses.append("\(Self.possessive(only.name)) \(size) is yours to review.")
            } else {
                clauses.append("\(size) is yours to review.")
            }
        }
        body = clauses.isEmpty ? nil : clauses.joined(separator: " ")
    }

    /// `Docker's`, and `Old downloads'` for a name that ends in an s.
    public static func possessive(_ name: String) -> String {
        name.lowercased().hasSuffix("s") ? "\(name)'" : "\(name)'s"
    }
}
