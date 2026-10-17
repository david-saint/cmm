import Foundation

/// When the History reads cmm's history again of its own accord: when its face appears (the face asks for itself), and when a
/// cleaning ends, because by then cmm has written the cleaning down. Reading more often than needed only looks again; it can
/// never clean.
public enum HistoryRefreshRule {
    /// The window's phase became the done screen (which only ever follows a cleaning, finished or stopped, even when the window
    /// never got to draw the cleaning itself), or went from cleaning to the error screen of a cleaning that failed partway (cmm
    /// may have written down what it did before it failed). A scan that fails is not a cleaning: nothing is read.
    public static func readsAgain(from old: AppModel.Phase, to new: AppModel.Phase) -> Bool {
        (new == .done && old != .done) || (old == .cleaning && new == .failed)
    }
}
