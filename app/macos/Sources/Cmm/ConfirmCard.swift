import CmmKit
import SwiftUI

/// How big the card turned out, so the placement can keep a taller card (the sentence about space freed inside Docker's
/// disk image wraps to a second line) inside the window.
struct CardSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// "Delete 9 items (8.4 GB)?" on a glass card that grows out of the Clean pill.
///
/// Cancel is the filled default on the left and carries `.defaultAction`, so Return presses it; Delete is the red
/// button beside it and has no shortcut, so a stray Return never deletes. The card is not a system sheet or alert (those
/// choose their own default button): the screen behind it is dimmed and disabled, which is also what traps the keyboard
/// focus inside the card, and Esc (handled in `RootView`) cancels. The count and the size come from the frozen selection.
struct ConfirmCard: View {
    let confirmation: CleanConfirmation
    let cancel: () -> Void
    let delete: () -> Void
    @FocusState private var cancelFocused: Bool

    /// What the placement needs to know about the card's size.
    static let size = CGSize(width: CardPlacement.width, height: CardPlacement.height)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(confirmation.prompt)
                .font(Typeface.ui(19, .bold))
                .tracking(-0.19)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(height: 22, alignment: .leading)
            Text(confirmation.detail)
                .font(Typeface.ui(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 20, alignment: .leading)
                .padding(.top, 6)
            if let after = confirmation.afterText {
                Text(after)
                    .font(Typeface.ui(14))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .frame(minHeight: 20, alignment: .leading)
                    .padding(.top, 2)
            }
            // What stays inside another program's storage is said once, under the figure it is not part of.
            if let inside = confirmation.insideText {
                Text(inside)
                    .font(Typeface.ui(13))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 20, alignment: .leading)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button(action: cancel) {
                    HStack(spacing: 10) {
                        Text(confirmation.cancelTitle)
                        Text("↩")
                            .font(Typeface.ui(12, .medium))
                            .opacity(0.6)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(PillStyle(look: .solid, height: 44, horizontal: 22, fontSize: 15))
                .keyboardShortcut(.defaultAction)
                .focused($cancelFocused)
                .accessibilityLabel("Cancel")
                .accessibilityHint("Closes this card and deletes nothing")

                Button(role: .destructive, action: delete) {
                    Text(confirmation.deleteTitle)
                }
                .buttonStyle(PillStyle(look: .soft(text: Theme.deleteLabel), height: 44, horizontal: 22, fontSize: 15, shadowed: false))
                .accessibilityLabel(confirmation.accessibilityLabel)
                .accessibilityHint("Deletes the selected items. Each one is checked again right before it is removed.")
            }
            .padding(.top, 20)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: CardPlacement.width, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CardSizeKey.self, value: proxy.size)
        })
        .glassSurface(radius: 28, tint: Theme.cardTint, shadow: Theme.cardShadow, nearShadow: Theme.cardNearShadow)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Confirm: \(confirmation.accessibilityLabel)")
        .onAppear { cancelFocused = true }
    }
}
