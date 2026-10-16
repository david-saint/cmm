import CmmKit
import SwiftUI

/// "List | Map | History" under the pane's title: the chosen word in ink, semibold, with a 1.5 pt underline; the others in the
/// secondary ink. Words and hairlines, not a segmented control, so the pane stays one calm sheet of glass.
struct FaceSwitch: View {
    let window: WindowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(DetailsFace.allCases.enumerated()), id: \.element) { index, face in
                if index > 0 { Rectangle().fill(Theme.switchDivider).frame(width: 1, height: 11) }
                word(face)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details view")
    }

    private func word(_ face: DetailsFace) -> some View {
        let selected = window.face == face
        return Button {
            withAnimation(MotionStyle.resolve(reduceMotion: reduceMotion).animation) { window.setFace(face) }
        } label: {
            Text(face.title)
                .font(Typeface.ui(12.5, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .frame(height: 22)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(Theme.ink).frame(height: 1.5) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(face.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(selected ? "" : face.hint)
    }
}
