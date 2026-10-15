import AppKit
import CmmKit
import SwiftUI

/// Three cards: how much room there is, how much cmm calls safe to remove, and what its guards held back.
struct HeaderView: View {
    let plan: Plan
    let selection: SelectionModel

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Free space now",
                systemImage: "internaldrive",
                value: ByteFormat.string(plan.host.freeBytes),
                caption: plan.host.volume
            )
            StatCard(
                title: "Safe to remove",
                systemImage: "sparkles",
                value: ByteFormat.string(selection.plannedBytes),
                caption: safeCaption,
                captionEmphasized: selection.selectedBytes != selection.plannedBytes
            )
            SkippedCard(skipped: plan.skipped)
        }
        .padding(16)
    }

    /// The planned total, and what is ticked when that is something else.
    private var safeCaption: String {
        if selection.selectedBytes == selection.plannedBytes {
            return Plural.items(selection.safeCount)
        }
        return "\(ByteFormat.string(selection.selectedBytes)) selected"
    }
}

struct StatCard: View {
    let title: String
    let systemImage: String
    let value: String
    let caption: String
    var captionEmphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(captionEmphasized ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

/// "Skipped by guards": the count, and the reasons on click (a popover) or hover (a tooltip).
struct SkippedCard: View {
    let skipped: [Skip]
    @State private var showReasons = false

    var body: some View {
        Button {
            if !skipped.isEmpty { showReasons.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Skipped by guards", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(skipped.count)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(skipped.isEmpty ? "Nothing was held back" : "Click to see why")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(skipped.isEmpty ? "No rule was held back" : skipped.map(\.summary).joined(separator: "\n"))
        .popover(isPresented: $showReasons, arrowEdge: .bottom) {
            SkipReasonsList(skipped: skipped)
                .padding(14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skipped by guards: \(skipped.count)")
        .accessibilityValue(skipped.map(\.summary).joined(separator: ". "))
        .accessibilityHint(skipped.isEmpty ? "" : "Shows why each rule was held back")
    }
}

/// `rule: reason`, one per line. Used by the popover and by the "nothing to clean" screen.
struct SkipReasonsList: View {
    let skipped: [Skip]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Held back by guards")
                .font(.headline)
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, skip in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(skip.rule)
                        .font(.system(.callout, design: .monospaced))
                    Text(skip.reason)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

extension View {
    /// The look of a card: a rounded panel with a hairline border, in the system's own colors so it follows the
    /// light and dark appearance.
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}
