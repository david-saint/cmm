import CmmKit
import SwiftUI

/// "Safe to remove  8.4 GB", "Review first  9.0 GB", "Held back".
struct SectionHeaderView: View {
    let section: DetailsModel.Section

    var body: some View {
        HStack(spacing: 7) {
            switch section.kind {
            case .safe:
                EmptyView()
            case .review:
                Circle().fill(Theme.review).frame(width: 7, height: 7)
            case .held:
                Image(systemName: "hand.raised.fill").font(.system(size: 11.5))
            }
            Text(section.title)
            Spacer(minLength: 8)
            if let total = section.total {
                Text(total).monospacedDigit()
            }
        }
        .font(Typeface.ui(12, .semibold))
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 18)
        .frame(height: 28)
        .padding(.top, section.kind == .safe ? 0 : 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A group: a round checkbox, its title and what it is, its size, and a chevron. The checkbox ticks the whole group; the
/// rest of the row opens it. For VoiceOver and the keyboard it is one element that does both.
struct GroupRowView: View {
    let row: DetailsModel.GroupRow
    let isFocused: Bool
    let tick: () -> Void
    let expand: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: tick) {
                RoundCheck(state: row.state, size: 18)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(-6)

            Button(action: expand) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(Typeface.ui(14, .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .font(row.subtitleIsMonospaced ? Typeface.mono(10.5) : Typeface.ui(11.5))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(row.subtitleIsMonospaced ? 1 : 2)
                            .lineSpacing(1) // the board's two-line sentence (Docker) sets 15 pt lines
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(row.sizeText)
                        .font(Typeface.ui(14, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 11)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .frame(minHeight: row.subtitleIsMonospaced ? 42 : 52)
        .rowHighlight(focused: isFocused, hovering: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, tick)
        .accessibilityAction(named: row.isExpanded ? "Collapse" : "Expand", expand)
        .padding(.top, row.followsOpenGroup ? 4 : 0)
    }
}

/// An item of an open group: its own checkbox, the path (or the label of a command), the engine's note and its size.
struct ItemRowView: View {
    let row: DetailsModel.ItemRow
    let isFocused: Bool
    let tick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tick) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                RoundCheck(state: row.isTicked ? .on : .off, size: 15)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.title)
                            .font(Typeface.mono(11.5))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(row.sizeText)
                            .font(Typeface.ui(12.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink2)
                    }
                    // A command's note says what runs and what it costs, and where the space goes: it is never cut. It
                    // runs under the size too, so it takes the whole width of the row and wraps as little as it can.
                    if row.showsDetail, let detail = row.detail {
                        Text(detail)
                            .font(Typeface.ui(10.5))
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, 41)
            .padding(.vertical, 4)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .rowHighlight(focused: isFocused, hovering: hovering)
        .onHover { hovering = $0 }
        .help(row.detail.map { "\(row.title)\n\($0)" } ?? row.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits([.isButton])
        .accessibilityAction(.default, tick)
    }
}

/// "Rebuild with npm ci or pod install." in italic New York, under the items of a group.
struct FootnoteView: View {
    let row: DetailsModel.FootnoteRow

    var body: some View {
        Text(row.text)
            .font(Typeface.serif(13).italic())
            .foregroundStyle(Theme.ink2)
            .padding(.leading, 75)
            .padding(.trailing, 18)
            .frame(minHeight: 26, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rule the guards held back, and why. Nothing here can be ticked.
struct HeldRowView: View {
    let row: HeldRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(Theme.ink)
                Text(row.detail)
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let size = row.sizeText {
                Text(size).font(Typeface.ui(12.5)).monospacedDigit().foregroundStyle(Theme.ink2)
            }
        }
        .padding(.leading, 38)
        .padding(.trailing, 18)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.detail)
    }
}

extension View {
    /// A soft highlight for hover and a ring for the keyboard's row, inset like the boards' selected row.
    func rowHighlight(focused: Bool, hovering: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.hover)
                .opacity(focused || hovering ? 1 : 0)
                .padding(.horizontal, 8)
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .padding(.horizontal, 8)
            }
        }
    }
}
