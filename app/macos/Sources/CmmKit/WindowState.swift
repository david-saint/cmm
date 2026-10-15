import Foundation
import Observation

/// What the window remembers about itself, apart from the plan: whether the Details pane is open, which groups are
/// open, where the keyboard is, and what Esc closes. It lives here, and not in the views, so the rules can be tested.
@MainActor
@Observable
public final class WindowState {
    public var detailsOpen: Bool
    /// The ids (`PlanGroup.id`) of the groups that are open in the list.
    public var expanded: Set<String>
    /// The row the keyboard is on (`DetailsModel` row ids).
    public var focusedRow: String?
    /// A section the pane should scroll to the next time it can, set by the review link.
    public var scrollTarget: DetailsModel.SectionKind?

    public init(detailsOpen: Bool = false, expanded: Set<String> = []) {
        self.detailsOpen = detailsOpen
        self.expanded = expanded
    }

    public func toggleDetails() {
        detailsOpen ? closeDetails() : openDetails()
    }

    public func openDetails(showing section: DetailsModel.SectionKind? = nil) {
        detailsOpen = true
        scrollTarget = section
    }

    public func closeDetails() {
        detailsOpen = false
        focusedRow = nil
    }

    public func toggleExpanded(_ groupID: String) {
        setExpanded(groupID, !expanded.contains(groupID))
    }

    public func setExpanded(_ groupID: String, _ open: Bool) {
        if open { expanded.insert(groupID) } else { expanded.remove(groupID) }
    }

    /// Esc: the confirmation card goes first, then the pane. Returns whether it closed anything.
    @discardableResult
    public func escape(confirmationOpen: Bool, cancelConfirmation: () -> Void) -> Bool {
        if confirmationOpen {
            cancelConfirmation()
            return true
        }
        if detailsOpen {
            closeDetails()
            return true
        }
        return false
    }
}
