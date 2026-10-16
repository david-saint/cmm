import Foundation

extension WindowState {
    /// The window at rest, however it is opened (the menu bar item, the notification, the Dock): the Details pane closed, and
    /// nothing focused, hovered or flying. The pane closes without the fold's flight: nobody saw it open. The ticks are left as
    /// they are, because they are the person's (the weekly reminder goes out of its way not to reset them either).
    public func comeToRest() {
        if detailsOpen { closeDetails() }
        landFlight()
        pointerLeftTheBand()
        focusedRow = nil
        focusedTile = nil
        hoveredTile = nil
        mapKeyboard = false
        scrollTarget = nil
    }

    /// What the menu bar item's "Last cleaned" row does: the window at rest, with the Details pane open on the History face.
    public func comeToRestOnHistory() {
        comeToRest()
        openHistory()
    }
}
