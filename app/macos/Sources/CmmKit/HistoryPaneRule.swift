import Foundation

/// Where the History can be seen on its own, in a pane over the screen, and when the window's Show Details (⌘I) works.
///
/// The rest screen has its own pane (List | Map | History), so it never needs this one. Every other screen but the cleaning
/// screen shows the History-only pane while the pane is open: before the first scan, while scanning, with nothing to clean,
/// after a cleaning and after an error. It shows whatever face the window remembers, which is kept for the next rest screen
/// (the List and the map need a plan to show). The cleaning screen shows no pane: the person is watching the cleaning.
public enum HistoryPaneRule {
    /// The screens that show the History-only pane while the pane is open.
    public static func hasRoom(in phase: AppModel.Phase) -> Bool {
        switch phase {
        case .idle, .scanning, .empty, .done, .failed: true
        case .ready, .cleaning: false
        }
    }

    public static func shows(phase: AppModel.Phase, detailsOpen: Bool) -> Bool {
        detailsOpen && hasRoom(in: phase)
    }

    /// Show or Hide Details (⌘I): on the two screens with the button for it at the top right, the rest screen and the
    /// nothing-to-clean screen, and never while the confirmation card is up.
    public static func detailsCommandWorks(phase: AppModel.Phase, confirmationOpen: Bool) -> Bool {
        (phase == .ready || phase == .empty) && !confirmationOpen
    }
}
