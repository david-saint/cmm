import CmmKit
import SwiftUI

// The screens that are not the rest screen: cleaning, done, nothing to clean, scanning and errors. Each is a hero block
// at the top left and, where there is a disk to show, the band at the bottom, as in the boards.

// MARK: cleaning

struct CleaningScreen: View {
    let model: AppModel
    @Environment(\.cmm) private var env

    var body: some View {
        GeometryReader { geometry in
            let layout = HeroLayout(screen: .cleaning, width: geometry.size.width, height: geometry.size.height)
            let s = layout.scale
            let p = CleaningPresentation(progress: model.progress, capacity: model.plan?.host.capacityBytes, home: env.home)

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HeroHeader(layout: layout, eyebrow: p.label, number: p.number, phrase: p.sentence)

                    HStack(spacing: 18 * s) {
                        ProgressLine(fraction: p.fraction, width: 488 * s, label: "Cleaning progress",
                                     value: "\(model.progress.items.count) of \(model.progress.total) items")
                        Button { model.stop() } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "stop.fill").font(.system(size: 10))
                                Text(p.stopTitle)
                            }
                        }
                        .buttonStyle(PillStyle(look: .soft(text: Theme.ink), height: 32, horizontal: 14, leading: 12, fontSize: 13, shadowed: false))
                        .disabled(!p.stopEnabled)
                        .accessibilityLabel("Stop cleaning")
                        .accessibilityHint("Finishes the item in progress, then stops. Items already removed stay removed.")
                    }
                    .padding(.top, 22 * s)

                    VStack(spacing: 0) {
                        ForEach(p.rows) { row in
                            RunningRowView(row: row, scale: s)
                        }
                    }
                    .frame(width: 640 * s, alignment: .leading)
                    .padding(.top, 26 * s)
                    .animation(.easeOut(duration: 0.2), value: p.rows.map(\.id))
                }
                .padding(.leading, layout.leading)
                .padding(.top, layout.top)

                BandBlock(band: p.band, caption: p.caption, sentence: p.bandSentence, layout: layout, insideLine: p.insideLine)
                    .offset(x: layout.bandLeading, y: layout.bandTop)
            }
        }
    }
}

/// A 2 pt line that fills with green as items are reported. It is one element for VoiceOver.
struct ProgressLine: View {
    let fraction: Double
    let width: Double
    let label: String
    let value: String

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.progressTrack)
            Capsule().fill(Theme.accent).frame(width: width * min(max(fraction, 0), 1))
        }
        .frame(width: width, height: 2)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// One line of the cleaning list: a mark, a word, the path and why, and a size. The lines fade as they age.
struct RunningRowView: View {
    let row: CleaningPresentation.Row
    let scale: Double

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            Text(row.word)
                .font(Typeface.ui(12.5 * scale, .semibold))
                .foregroundStyle(tint)
                .frame(width: 78 * scale, alignment: .leading)
            path
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.sizeText)
                .font(Typeface.ui(12.5 * scale))
                .monospacedDigit()
                .foregroundStyle(row.kind == .removing || row.kind == .deleted ? Theme.ink : Theme.ink2)
                .frame(width: 64 * scale, alignment: .trailing)
        }
        .frame(height: 28 * scale)
        .opacity(row.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.word): \(row.path)")
        .accessibilityValue([row.sizeText, row.reason].compactMap { $0 }.joined(separator: ", "))
    }

    private var path: Text {
        let base = Text(row.path).font(Typeface.mono(12 * scale)).foregroundStyle(Theme.ink)
        guard let reason = row.reason else { return base }
        return base + Text(" · \(reason)").font(Typeface.ui(12 * scale)).foregroundStyle(Theme.ink2)
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .removing: SpinnerArc(size: 15 * scale)
        case .deleted: Image(systemName: "checkmark.circle.fill").font(.system(size: 14 * scale)).foregroundStyle(Theme.accent)
        case .skipped: Image(systemName: "hand.raised.fill").font(.system(size: 13 * scale)).foregroundStyle(Theme.skip)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 14 * scale)).foregroundStyle(Theme.fail)
        case .other: Image(systemName: "questionmark.circle.fill").font(.system(size: 14 * scale)).foregroundStyle(Theme.ink2)
        }
    }

    private var tint: Tone {
        switch row.kind {
        case .removing, .deleted: Theme.accentLabel
        case .skipped: Theme.skip
        case .failed: Theme.fail
        case .other: Theme.ink2
        }
    }
}

// MARK: done

struct DoneScreen: View {
    let model: AppModel
    @Environment(\.cmm) private var env

    var body: some View {
        if let summary = model.summary {
            GeometryReader { geometry in
                let layout = HeroLayout(screen: .done, width: geometry.size.width, height: geometry.size.height)
                let p = DonePresentation(
                    summary: summary, capacity: model.plan?.host.capacityBytes,
                    volumeName: model.plan.map { env.volumeName($0) } ?? "", home: env.home,
                    now: env.now(), calendar: env.calendar, locale: env.locale
                )
                ZStack(alignment: .topLeading) {
                    content(p, layout: layout)
                        .padding(.leading, layout.leading)
                        .padding(.top, layout.top)
                    BandBlock(band: p.band, caption: p.caption, sentence: p.bandSentence, layout: layout)
                        .offset(x: layout.bandLeading, y: layout.bandTop)
                }
            }
        }
    }

