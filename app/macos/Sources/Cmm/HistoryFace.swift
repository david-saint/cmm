import CmmKit
import SwiftUI

/// The History face of the Details pane. This is only the place it will be drawn: the face switch works and the pane has
/// something to show, until the real face (the boards `C-History*`) replaces this body.
struct HistoryFace: View {
    var body: some View {
        Text("History")
            .font(Typeface.ui(13))
            .foregroundStyle(Theme.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("History")
    }
}
