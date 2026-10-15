import AppKit
import Foundation

/// "Show in Finder": asks Finder to select a file or folder that cmm itself reported (a failed item, the cleanup log).
/// It changes nothing and starts nothing of ours; it is the only place the app talks to the workspace, and it is given
/// only paths that came out of cmm's events.
@MainActor
enum FinderReveal {
    static func show(_ path: String) {
        guard path.hasPrefix("/") else { return }  // a command item's label is not a place
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
