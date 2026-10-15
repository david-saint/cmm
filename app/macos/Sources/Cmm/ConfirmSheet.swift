import CmmKit
import SwiftUI

/// "Delete N items (X GB)? Each item is checked again right before it is removed."
///
/// It is a plain sheet rather than an alert or a confirmation dialog, because those pick their own default button.
/// Here Cancel is the default (it carries `.defaultAction`) and Clean has no shortcut, so a stray Return never
/// deletes. However else the sheet is dismissed, the binding in RootView cancels the confirmation. The count and the
/// size come from the frozen selection.
struct ConfirmSheet: View {
    let confirmation: CleanConfirmation
    let cancel: () -> Void
    let clean: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmation.prompt)
                        .font(.headline)
                    Text(confirmation.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Closes this window and deletes nothing")
                Button("Clean", role: .destructive, action: clean)
                    .accessibilityLabel("Clean \(Plural.items(confirmation.itemCount))")
                    .accessibilityHint("Deletes the selected items, \(ByteFormat.string(confirmation.bytes))")
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}
