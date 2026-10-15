import Foundation

/// The contents of the Details pane as plain values: three sections (Safe to remove, Review first, Held back), the
/// rows in each, and the words on every row, so the order, the copy and the VoiceOver strings can be tested without a
/// window. The view only draws what this says.
public struct DetailsModel: Equatable, Sendable {
    public enum SectionKind: String, Hashable, Sendable {
        case safe
        case review
        case held
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let kind: SectionKind
        public let title: String
        /// The section's size ("8.4 GB"); nil for "Held back".
        public let total: String?
        public let rows: [Row]

        public var id: String { kind.rawValue }
    }

    public enum Row: Identifiable, Equatable, Sendable {
        case group(GroupRow)
        case item(ItemRow)
        case footnote(FootnoteRow)
        case held(HeldRow)

        public var id: String {
            switch self {
            case .group(let row): row.id
            case .item(let row): row.id
            case .footnote(let row): row.id
            case .held(let row): row.id
            }
        }
    }

    public struct GroupRow: Identifiable, Equatable, Sendable {
        public let group: PlanGroup
        public let title: String
        public let subtitle: String
        /// A path or a command is set in the monospaced face, a sentence is not.
        public let subtitleIsMonospaced: Bool
        public let sizeText: String
        public let state: TriState
        public let isExpanded: Bool

        public var id: String { "group:\(group.id)" }

        public var accessibilityLabel: String {
            var label = "\(title), \(Plural.items(group.count)), \(sizeText)"
            if group.section == .review { label += ", needs your review" }
            return label
        }

        public var accessibilityValue: String {
            "\(DetailsModel.words(for: state)), \(isExpanded ? "expanded" : "collapsed")"
        }
    }

    public struct ItemRow: Identifiable, Equatable, Sendable {
        public let item: PlanItem
        public let groupID: String
        public let title: String
        /// The engine's note for the item ("lane lane-a: untouched for 12 days"), when it has one.
        public let detail: String?
        public let sizeText: String
        public let isTicked: Bool

        public var id: String { "item:\(item.path)" }
        public var accessibilityLabel: String { title }
        public var accessibilityValue: String {
            var parts = [isTicked ? "selected" : "not selected", sizeText]
            if let detail { parts.append(detail) }
            return parts.joined(separator: ", ")
        }
    }

    public struct FootnoteRow: Identifiable, Equatable, Sendable {
        public let groupID: String
        public let text: String

        public var id: String { "footnote:\(groupID)" }
    }

    public let sections: [Section]

    /// The rows a keyboard can stop on, top to bottom: every group, and the items of the groups that are open.
    public var focusableIDs: [String] {
        sections.flatMap(\.rows).compactMap {
            switch $0 {
            case .group(let row): row.id
            case .item(let row): row.id
            case .footnote, .held: nil
            }
        }
    }

    /// - Parameter expanded: the ids (`PlanGroup.id`) of the groups that are open.
    public init(selection: SelectionModel, expanded: Set<String>, home: String) {
        var sections: [Section] = []

        for (kind, section, title, total) in [
            (SectionKind.safe, PlanSection.safe, "Safe to remove", selection.plannedBytes),
            (SectionKind.review, PlanSection.review, "Review first", selection.reviewBytes),
        ] {
            let groups = selection.groups(in: section)
            guard !groups.isEmpty else { continue }
            var rows: [Row] = []
            for group in groups {
                let isOpen = expanded.contains(group.id)
                rows.append(.group(Self.groupRow(group, selection: selection, isExpanded: isOpen, home: home)))
                guard isOpen else { continue }
                for item in group.items {
                    rows.append(.item(ItemRow(
                        item: item,
                        groupID: group.id,
                        title: item.action == .command ? item.path : PathFormat.shorten(item.path, home: home),
                        detail: (item.note?.isEmpty ?? true) ? nil : item.note,
                        sizeText: SizeText.string(item.bytes),
                        isTicked: selection.isTicked(item)
                    )))
                }
                if let footnote = LabelParts(group.name).footnote {
                    rows.append(.footnote(FootnoteRow(groupID: group.id, text: footnote)))
                }
            }
            sections.append(Section(kind: kind, title: title, total: SizeText.string(total), rows: rows))
        }

        let held = Self.heldRows(selection: selection)
        if !held.isEmpty {
            sections.append(Section(kind: .held, title: "Held back", total: nil, rows: held.map { .held($0) }))
        }
        self.sections = sections
    }

    /// Guard skips first, then groups the app cannot offer; the same rows feed the line under the band.
    static func heldRows(selection: SelectionModel) -> [HeldRow] {
        let labelsByRule = Dictionary(grouping: selection.plan.items, by: \.rule).mapValues { Array(Set($0.map(\.group))) }
        var rows = selection.plan.skipped.enumerated().map { index, skip in
            HeldRow.make(skip: skip, index: index, labelsInPlan: labelsByRule[skip.rule] ?? [])
        }
        for group in selection.groups(in: .other) {
            rows.append(HeldRow.make(unofferable: group, index: rows.count))
        }
        return rows
    }

    private static func groupRow(_ group: PlanGroup, selection: SelectionModel, isExpanded: Bool, home: String) -> GroupRow {
        let entry = RuleCatalog.entries[group.rule]
        let parts = LabelParts(group.name)

        let subtitle: String
        let isMono: Bool
        if let blurb = entry?.blurb {
            (subtitle, isMono) = (blurb, false)
        } else if group.items.count > 1 {
            let detail = parts.clauses.first.map { " · \($0)" } ?? ""
            (subtitle, isMono) = ("\(Plural.items(group.count))\(detail)", false)
        } else if let item = group.items.first {
            let text = item.action == .command ? (entry?.command ?? item.path) : PathFormat.shorten(item.path, home: home)
            (subtitle, isMono) = (text, true)
        } else {
            (subtitle, isMono) = ("", false)
        }

        return GroupRow(
            group: group,
            title: RuleCatalog.title(rule: group.rule, label: group.name),
            subtitle: subtitle,
            subtitleIsMonospaced: isMono,
            sizeText: SizeText.string(group.bytes),
            state: selection.state(of: group),
            isExpanded: isExpanded
        )
    }

    static func words(for state: TriState) -> String {
        switch state {
        case .off: "not selected"
        case .on: "selected"
        case .mixed: "partly selected"
        }
    }
}
