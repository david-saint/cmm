import AppKit
import CmmKit
import SwiftUI

/// The body of the window: groups largest first. A group row has a disclosure arrow, a tri-state checkbox, the
/// name, the item count and the size; opened, it lists its items with a checkbox, the path (or the note of a
/// command item), the size and the note beneath.
struct PlanListView: View {
    let model: AppModel
    let selection: SelectionModel
    let home: String

    @State private var expanded: Set<String>

    /// `expanded` is the set of group names that start open; people open them by clicking.
    init(model: AppModel, selection: SelectionModel, home: String, expanded: Set<String> = []) {
        self.model = model
        self.selection = selection
        self.home = home
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(selection.groups) { group in
                    GroupRow(
                        group: group,
                        state: selection.state(of: group),
                        isExpanded: expanded.contains(group.id),
                        toggleExpanded: { toggleExpanded(group) },
                        toggleTicks: { model.toggle(group) }
                    )
                    if expanded.contains(group.id) {
                        ForEach(group.items) { item in
                            ItemRow(
                                item: item,
                                isTicked: selection.isTicked(item),
                                home: home,
                                toggle: { model.toggle(item) }
                            )
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func toggleExpanded(_ group: PlanGroup) {
        if expanded.contains(group.id) {
            expanded.remove(group.id)
        } else {
            expanded.insert(group.id)
        }
    }
}

struct GroupRow: View {
    let group: PlanGroup
    let state: TriState
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let toggleTicks: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // The arrow is a convenience for the mouse; the label button below is the accessible disclosure control.
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            TriStateCheckbox(state: state, label: "Select \(group.name)", action: toggleTicks)

            Button(action: toggleExpanded) {
                HStack(spacing: 10) {
                    Text(group.name)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 12)
                    Text(Plural.items(group.count))
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(group.bytes))
                        .monospacedDigit()
                        .frame(minWidth: 84, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(Plural.items(group.count)), \(ByteFormat.string(group.bytes))")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows or hides the items of this group")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

struct ItemRow: View {
    let item: PlanItem
    let isTicked: Bool
    let home: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                CheckGlyph(state: isTicked ? .on : .off)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayTitle(home: home))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.tier != .safe {
                            TierBadge(tier: item.tier)
                        }
                    }
                    if let detail = item.displayDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Text(ByteFormat.string(item.bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)
            }
            .padding(.leading, 58)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.action == .command ? (item.note ?? item.path) : item.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayTitle(home: home))
        .accessibilityValue(valueDescription)
        .accessibilityHint("Includes or excludes this item from the cleanup")
        .accessibilityAddTraits(.isToggle)
    }

    private var valueDescription: String {
        var parts = [isTicked ? "selected" : "not selected", ByteFormat.string(item.bytes)]
        if item.tier != .safe { parts.append("tier \(item.tier.rawValue)") }
        if let detail = item.displayDetail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

/// A tier other than `safe`: says so in words and with an icon, not only with a color.
struct TierBadge: View {
    let tier: Tier

    var body: some View {
        Label(tier.rawValue.capitalized, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(Color.orange)
    }
}
