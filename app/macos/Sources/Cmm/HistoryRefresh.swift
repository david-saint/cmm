import CmmKit
import SwiftUI

/// Reads the history again when a cleaning ends (`HistoryRefreshRule`). It sits on the window's root, not on the History face:
/// while a cleaning runs the window shows the cleaning and done screens and the face is not there to see the end. So when the
/// person goes back to the pane, the cleaning they just made is in the list already. It only ever asks the History model to
/// read; it starts nothing else.
struct HistoryRefresh: ViewModifier {
    let phase: AppModel.Phase
    @Environment(HistoryModel.self) private var history: HistoryModel?

    func body(content: Content) -> some View {
        content.onChange(of: phase) { old, new in
            guard HistoryRefreshRule.readsAgain(from: old, to: new), let history else { return }
            Task { await history.load() }
        }
    }
}
