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
    /// Which face of the pane is showing, List, Map or History. The first open is the map; after that, the one last chosen.
    public var face: DetailsFace
    /// The tile of the map the keyboard is on (`MapTile.id`).
    public var focusedTile: String?
    /// The tile the pointer is on, in the map or by way of its slice in the band. Previews the caption when nothing is
    /// focused, and lights the other one of the pair.
    public var hoveredTile: String?
    /// Changes every time something asks the map to take the keyboard (the review link, a band slice): the map watches it
    /// and focuses itself, because a view cannot be focused from here.
    public private(set) var mapFocusRequest = 0
    /// The map has the keyboard (so the band rings the focused tile's slice only when its tile is ringed too).
    public var mapKeyboard = false
    /// The pointer is on the disk band, where the reclaimable end is shown enlarged.
    public var bandHovered = false
    /// The slice the pointer put into `hoveredTile`, so that leaving the band clears that hover and only that one.
    private var sliceUnderPointer: String?
    /// Whether slices fly into tiles and back. Off with Reduce Motion, where the pane fades in place.
    public var flightsEnabled = true
    /// The slices flying between the band and the map, or nil when nothing is.
    public private(set) var flight: Flight?
    private var flightCount = 0

    public enum FlightKind: Equatable, Sendable {
        /// The band's slices lift off and become the map's tiles.
        case unfold
        /// The tiles go back into the band.
        case fold
    }

    /// One flight. It begins in the same change as the pane opens or closes, so the views never draw a frame of the map's
    /// tiles in the wrong place first; whoever draws it lands it when its time is up.
    public struct Flight: Equatable, Sendable {
        public let kind: FlightKind
        /// Tells this flight from every one before it, so a late timer cannot land a later flight.
        public let generation: Int
        /// The pane was already open (on the list) when the slices left: the band was the narrow one.
        public let paneWasOpen: Bool
        /// The pointer was on the band: its end was already enlarged.
        public let bandWasMagnified: Bool
        public let startedAt: Date
    }

    public init(detailsOpen: Bool = false, expanded: Set<String> = [], face: DetailsFace = .map) {
        self.detailsOpen = detailsOpen
        self.expanded = expanded
        self.face = face
    }

    /// The pointer entered or left a tile of the map.
    public func pointer(onTile tile: String, inside: Bool) {
        if inside {
            hoveredTile = tile
        } else if hoveredTile == tile {
            hoveredTile = nil
        }
    }

    /// The pointer is on the band, over this slice (nil: over the band but not over a slice).
    public func pointerIsOnBand(over slice: String?) {
        bandHovered = true
        sliceUnderPointer = slice
        if hoveredTile != slice { hoveredTile = slice }
    }

    public func pointerLeftTheBand() {
        bandHovered = false
        if let slice = sliceUnderPointer, hoveredTile == slice { hoveredTile = nil }
        sliceUnderPointer = nil
    }

    /// The pane is open and showing the map.
    public var mapOpen: Bool { detailsOpen && face == .map }

    /// The band's end is shown enlarged: while the pointer is on the band, and for as long as the map is open.
    public var isBandMagnified: Bool { bandHovered || mapOpen }

    public func toggleDetails() {
        detailsOpen ? closeDetails() : openDetails()
    }

    public func openDetails(showing section: DetailsModel.SectionKind? = nil) {
        let (wasOpen, wasMapOpen) = (detailsOpen, mapOpen)
        detailsOpen = true
        scrollTarget = section
        if mapOpen, !wasMapOpen { beginFlight(.unfold, paneWasOpen: wasOpen) }
    }

    /// Opens the pane on the map, with this tile focused: what the review link and a click on a slice of the band do.
    public func openMap(focusing tile: String?) {
        let (wasOpen, wasMapOpen) = (detailsOpen, mapOpen)
        face = .map
        detailsOpen = true
        scrollTarget = nil
        focusedTile = tile
        mapFocusRequest &+= 1
        if !wasMapOpen { beginFlight(.unfold, paneWasOpen: wasOpen) }
    }

    /// The List | Map | History switch. Leaving the map takes the keyboard back from it; switching faces never flies.
    public func setFace(_ newFace: DetailsFace) {
        guard newFace != face else { return }
        face = newFace
        hoveredTile = nil
        if newFace != .map { mapKeyboard = false }
    }

    /// Opens the pane on the History face: what the menu bar's "Last cleaned" row does. It only looks: nothing is asked of
    /// the list, the map or the plan.
    public func openHistory() {
        setFace(.history)
        detailsOpen = true
        scrollTarget = nil
    }

    public func closeDetails() {
        let wasMapOpen = mapOpen
        detailsOpen = false
        focusedRow = nil
        focusedTile = nil
        hoveredTile = nil
        mapKeyboard = false
        if wasMapOpen { beginFlight(.fold, paneWasOpen: true) }
    }

    private func beginFlight(_ kind: FlightKind, paneWasOpen: Bool) {
        guard flightsEnabled else { return }
        flightCount &+= 1
        flight = Flight(
            kind: kind, generation: flightCount, paneWasOpen: paneWasOpen, bandWasMagnified: bandHovered, startedAt: Date()
        )
    }

    /// The flight is over: the tiles take over from the shapes that flew. With a generation, only that flight is landed.
    public func landFlight(_ generation: Int? = nil) {
        guard let flight, generation == nil || flight.generation == generation else { return }
        self.flight = nil
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
