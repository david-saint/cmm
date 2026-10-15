import CmmKit
import SwiftUI

/// The picture of a checkbox: empty, checked or dashed. Shape carries the meaning, not color, so it reads the
/// same in light and dark and for people who do not see color.
struct CheckGlyph: View {
    let state: TriState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .off: "square"
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        }
    }
}

/// A checkbox button with three states, for a group of items.
struct TriStateCheckbox: View {
    let state: TriState
    /// What VoiceOver says, for example "Select Go build cache".
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CheckGlyph(state: state)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(valueDescription)
        .accessibilityHint("Selects or clears every item in the group")
        .accessibilityAddTraits(.isToggle)
    }

    private var valueDescription: String {
        switch state {
        case .off: "not selected"
        case .on: "selected"
        case .mixed: "partly selected"
        }
    }
}
