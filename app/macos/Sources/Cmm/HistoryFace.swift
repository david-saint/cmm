import CmmKit
import SwiftUI

/// The History face of the Details pane (the boards `C-History`, `C-History-Dark` and `C-History-States`): what past cleanings
/// gave the disk back and how its free space has moved. It draws what `HistoryPresentation` says and decides nothing; it asks
/// the History model for a report each time it appears, and says so only when a read takes longer than a moment.
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
                let state = givenState ?? ownState
                HistoryFaceContent(
                    presentation: history.presentation(
                        historyEnabled: settings?.historyEnabled ?? true, now: env.now(), calendar: env.calendar,
                        locale: env.locale, home: env.home
                    ),
                    phase: history.phase,
                    state: state,
                    retry: { Task { await history.load() } }
                )
                .task { await history.load() }
                .onChange(of: history.isLoading, initial: true) { _, reading in state.readingChanged(reading) }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The face: the paragraph, the chart and the words under it, then the weeks of cleanings, scrolling as one sheet like the
/// List. Before there is a report it says only that it is reading, or that it could not read, with Retry; once there is one,
/// that report stays, and either of those is a quiet line at the foot.
struct HistoryFaceContent: View {
    let presentation: HistoryPresentation?
    let phase: HistoryModel.Phase
    let state: HistoryFaceState
    let retry: () -> Void
    @Environment(\.cmm) private var env
    /// The list has the keyboard: it is one stop for the Tab key (or a click on a row), and inside it the List's keys work.
    @FocusState private var listFocused: Bool

    /// The board's column: the pane less 18 pt on each side.
    static let width = HeroLayout.paneWidth - 36

    var body: some View {
        let status = HistoryReadStatus(phase: phase, showsReading: state.showsReading)
        let rows = presentation?.rows.listed ?? []
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let presentation {
                            face(presentation)
                        } else {
                            alone(status)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .modifier(PaneKeys { key in
                    let action = HistoryNavigation.handle(key, focused: state.focusedRun, rows: rows, expanded: state.expanded)
                    state.follow(action)
                    if case .focus(let run) = action { proxy.scrollTo("run:\(run)") }
                })
            }
            if presentation != nil, status != .quiet {
                HistoryReadFooter(status: status, retry: retry)
            }
        }
    }

    /// A click on a cleaning gives the list the keyboard on that row, and opens or closes it.
    private func click(_ row: RunRows.Row) {
        state.focusedRun = row.id
        listFocused = true
        if row.hasDetails { state.toggle(row.id) }
    }

    /// With no report yet: nothing for the first moment, then that it is reading, or the one sentence of a failure and Retry.
    @ViewBuilder
    private func alone(_ status: HistoryReadStatus) -> some View {
        switch status {
        case .quiet:
            EmptyView()
        case .reading:
            Text(HistoryReadStatus.readingText)
                .font(Typeface.ui(12.5))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 18)
                .padding(.top, 4)
        case .failed(let sentence, let detail):
            VStack(alignment: .leading, spacing: 14) {
                HistoryParagraph(text: sentence)
                    .help(detail)
                HistoryRetryButton(action: retry, height: 28, fontSize: 12.5)
                    .padding(.horizontal, 18)
            }
        }
    }

    @ViewBuilder
    private func face(_ presentation: HistoryPresentation) -> some View {
        let chart = presentation.timeline?.chart
        if let summary = presentation.summary {
            HistoryParagraph(text: summary)
                // the chart reads these same words to VoiceOver, once
                .accessibilityHidden(chart != nil)
                .padding(.bottom, chart != nil ? 10 : 12)
        }
        if let timeline = presentation.timeline {
            if let chart {
                HistoryChart(
                    layout: HistoryChartLayout(chart: chart, width: Self.width, calendar: env.calendar, locale: env.locale),
                    label: presentation.chartLabel, state: state
                )
                .padding(.horizontal, 18)
            }
            if let caption = timeline.caption {
                // "History fills in as cmm runs: 3 days so far." under a line that is still short
                Text(caption)
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(16 - 13.54)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    // the board leaves about 13 pt between the days under the line and these words
                    .padding(.top, chart != nil ? 8 : 0)
            }
            Color.clear.frame(height: 12)
        }
        if let message = presentation.emptyMessage {
            if chart != nil {
                // a line and no cleaning yet: the words stand where the list will be, quietly
                Text(message)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            } else {
                HistoryParagraph(text: message)
            }
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
                    row: row, isExpanded: state.expanded.contains(row.id),
                    isFocused: (listFocused || env.showsFocusWithoutKeyboard) && state.focusedRun == row.id,
                    toggle: { click(row) }
                )
                .id("run:\(row.id)")
            }
        }
    }
}

/// The quiet line at the foot of the face while it keeps showing the last report: "Reading the history…", or the one sentence
/// of a failure, with Retry. It takes its room from the list's sheet, so nothing above it moves.
struct HistoryReadFooter: View {
    let status: HistoryReadStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .quiet:
                Spacer(minLength: 0)
            case .reading:
                Text(HistoryReadStatus.readingText)
                Spacer(minLength: 0)
            case .failed(let sentence, let detail):
                Text(sentence)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
                Spacer(minLength: 8)
                HistoryRetryButton(action: retry, height: 22, fontSize: 11.5)
            }
        }
        .font(Typeface.ui(11.5))
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hair).frame(height: 1).padding(.horizontal, 18)
        }
    }
}

/// Retry: a soft pill, like the app's other second buttons. It only asks the History model to read again.
struct HistoryRetryButton: View {
    let action: () -> Void
    let height: Double
    let fontSize: Double

    var body: some View {
        Button(action: action) {
            Text(HistoryReadStatus.retryTitle)
        }
        .buttonStyle(PillStyle(look: .soft(text: Theme.ink), height: height, horizontal: height / 2, fontSize: fontSize, shadowed: false))
        .accessibilityHint(HistoryReadStatus.retryHint)
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
