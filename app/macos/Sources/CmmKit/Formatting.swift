import Foundation

// Text the window shows, as plain functions so it can be tested without a window. (No UI code lives in CmmKit.)

/// Byte sizes in decimal units, the way the Finder and cmm write them: `927.1 MB`, `27.6 GB`.
///
/// This is deliberately not `ByteCountFormatter`: its output depends on the locale, and the app's tests and its
/// confirmation sheet should say the same thing everywhere.
public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func string(_ bytes: Int64) -> String {
        let bytes = max(bytes, 0)
        if bytes < 1000 { return "\(bytes) B" }

        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        // Rounding to one decimal can reach 1000 (999.96 KB); that is 1.0 MB, not "1000.0 KB".
        if (value * 10).rounded() / 10 >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return "\(String(format: "%.1f", value)) \(units[unit])"
    }
}

public enum Plural {
    /// `1 item`, `2 items`, `0 items`.
    public static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

public enum PathFormat {
    /// Writes the home folder as `~`, only at a path component boundary: with the home folder `/Users/test`,
    /// `/Users/test2/x` stays as it is. A path that is not under the home folder (and a label such as
    /// `homebrew: cleanup`) is returned unchanged.
    public static func shorten(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard home.count > 1 else { return path }  // "" or "/" would turn every path into "~/..."
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension PlanItem {
    /// What to show as the item's name: the shortened path, or for a command item (whose "path" is only a label)
    /// its note.
    public func displayTitle(home: String) -> String {
        if action == .command, let note, !note.isEmpty { return note }
        return PathFormat.shorten(path, home: home)
    }

    /// The secondary line: the note, unless the note is already the title.
    public var displayDetail: String? {
        guard action != .command, let note, !note.isEmpty else { return nil }
        return note
    }
}

extension Skip {
    /// `uv-cache: uv is running`
    public var summary: String { "\(rule): \(reason)" }
}

extension SelectionModel {
    /// The footer: `Selected: 4 items, 3.1 GB`.
    public var summaryText: String {
        "Selected: \(Plural.items(selectedCount)), \(ByteFormat.string(selectedBytes))"
    }

    /// The label of the button that opens the confirmation: `Clean 4 items…`.
    public var cleanButtonTitle: String {
        "Clean \(Plural.items(selectedCount))…"
    }
}