    private func content(_ p: DonePresentation, layout: HeroLayout) -> some View {
        let s = layout.scale
        return VStack(alignment: .leading, spacing: 0) {
            HeroHeader(layout: layout, eyebrow: p.label, number: p.number, phrase: p.sentence)

            HStack(spacing: 0) {
                ForEach(Array(p.comparison.enumerated()), id: \.offset) { _, run in
                    Text(run.text)
                        .fontWeight(run.emphasized ? .semibold : .regular)
                        .foregroundStyle(run.emphasized ? Theme.accentText : Theme.ink2)
                }
            }
            .font(Typeface.ui(15 * s))
            .monospacedDigit()
            .frame(height: 18 * s) // the boards' line box; SwiftUI's own is a point taller
            .padding(.top, 10 * s)

            // What went inside another program's storage is not in the figures above; it is said once, quietly.
            if let inside = p.insideSentence {
                Text(inside)
                    .font(Typeface.ui(13 * s))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720 * s, alignment: .leading)
                    .padding(.top, 6 * s)
            }

            HStack(spacing: 18 * s) {
                Counter(symbol: "checkmark.circle.fill", text: p.deletedText, color: Theme.accentText)
                Counter(symbol: "hand.raised.fill", text: p.skippedText, color: Theme.skip)
                Counter(symbol: "xmark.circle.fill", text: p.failedText, color: Theme.fail)
            }
            .font(Typeface.ui(13 * s, .semibold))
            .monospacedDigit()
            .frame(height: 16 * s)
            .padding(.top, (p.insideSentence == nil ? 26 : 18) * s)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(p.issues) { issue in
                    IssueLine(
                        scale: s, path: issue.path, message: issue.message,
                        buttonTitle: issue.revealPath == nil ? nil : "Show in Finder",
                        action: { if let path = issue.revealPath { env.reveal(path) } }
                    )
                }
                if let log = p.log {
                    IssueLine(scale: s, label: "Log", path: log.path, message: nil, buttonTitle: "Show", action: { env.reveal(log.revealPath) })
                }
                ForEach(p.warnings, id: \.self) { warning in
                    Note(text: warning, symbol: "exclamationmark.triangle.fill", color: Theme.review, scale: s)
                }
                ForEach(p.notes, id: \.self) { note in
                    Note(text: note, symbol: nil, color: Theme.ink2, scale: s)
                }
            }
            .frame(width: 640 * s, alignment: .leading)
            .padding(.top, 8 * s)

            HStack(spacing: 20 * s) {
                Button("Done") { Task { await model.scan() } }
                    .buttonStyle(PillStyle(look: .solid, height: 44 * s, horizontal: 26 * s, fontSize: 15 * s))
                    .accessibilityHint("Closes this summary and scans again for what is left")
                Button("Rescan") { Task { await model.scan() } }
                    .buttonStyle(LinkStyle(height: 44 * s))
                    .accessibilityHint("Scans again for what is left")
            }
            .padding(.top, 22 * s)
        }
    }
}

/// `7 deleted`, with its mark.
struct Counter: View {
    let symbol: String
    let text: String
    let color: Tone

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(text)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// A line under the counters: a path and what happened to it, or the log, with a small button on the right.
struct IssueLine: View {
    let scale: Double
    var label: String?
    let path: String
    let message: String?
    var buttonTitle: String?
    var action: @MainActor () -> Void = {}

    var body: some View {
        HStack(spacing: 9) {
            if let label {
                Text(label).font(Typeface.ui(13 * scale)).foregroundStyle(Theme.ink2)
            }
            Text(path)
                .font(Typeface.mono(12 * scale))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let message {
                Text(message)
                    .font(Typeface.ui(13 * scale))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .buttonStyle(PillStyle(look: .soft(text: Theme.ink), height: 24, horizontal: 10, fontSize: 11.5, shadowed: false))
            }
        }
        .frame(minHeight: 26 * scale)
        .accessibilityElement(children: .contain)
    }
}

/// A sentence about the run, with an optional mark.
struct Note: View {
    let text: String
    let symbol: String?
    let color: Tone
    let scale: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11 * scale)) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.ui(12.5 * scale))
        .foregroundStyle(color)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: nothing to clean

