import CmmKit
import SwiftUI

/// The pane over the screens that have none of their own: the History on its own (`HistoryPane`), whenever the pane is open,
/// on every screen `HistoryPaneRule` gives room to. It is what the menu bar's "Last cleaned" row and "See it in History" open
/// after a cleaning, and what the nothing-to-clean screen's Show details opens.
///
/// It is the window's, as the rest screen's pane is the rest screen's, and it moves as that one does: opening and closing it
/// slides it in from the right edge (with Reduce Motion it fades). When the window goes from one screen to another with the
/// pane open, it fades with the screens instead, so that the pane's place crossfades rather than slides. With nothing to show
/// it is empty space, which takes no clicks.
struct PaneOverlay: View {
    let model: AppModel
    let window: WindowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
        ZStack(alignment: .topTrailing) {
            if HistoryPaneRule.hasRoom(in: model.phase) {
                ZStack(alignment: .topTrailing) {
                    if window.detailsOpen {
                        HistoryPane { withAnimation(motion.animation) { window.closeDetails() } }
                            .padding(HeroLayout.paneInset)
                            .transition(motion.slidesPane ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(motion.animation, value: window.detailsOpen)
    }
}
