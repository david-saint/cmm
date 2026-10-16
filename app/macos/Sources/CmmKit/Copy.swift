import Foundation

// The words of the window. Everything here is built from the plan: a rule's id, the label of its group, the notes
// of its items, the reasons of its skips. A small catalog of cmm's own rules supplies the short titles the design
// uses ("Homebrew old versions"); a rule the catalog does not know falls back to the plan's own wording, so nothing
// is ever invented and a new rule needs no change here to appear.

/// A group label such as `Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)`, taken
/// apart: the title, and the clauses of its trailing parenthetical.
struct LabelParts: Equatable {
    let title: String
    let clauses: [String]

    init(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            title = trimmed
            clauses = []
            return
        }
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        title = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        clauses = inside.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The second clause as a sentence ("Rebuild with npm ci or pod install."), shown under a group's items.
    var footnote: String? {
        guard clauses.count >= 2 else { return nil }
        var text = clauses[1].replacingOccurrences(of: " / ", with: " or ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }
}

/// What cmm's built-in rules are called in the window, and how the sentence under the headline names them.
public enum RuleCatalog {
    enum Phrase {
        case caches
        case laneDependencies
        case laneOutput
        case text(String)
    }

    struct Entry {
        let title: String
        /// The group label cmm gives the rule, so a skip reason that starts with it can be shortened.
        let label: String
        let phrase: Phrase
        /// What a single command item runs, shown instead of its pseudo-path ("brew cleanup").
        var command: String?
        /// A fixed second line for a group (Docker's).
        var blurb: String?
        /// A shorter name for a tile of the map, where the tile is small ("Homebrew").
        var mapTitle: String?
        /// A clause the map's caption adds for a group of commands ("volumes are never offered").
        var mapClause: String?
    }

    static let entries: [String: Entry] = [
        "go-build": Entry(title: "Go build cache", label: "Go build cache", phrase: .caches),
        "npm-cache": Entry(title: "npm cache", label: "npm download cache", phrase: .caches),
        "cocoapods": Entry(title: "CocoaPods cache", label: "CocoaPods cache", phrase: .caches),
        "bun-cache": Entry(title: "bun cache", label: "bun cache", phrase: .caches),
        "uv-cache": Entry(title: "uv cache", label: "uv cache (Python packages; downloads again on demand)", phrase: .caches),
        "xcode-module-cache": Entry(
            title: "Xcode module cache", label: "Xcode module/compilation cache (rebuilds on the next build)", phrase: .caches),
        "jest-temp": Entry(title: "Jest temp cache", label: "Jest temp cache", phrase: .caches),
        "deriveddata-stale": Entry(
            title: "Stale Xcode build output", label: "Stale Xcode build output (DerivedData)", phrase: .text("stale Xcode build output")),
        "lane-local-build": Entry(
            title: "Stale lane build folders", label: "Stale lane-local Xcode build folders", phrase: .text("stale lane build folders")),
        "lane-deps": Entry(
            title: "Idle lane dependencies",
            label: "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)", phrase: .laneDependencies),
        "lane-build-output": Entry(
            title: "Idle lane build output",
            label: "Idle lane build output (untouched 5+ days; rebuilds on the next build)", phrase: .laneOutput),
        "maestro-temp": Entry(
            title: "Maestro test output", label: "Maestro test output (older than 1 hour)", phrase: .text("Maestro test output")),
        "cursor-update": Entry(
            title: "Cursor's failed update", label: "Cursor's failed update (staged copy)", phrase: .text("a failed Cursor update")),
        "claude-versions": Entry(title: "Old Claude CLI versions", label: "Old claude CLI versions", phrase: .text("old CLI versions")),
        "cursor-agent-versions": Entry(
            title: "Old Cursor agent versions", label: "Old cursor-agent versions", phrase: .text("old CLI versions")),
        "simulators": Entry(
            title: "Unavailable simulators", label: "Simulators whose runtime was removed", phrase: .text("unavailable simulators")),
        "homebrew": Entry(
            title: "Homebrew old versions", label: "Homebrew: old versions of installed formulae (brew cleanup)",
            phrase: .text("old Homebrew versions"), command: "brew cleanup", mapTitle: "Homebrew"),
        "docker": Entry(
            title: "Docker", label: "Docker: unused images, stopped containers and build cache (review first)",
            phrase: .text("Docker's unused data"), blurb: "Unused images, stopped containers, build cache. Volumes are never offered.",
            mapClause: "volumes are never offered"),
    ]

    /// The catalog's title for a rule, or nil when the rule is not one of cmm's built-ins.
    static func knownTitle(rule: String) -> String? {
        entries[rule]?.title
    }

    /// The title for a group: the catalog's, else the plan's own label without its parenthetical, else the rule id
    /// made readable.
    public static func title(rule: String, label: String) -> String {
        if let known = entries[rule]?.title { return known }
        let fromLabel = LabelParts(label).title
        return fromLabel.isEmpty ? humanized(rule: rule) : fromLabel
    }

    /// The name of a tile of the map: the catalog's short one where it has one, else the group's title.
    public static func mapTitle(rule: String, label: String) -> String {
        entries[rule]?.mapTitle ?? title(rule: rule, label: label)
    }

    /// `some-new-rule` -> `Some new rule`.
    public static func humanized(rule: String) -> String {
        let words = rule.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A title as it reads in the middle of a sentence: plain first words lose their capital ("unavailable
    /// simulators"), names keep it ("Go build cache").
    static func midSentence(_ title: String) -> String {
        let plain: Set<String> = ["Unavailable", "Idle", "Stale", "Old"]
        let first = title.prefix { $0 != " " }
        guard plain.contains(String(first)) else { return title }
        return title.prefix(1).lowercased() + title.dropFirst()
    }

    /// A plural title takes "were", a singular one "was".
    static func isPlural(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasSuffix("s") && !lower.hasSuffix("ss")
    }
}

/// A rule that was held back by a guard, as a row of the Details pane.
public struct HeldRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The reason as cmm gave it, without the rule's label in front.
    public let reason: String
    /// The line under the title: the reason with a capital, and when the rule comes back.
    public let detail: String
    /// Set for rows that stand for items the app cannot offer (not for guard skips).
    public let sizeText: String?

    var midTitle: String { RuleCatalog.midSentence(title) }

    /// - Parameter labelsInPlan: the group labels the plan itself uses for this rule, so a reason that starts with
    ///   a label the catalog does not know can still be shortened.
    static func make(skip: Skip, index: Int, labelsInPlan: [String]) -> HeldRow {
        let reason = strip(skip.reason, rule: skip.rule, labelsInPlan: labelsInPlan)
        let sentence = reason.prefix(1).uppercased() + reason.dropFirst()
        return HeldRow(
            id: "held:\(index)", title: RuleCatalog.entries[skip.rule]?.title ?? RuleCatalog.humanized(rule: skip.rule),
            reason: reason, detail: "\(sentence) · offered again next scan", sizeText: nil
        )
    }

    /// A group of items that cannot be ticked (manual or unknown tier), listed so nothing is hidden.
    static func make(unofferable group: PlanGroup, index: Int) -> HeldRow {
        let manual = group.items.contains { $0.tier == .manual }
        let reason = manual ? "it needs a manual step" : "this version of the app does not offer it"
        return HeldRow(
            id: "held:\(index)", title: RuleCatalog.title(rule: group.rule, label: group.name),
            reason: reason, detail: "Not offered here: \(reason)", sizeText: SizeText.string(group.bytes)
        )
    }

    private static func strip(_ reason: String, rule: String, labelsInPlan: [String]) -> String {
        var prefixes = labelsInPlan
        if let entry = RuleCatalog.entries[rule] { prefixes += [entry.label, entry.title] }
        prefixes.append(rule)
        for prefix in prefixes where !prefix.isEmpty {
            let lead = prefix + ": "
            if reason.range(of: lead, options: [.anchored, .caseInsensitive]) != nil {
                return String(reason.dropFirst(lead.count))
            }
        }
        return reason
    }
}

/// The line under the disk band, and the sentence of the "nothing to clean" screen, about what was held back.
public enum HeldBack {
    /// `1 held back: unavailable simulators, because Simulator is running`
    public static func line(for rows: [HeldRow]) -> String? {
        switch rows.count {
        case 0: return nil
        case 1: return "1 held back: \(rows[0].midTitle), because \(rows[0].reason)"
        default: return "\(rows.count) held back: \(list(rows))"
        }
    }

    /// `The uv cache was held back because uv is running. cmm looks again on the next scan.`
    public static func sentence(for rows: [HeldRow]) -> String? {
        switch rows.count {
        case 0:
            return nil
        case 1:
            let title = rows[0].midTitle
            let verb = RuleCatalog.isPlural(title) ? "were" : "was"
            return "The \(title) \(verb) held back because \(rows[0].reason). cmm looks again on the next scan."
        default:
            return "\(rows.count) things were held back: \(list(rows)). cmm looks again on the next scan."
        }
    }

    private static func list(_ rows: [HeldRow]) -> String {
        let titles = rows.map(\.midTitle)
        if titles.count <= 3 { return join(titles) }
        return titles.prefix(3).joined(separator: ", ") + " and \(titles.count - 3) more"
    }

    static func join(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// The sentence under the headline: what the safe items are, in words, and that all of it can be regenerated.
///
/// "Caches, the dependencies of three idle lanes and old Homebrew versions. All of it can be regenerated."
public enum HeroBody {
    public static func text(for selection: SelectionModel) -> String? {
        let safeGroups = selection.groups(in: .safe)
        guard !safeGroups.isEmpty else { return nil }

        // One phrase per kind of thing, with the bytes behind it, so the biggest comes first.
        var phrases: [String: (text: String, bytes: Int64)] = [:]
        var order: [String] = []
        func add(_ text: String, _ bytes: Int64) {
            if phrases[text] == nil { order.append(text) }
            phrases[text, default: (text, 0)].bytes += bytes
        }

        for group in safeGroups {
            switch RuleCatalog.entries[group.rule]?.phrase {
            case .caches?:
                add("Caches", group.bytes)
            case .laneDependencies?:
                add("the dependencies of \(idleLanes(in: group))", group.bytes)
            case .laneOutput?:
                add("the build output of \(idleLanes(in: group))", group.bytes)
            case .text(let phrase)?:
                add(phrase, group.bytes)
            case nil:
                add(RuleCatalog.midSentence(RuleCatalog.title(rule: group.rule, label: group.name)), group.bytes)
            }
        }

        let ranked = order.enumerated()
            .sorted { (phrases[$0.element]!.bytes, $1.offset) > (phrases[$1.element]!.bytes, $0.offset) }
            .map(\.element)
        let named = ranked.count > 3 ? ranked.prefix(3).joined(separator: ", ") + " and more" : HeldBack.join(ranked)
        let sentence = named.prefix(1).uppercased() + named.dropFirst()
        return "\(sentence). All of it can be regenerated."
    }

    /// "three idle lanes", "one idle lane", or "idle lanes" when the notes do not say how many: the distinct lanes are
    /// read from the items' notes ("lane lane-a: untouched for 12 days"), and no number is claimed without them.
    private static func idleLanes(in group: PlanGroup) -> String {
        var names = Set<String>()
        for item in group.items {
            guard let note = item.note, note.hasPrefix("lane "),
                  let colon = note.firstIndex(of: ":") else { continue }
            let name = note[note.index(note.startIndex, offsetBy: 5)..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }
        switch names.count {
        case 0: return "idle lanes"
        case 1: return "one idle lane"
        default: return "\(number(names.count)) idle lanes"
        }
    }

    /// One to ten as words, then digits.
    static func number(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }
}
