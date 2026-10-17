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

    /// Whether the History-only pane is up. On the nothing-to-clean screen the pane's own button opens it, whatever face the
    /// window remembers (there is no plan for the List or the map to show). On the others it is up only when the History was
    /// asked for: a pane left open on the List or the map is not the History, and a scan or an error does not turn it into one.
    public static func shows(phase: AppModel.Phase, detailsOpen: Bool, face: DetailsFace) -> Bool {
        detailsOpen && hasRoom(in: phase) && (phase == .empty || face == .history)
    }

    /// A cleaning that starts takes the pane away, whatever it was showing: the result screen that follows must not open
    /// under a pane the person left open, with its buttons beneath it. The History can be asked for again from there.
    public static func closesPane(whenPhaseBecomes phase: AppModel.Phase) -> Bool {
        phase == .cleaning
    }

    /// Show or Hide Details (⌘I): on the two screens with the button for it at the top right, the rest screen and the
    /// nothing-to-clean screen, and never while the confirmation card is up.
    public static func detailsCommandWorks(phase: AppModel.Phase, confirmationOpen: Bool) -> Bool {
        (phase == .ready || phase == .empty) && !confirmationOpen
    }
}
