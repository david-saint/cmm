import Foundation

/// What the menu bar item's popover can ask for (spec R5, R10 and the boards). **There is no case that cleans**: a cleaning
/// goes through the window's confirmation card and nowhere else, and a source test keeps this list from growing one.
public enum MenuBarAction: String, CaseIterable, Sendable {
    /// The same scan as the window's. It only looks.
    case scan
    /// Raises the window at rest.
    case openWindow
    /// Raises the window on the History face (the "Last cleaned" row).
    case openHistory
    case openSettings
    case quit
}

/// What the menu bar item and its popover say, in one value: the six states of spec R5, and a seventh for the minutes a
/// cleaning takes. The title is the free space, and the state is what the popover is about.
public enum MenuBarState: Equatable, Sendable {
    /// Something can go: the safe items, never a review item and never what is freed inside another program's storage.
    case ready(canGo: Int64, free: Int64)
    case nothingToClean(free: Int64)
    /// Under 10 GB free, whatever else is true.
    case low(free: Int64, canGo: Int64)
    case scanning
    /// The window is cleaning. (The spec's six states have none; calling it "scanning" would say the wrong thing.)
    case cleaning
    /// For an hour after a cleaning that gave the disk something back.
    case justCleaned(freed: Int64, free: Int64)
    case unknown

    /// Free space under this (decimal) is low: an amber dot and the words "Low on space".
    public static let lowBelowBytes: Int64 = 10_000_000_000
    /// How long "just cleaned" lasts.
    public static let justCleanedFor: TimeInterval = 3_600
}
