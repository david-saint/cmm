import CmmKit
import SwiftUI

/// Scanning: cmm is working out what can go. It can take a minute because big folders are sized.
struct ScanningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Checking what can safely go (this can take a minute)")
                .font(.headline)
            Text("This only looks. Nothing is removed until you choose items and confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// Nothing to clean: say so, show how much room there is, and why the guards held rules back.
struct NothingToCleanView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Nothing to clean right now")
                .font(.title2.weight(.semibold))
            if let plan = model.plan {
                Text("Free space: \(ByteFormat.string(plan.host.freeBytes)) on \(plan.host.volume)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if !plan.skipped.isEmpty {
                    SkipReasonsList(skipped: plan.skipped)
                        .padding(14)
                        .cardBackground()
                }
            }
            RescanButton(model: model)
        }
        .padding(24)
    }
}

/// Something went wrong: cmm was not found, the plan failed or could not be read, or a cleanup ended badly.
struct ErrorView: View {
    let model: AppModel
    let home: String

    var body: some View {
        let failure = model.failure
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(failure?.title ?? "Something went wrong")
                .font(.title2.weight(.semibold))
            // Short messages take the room they need; a long one (cmm's stderr) scrolls.
            if isLong(failure?.detail ?? "") {
                ScrollView { detailText(failure?.detail ?? "") }
                    .frame(maxWidth: 560, maxHeight: 150)
            } else {
                detailText(failure?.detail ?? "")
                    .frame(maxWidth: 560)
            }

            if failure?.stage == .clean, !model.progress.items.isEmpty {
                Divider()
                ResultsList(items: model.progress.items, plan: model.plan, home: home)
                    .frame(maxWidth: 640)
            }
            RescanButton(model: model, title: "Retry")
        }
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    private func isLong(_ text: String) -> Bool {
        text.count > 500 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
