import CmmKit
import SwiftUI

/// While cmm works: each item as it finishes, with a mark and a word for deleted, skipped or failed, and a Stop
/// button that asks cmm to finish the item it is on and end.
struct CleaningView: View {
    let model: AppModel
    let home: String

    var body: some View {
        let progress = model.progress
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(progress.stopRequested ? "Stopping after the current item…" : "Cleaning…")
                    .font(.title3.weight(.semibold))
                ProgressView(value: progress.fraction)
                    .accessibilityLabel("Cleaning progress")
                    .accessibilityValue("\(progress.items.count) of \(progress.total) items")
                Text("\(progress.items.count) of \(progress.total) items · \(ByteFormat.string(progress.freedBytes)) freed so far")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            ResultsList(items: progress.items, plan: model.plan, home: home, followLatest: true)
            Divider()

            HStack(spacing: 14) {
                TallyLabels(deleted: progress.deleted, skipped: progress.skipped, failed: progress.failed)
                Spacer()
                Button("Stop") { model.stop() }
                    .disabled(progress.stopRequested)
                    .accessibilityLabel("Stop cleaning")
                    .accessibilityHint("Finishes the item in progress, then stops. Items already removed stay removed.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

/// Deleted / skipped / failed counts, each with an icon and a word.
struct TallyLabels: View {
    let deleted: Int
    let skipped: Int
    let failed: Int

    var body: some View {
        HStack(spacing: 14) {
            Label("\(deleted) deleted", systemImage: ResultStyle.deleted.symbol)
                .foregroundStyle(ResultStyle.deleted.color)
            Label("\(skipped) skipped", systemImage: ResultStyle.skipped.symbol)
                .foregroundStyle(ResultStyle.skipped.color)
            Label("\(failed) failed", systemImage: ResultStyle.failed.symbol)
                .foregroundStyle(ResultStyle.failed.color)
        }
        .font(.callout)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(deleted) deleted, \(skipped) skipped, \(failed) failed")
    }
}

/// How a result looks: an icon, a word and a color. The icon and the word carry the meaning; the color only helps.
struct ResultStyle {
    let symbol: String
    let word: String
    let color: Color

    static let deleted = ResultStyle(symbol: "checkmark.circle.fill", word: "Deleted", color: .green)
    static let skipped = ResultStyle(symbol: "minus.circle.fill", word: "Skipped", color: .orange)
    static let failed = ResultStyle(symbol: "xmark.octagon.fill", word: "Failed", color: .red)

    static func of(_ status: ItemStatus) -> ResultStyle {
        switch status {
        case .deleted: .deleted
        case .skipped: .skipped
        case .failed: .failed
        case .dryRun: ResultStyle(symbol: "eye.circle.fill", word: "Dry run", color: .blue)
        case .other(let name): ResultStyle(symbol: "questionmark.circle.fill", word: name.capitalized, color: .gray)
        }
    }
}

/// The items cmm has reported on, in the order it reported them.
struct ResultsList: View {
    let items: [ItemEvent]
    let plan: Plan?
    let home: String
    var followLatest = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        ResultRow(item: item, title: title(for: item), home: home)
                            .id(item.id)
                        Divider().padding(.leading, 44)
                    }
                    if items.isEmpty {
                        Text("Waiting for cmm to report the first item…")
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
            }
            .onChange(of: items.count) {
                if followLatest, let last = items.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// A command item's path is only a label, so it is shown by its note when the plan has one.
    private func title(for item: ItemEvent) -> String {
        if let planned = plan?.items.first(where: { $0.path == item.path }) {
            return planned.displayTitle(home: home)
        }
        return PathFormat.shorten(item.path, home: home)
    }
}

struct ResultRow: View {
    let item: ItemEvent
    let title: String
    let home: String

    var body: some View {
        let style = ResultStyle.of(item.status)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(style.word)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.color)
                        .frame(width: 58, alignment: .leading)
                    Text(title)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 66)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 12)
            Text(item.status == .deleted ? ByteFormat.string(item.freedBytes) : ByteFormat.string(item.bytes))
                .monospacedDigit()
                .foregroundStyle(item.status == .deleted ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.word): \(title)")
        .accessibilityValue(([ByteFormat.string(item.status == .deleted ? item.freedBytes : item.bytes)]
            + (item.reason.isEmpty ? [] : [item.reason])).joined(separator: ", "))
        .help(item.path)
    }
}
