import CmmKit
import SwiftUI

/// "Selected: N items, X GB", Rescan (⌘R) and "Clean N items…".
struct FooterView: View {
    let model: AppModel
    let selection: SelectionModel

    var body: some View {
        HStack(spacing: 12) {
            Text(selection.summaryText)
                .monospacedDigit()
                .accessibilityLabel(selection.summaryText)
            Spacer()
            RescanButton(model: model)
            Button(selection.cleanButtonTitle) {
                model.requestClean()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.selectedCount == 0)
            .accessibilityLabel(selection.cleanButtonTitle)
            .accessibilityHint("Opens a confirmation. Nothing is deleted until you confirm.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// Rescan with ⌘R. Each screen that offers it shows exactly one, so the shortcut is never ambiguous.
struct RescanButton: View {
    let model: AppModel
    var title = "Rescan"

    var body: some View {
        Button(title) {
            Task { await model.scan() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.phase == .scanning || model.phase == .cleaning)
        .help("Check again what can safely go (⌘R)")
        .accessibilityLabel(title)
        .accessibilityHint("Checks again what can safely go")
    }
}
