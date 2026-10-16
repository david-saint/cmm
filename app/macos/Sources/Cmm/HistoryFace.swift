import CmmKit
import SwiftUI

/// The History face of the Details pane (the boards `C-History`, `C-History-Dark` and `C-History-States`): what past cleanings
/// gave the disk back and how its free space has moved. It draws what `HistoryPresentation` says and decides nothing; it asks
/// the History model for a report each time it appears.
struct HistoryFace: View {
    @Environment(HistoryModel.self) private var history: HistoryModel?
    @Environment(SettingsModel.self) private var settings: SettingsModel?
    /// A test's own state, to draw a given moment. The face makes its own otherwise, so it opens at rest each time.
    @Environment(HistoryFaceState.self) private var givenState: HistoryFaceState?
    @Environment(\.cmm) private var env
    @State private var ownState = HistoryFaceState()

    var body: some View {
        Group {
            if let history {
                HistoryFaceContent(
                    presentation: history.presentation(
                        historyEnabled: settings?.historyEnabled ?? true, now: env.now(), calendar: env.calendar,
                        locale: env.locale, home: env.home
                    ),
                    state: givenState ?? ownState
                )
                .task { await history.load() }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The face once there is something to show: the paragraph, then the weeks of cleanings. It scrolls as one sheet, like the List.
struct HistoryFaceContent: View {
    let presentation: HistoryPresentation?
    let state: HistoryFaceState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let presentation {
                    face(presentation)
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func face(_ presentation: HistoryPresentation) -> some View {
        if let summary = presentation.summary {
            HistoryParagraph(text: summary)
                .padding(.bottom, 12)
        }
        if let message = presentation.emptyMessage {
            HistoryParagraph(text: message)
        }
        weeks(presentation.rows)
        if let footnote = presentation.rows.footnote {
            Text(footnote)
                .font(Typeface.serif(12.5).italic())
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 18)
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func weeks(_ rows: RunRows) -> some View {
        ForEach(Array(rows.weeks.enumerated()), id: \.element.id) { index, week in
            let previous = index > 0 ? rows.weeks[index - 1].rows.last : nil
            HistoryWeekHeader(
                week: week, isFirst: index == 0, followsOpenRow: previous.map { state.expanded.contains($0.id) } ?? false
            )
            .id("week:\(week.id)")
            ForEach(week.rows) { row in
                HistoryRunRow(
                    row: row, isExpanded: state.expanded.contains(row.id), isFocused: false,
                    toggle: { if row.hasDetails { state.toggle(row.id) } }
                )
                .id("run:\(row.id)")
            }
        }
    }
}

/// The paragraph at the top of the face, in New York as the boards set it: 17 pt on 24 pt lines.
struct HistoryParagraph: View {
    let text: String

    var body: some View {
        // New York at 17 pt sets its lines 20.3 pt apart; the board's line is 24, so the rest is added, half of it under the
        // last line (the half above the first is where the face begins, two points above the board's 76).
        let extra = 24 - 20.29
        Text(text)
            .font(Typeface.serif(17))
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .lineSpacing(extra)
            .padding(.bottom, extra / 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
    }
}
