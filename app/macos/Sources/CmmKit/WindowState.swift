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
    /// A section the pane should scroll to the next time it can.
    public var scrollTarget: DetailsModel.SectionKind?
    /// Which face of the pane is showing, List or Map. The first open is the map; after that, the one last chosen.
    public var face: DetailsFace
    /// The tile of the map the keyboard is on (`MapTile.id`).
    public var focusedTile: String?
    /// The tile the pointer is on, in the map or by way of its slice in the band. Previews the caption when nothing is
    /// focused, and lights the other one of the pair.
    public var hoveredTile: String?
    /// Changes every time something asks the map to take the keyboard (the review link, a band slice): the map watches it
    /// and focuses itself, because a view cannot be focused from here.
    public private(set) var mapFocusRequest = 0

    public init(detailsOpen: Bool = false, expanded: Set<String> = [], face: DetailsFace = .map) {
        self.detailsOpen = detailsOpen
        self.expanded = expanded
        self.face = face
    }

    public func toggleDetails() {
        detailsOpen ? closeDetails() : openDetails()
    }

    public func openDetails(showing section: DetailsModel.SectionKind? = nil) {
        detailsOpen = true
        scrollTarget = section
    }

    /// Opens the pane on the map, with this tile focused: what the review link and a click on a slice of the band do.
    public func openMap(focusing tile: String?) {
        face = .map
        detailsOpen = true
        scrollTarget = nil
        focusedTile = tile
        mapFocusRequest &+= 1
    }

    /// The List | Map switch.
    public func setFace(_ newFace: DetailsFace) {
        guard newFace != face else { return }
        face = newFace
        hoveredTile = nil
    }

    public func closeDetails() {
        detailsOpen = false
        focusedRow = nil
        focusedTile = nil
        hoveredTile = nil
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
