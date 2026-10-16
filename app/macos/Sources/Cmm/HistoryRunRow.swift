import CmmKit
import SwiftUI

// The list of the History face (the boards `C-History` and `C-History-States`): the weeks, a row per cleaning, and the items
// a row opens to. They draw what `RunRows` says and nothing else.

/// "This week   5.4 GB": a week of the list and what it gave the disk back. Every week after the first has a hairline above.
struct HistoryWeekHeader: View {
    let week: RunRows.Week
    let isFirst: Bool
    /// The row above is open, and its ground needs a little more room before the hairline.
    let followsOpenRow: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Theme.hair).frame(height: 1)
            }
            HStack(spacing: 8) {
                Text(week.title)
                Spacer(minLength: 8)
                Text(week.totalText).monospacedDigit()
            }
            .font(Typeface.ui(11.5, .semibold))
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .frame(height: 26)
        }
        .padding(.horizontal, 18)
        .padding(.top, isFirst ? 0 : (followsOpenRow ? 6 : 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(week.spoken)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A cleaning: when it ended and what the disk got back, then the groups that went, what stopped it or failed, and, apart from
/// all of it, what was freed inside another program's storage. A click opens it to its items, like a group of the List.
struct HistoryRunRow: View {
    let row: RunRows.Row
    let isExpanded: Bool
    let isFocused: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                summary.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.spoken)
            .accessibilityValue(row.hasDetails ? (isExpanded ? "expanded" : "collapsed") : "")
            .accessibilityAddTraits(.isButton)

            if isExpanded, row.hasDetails {
                HistoryRunItems(row: row)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, isExpanded ? 6 : 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isExpanded ? Theme.historyOpenRow : Theme.nothing)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hover).opacity(hovering ? 1 : 0)
                }
                .padding(.horizontal, 8)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .padding(.horizontal, 8)
            }
        }
        .onHover { hovering = $0 }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.dateText)
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(Theme.ink)
                Text(row.timeText)
                    .font(Typeface.ui(12))
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                // A cleaning that gave the disk nothing back says so in the quiet ink.
                Text(row.freedText)
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(row.freedBytes > 0 ? Theme.ink : Theme.ink2)
                if row.hasDetails {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
            }
            .monospacedDigit()
            .lineLimit(1)

            if row.stoppedText != nil || row.groupsText != nil || row.failedText != nil {
                secondLine.padding(.top, 3)
            }
            if let inside = row.insideText {
                HistoryInsideChip(text: inside).padding(.top, 4)
            }
        }
    }

    /// `Stopped after 2 of 9 · Idle lane dependencies · ✕ 1 failed`: the groups give way (and are cut short) before the words
    /// about what stopped or failed do.
    private var secondLine: some View {
        HStack(spacing: 6) {
            if let stopped = row.stoppedText {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Theme.ink2)
                    Text(stopped)
                        .font(Typeface.ui(11.5, .medium))
                        .foregroundStyle(Theme.ink)
                }
                .fixedSize()
            }
            if let groups = row.groupsText {
                if row.stoppedText != nil { Text("·") }
                // SF sets a little wider here than the board's browser did: the line may close up a touch before it is cut.
                Text(groups)
                    .allowsTightening(true)
                    .truncationMode(.tail)
            }
            if let failed = row.failedText {
                if row.stoppedText != nil || row.groupsText != nil { Text("·") }
                HStack(spacing: 4) {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                    Text(failed).font(Typeface.ui(11.5, .semibold))
                }
                .foregroundStyle(Theme.fail)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(Typeface.ui(11.5))
        .monospacedDigit()
        .foregroundStyle(Theme.ink2)
        .lineLimit(1)
    }
}

/// `9.0 GB inside Docker's disk image, not counted`: in amber, in a dotted outline, apart from the figure the disk got back.
struct HistoryInsideChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.ui(11))
            .monospacedDigit()
            .foregroundStyle(Theme.reviewText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay {
                // CSS's 1 px dotted border: square dots one point apart
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.review, style: StrokeStyle(lineWidth: 1, lineCap: .butt, dash: [1, 1]))
            }
    }
}

/// What an open cleaning lists: its items, largest first, what did not fit in cmm's line, and what the disk's free space did.
struct HistoryRunItems: View {
    let row: RunRows.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(row.items) { item in
                HistoryItemRow(item: item)
            }
            if let omitted = row.omittedText {
                Text(omitted)
                    .font(Typeface.ui(11))
                    .foregroundStyle(Theme.ink2)
                    .frame(height: 22, alignment: .leading)
                    .padding(.leading, 24)
            }
            if let footnote = row.footnote {
                Text(footnote)
                    .font(Typeface.serif(12.5).italic())
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(height: 22, alignment: .leading)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 2)
    }
}

/// An item of an open cleaning: a tick or a cross, the path in the mono face (a command's label as it is), what became of it,
/// and its size. A size that went inside another program's storage is amber, like the line that says so.
struct HistoryItemRow: View {
    let item: RunRows.Item

    var body: some View {
        HStack(spacing: 8) {
            mark.frame(width: 16, alignment: .leading)
            (Text(item.title).font(Typeface.mono(11)).foregroundStyle(Theme.ink)
                + Text(" \u{00B7} \(item.detail)").font(Typeface.ui(11)).foregroundStyle(item.status == .failed ? Theme.fail : Theme.ink2))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(item.sizeText)
                .font(Typeface.ui(11.5))
                .monospacedDigit()
                .foregroundStyle(item.insidePlace == nil ? Theme.ink2 : Theme.reviewText)
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spoken)
    }

    @ViewBuilder private var mark: some View {
        switch item.status {
        case .deleted:
            CheckShape()
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 10)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.fail)
        case .other:
            Image(systemName: "minus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.ink2)
        }
    }
}