/// Nothing to clean. With the pane open (the History, over the screen: `PaneOverlay`) the headline moves left and the band
/// stops before the pane, as the board `C-History` draws it; with it closed, Rescan and Show details are at the top right, as
/// on the rest screen.
struct EmptyScreen: View {
    let model: AppModel
    let window: WindowState
    @Environment(\.cmm) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let plan = model.plan {
            GeometryReader { geometry in
                let open = window.detailsOpen
                let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
                let layout = HeroLayout(screen: .empty, detailsOpen: open, width: geometry.size.width, height: geometry.size.height)
                let s = layout.scale
                let p = EmptyPresentation(plan: plan, volumeName: env.volumeName(plan), now: env.now(), calendar: env.calendar)

                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        HeroHeader(layout: layout, eyebrow: p.label, number: p.number, phrase: p.sentence)
                        if let held = p.heldSentence {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "hand.raised.fill").font(.system(size: 14 * s))
                                Paragraph(text: held, size: 15 * s, lineHeight: 22 * s)
                            }
                            .foregroundStyle(Theme.ink2)
                            // in the text column, which ends before the pane when it is open
                            .frame(maxWidth: open ? layout.bandWidth : 520 * s, alignment: .leading)
                            .padding(.top, 14 * s)
                            .accessibilityElement(children: .combine)
                        }
                        Button { Task { await model.scan() } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise").font(.system(size: layout.pillFontSize - s, weight: .medium))
                                Text("Rescan")
                            }
                        }
                        .buttonStyle(PillStyle(
                            look: .soft(text: Theme.ink), height: layout.pillHeight, horizontal: (open ? 20 : 22) * s,
                            fontSize: layout.pillFontSize, shadowed: false
                        ))
                        .accessibilityHint("Scans again")
                        .padding(.top, layout.actionsTopGap)
                    }
                    .padding(.leading, layout.leading)
                    .padding(.top, layout.top)

                    BandBlock(band: p.band, caption: p.caption, sentence: p.bandSentence, layout: layout)
                        .offset(x: layout.bandLeading, y: layout.bandTop)

                    if !open {
                        HeaderButtons(model: model, window: window, detailsOpen: false)
                            .padding(.top, 14)
                            .padding(.trailing, 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .animation(motion.animation, value: open)
            }
        }
    }
}

// MARK: scanning and errors (the boards do not draw these; they use the same language)

struct ScanningScreen: View {
    var body: some View {
        GeometryReader { geometry in
            let layout = HeroLayout(screen: .message, width: geometry.size.width, height: geometry.size.height)
            let s = layout.scale
            VStack(alignment: .leading, spacing: 0) {
                Text("Scanning · this can take a minute")
                    .font(Typeface.ui(layout.eyebrowSize, .medium))
                    .tracking(layout.eyebrowSize * 0.01)
                    .foregroundStyle(Theme.ink2)
                Phrase(text: "Checking what can safely go.", size: 52 * s, maxWidth: 680 * s)
                    .padding(.top, 14 * s)
                IndeterminateLine(width: 488 * s)
                    .padding(.top, 26 * s)
                Paragraph(text: "This only looks. Nothing is removed until you choose items and confirm.", size: 15 * s, lineHeight: 22 * s)
                    .frame(maxWidth: 470 * s, alignment: .leading)
                    .padding(.top, 20 * s)
            }
            .padding(.leading, layout.leading)
            .padding(.top, layout.top)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A 2 pt line with a green stretch that travels along it; it holds still, filled a little, with Reduce Motion.
struct IndeterminateLine: View {
    let width: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0.35 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let stretch = width * 0.28
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.progressTrack)
                Capsule().fill(Theme.accent).frame(width: stretch).offset(x: (width + stretch) * t - stretch)
            }
            .clipShape(Capsule())
        }
        .frame(width: width, height: 2)
        .accessibilityHidden(true)
    }
}

struct ErrorScreen: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let layout = HeroLayout(screen: .message, width: geometry.size.width, height: geometry.size.height)
            let s = layout.scale
            let failure = model.failure
            VStack(alignment: .leading, spacing: 0) {
                Text(failure?.stage == .clean ? "Cleaning stopped" : "Scan stopped")
                    .font(Typeface.ui(layout.eyebrowSize, .medium))
                    .tracking(layout.eyebrowSize * 0.01)
                    .foregroundStyle(Theme.ink2)
                Phrase(text: Self.sentence(failure?.title ?? "Something went wrong"), size: 52 * s, maxWidth: 680 * s)
                    .padding(.top, 14 * s)
                    .accessibilityAddTraits(.isHeader)
                detail(failure?.detail ?? "", scale: s)
                    .padding(.top, 16 * s)
                Button { Task { await model.scan() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14 * s, weight: .medium))
                        Text("Try again")
                    }
                }
                .buttonStyle(PillStyle(look: .solid, height: 44 * s, horizontal: 24 * s, fontSize: 15 * s))
                .accessibilityHint("Scans again")
                .padding(.top, 28 * s)
            }
            .padding(.leading, layout.leading)
            .padding(.top, layout.top)
        }
    }

    /// The headline as a sentence: the title with a full stop.
    static func sentence(_ title: String) -> String {
        title.hasSuffix(".") ? title : title + "."
    }

    @ViewBuilder
    private func detail(_ text: String, scale s: Double) -> some View {
        let long = text.count > 500 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
        let body = Paragraph(text: text, size: 15 * s, lineHeight: 22 * s)
            .textSelection(.enabled)
            .frame(maxWidth: 600 * s, alignment: .leading)
        if long {
            ScrollView { body }.frame(maxWidth: 600 * s, maxHeight: 190 * s)
        } else {
            body
        }
    }
}
