import CmmKit
import SwiftUI

/// The History on its own, in the pane's glass, for the screens that have no plan to list or map (`HistoryPaneRule`): the
/// title and the button that hides the pane, then the History face where the rest screen's pane has it (78 pt down), so the
/// face stays put when the window goes from one screen to the other. The rest screen keeps its own pane, with the
/// List | Map | History switch. Where the pane goes, and how it comes and goes, is the window's (`PaneOverlay`).
struct HistoryPane: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text("History")
                    .font(Typeface.ui(14, .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.leading, 18)
                    .padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                // where the rest screen's pane has its Hide details, the rightmost of its two buttons
                Button(action: close) {
                    Image(systemName: "sidebar.trailing").font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(CircleIconStyle(active: true))
                .help("Hide History (Esc)")
                .accessibilityLabel("Hide History")
                .padding(.top, 8)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
            .frame(height: HeroLayout.paneContentTop, alignment: .topLeading)
            HistoryFace()
        }
        .frame(width: HeroLayout.paneWidth)
        .frame(maxHeight: .infinity)
        .glassSurface(radius: 16, tint: Theme.paneTint, shadow: Theme.paneShadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History")
        .accessibilityIdentifier("history-pane")
    }
}
