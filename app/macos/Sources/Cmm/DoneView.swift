import CmmKit
import SwiftUI

/// After the cleanup: what was really freed (cmm's own numbers), what was skipped or failed and why, the free
/// space before and after, and where the record is.
struct DoneView: View {
    let model: AppModel
    let home: String

    var body: some View {
        if let summary = model.summary {
            let done = summary.done
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Image(systemName: done.stopped ? "stop.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(done.stopped ? Color.orange : Color.green)
                        .accessibilityHidden(true)
                    Text("Freed \(ByteFormat.string(done.freedBytes))")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    if done.stopped {
                        Text("Stopped early. Items after the one in progress were not touched.")
                            .foregroundStyle(.secondary)
                    }
                    TallyLabels(deleted: done.deleted, skipped: done.skipped, failed: done.failed)
                        .font(.body)
                    Text("Free space: \(ByteFormat.string(done.freeBefore)) before, \(ByteFormat.string(done.freeAfter)) after")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let log = done.log {
                        Text("Record of this cleanup: \(log)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(Array(done.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                    if summary.unreadableLines > 0 {
                        Label(
                            "\(summary.unreadableLines) line(s) of cmm's output could not be read; the totals above are cmm's own.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)

                Divider()
                ResultsList(items: summary.items, plan: model.plan, home: home)
                Divider()

                HStack {
                    Spacer()
                    RescanButton(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }
}
