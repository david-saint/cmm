import CmmKit
import SwiftUI

/// What the screens need from the world, passed down as one value so a test can hand them fixed ones: the home folder
/// (paths are shown as `~/...`), the name of the volume, the clock, and what "Show in Finder" does.
struct ViewEnvironment: Sendable {
    var home: String = NSHomeDirectory()
    var volumeName: @Sendable (Plan) -> String = { VolumeName.display(forVolume: $0.host.volume) }
    var now: @Sendable () -> Date = { Date() }
    var calendar: Calendar = .current
    var locale: Locale = .current
    var reveal: @MainActor @Sendable (String) -> Void = { FinderReveal.show($0) }
    /// +1 in the app. The offscreen snapshots (`NSView.cacheDisplay`) draw a layer's shadow offset upside down, so the
    /// snapshot renderer sets -1 and the PNGs show the shadow where the window does: below.
    var shadowDirection: CGFloat = 1
}

private struct ViewEnvironmentKey: EnvironmentKey {
    static let defaultValue = ViewEnvironment()
}

extension EnvironmentValues {
    var cmm: ViewEnvironment {
        get { self[ViewEnvironmentKey.self] }
        set { self[ViewEnvironmentKey.self] = newValue }
    }
}

private struct IncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True to draw with the Increase Contrast colours whatever the system says. The app never sets it (SwiftUI's own
    /// `colorSchemeContrast` carries the system's switch); the snapshot tests do, because a window's appearance cannot
    /// turn the switch on.
    var cmmIncreasedContrast: Bool {
        get { self[IncreasedContrastKey.self] }
        set { self[IncreasedContrastKey.self] = newValue }
    }
}
