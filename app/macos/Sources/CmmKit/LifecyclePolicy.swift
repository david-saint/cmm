import Foundation

/// A window of cmm's own. The menu bar item's popover is not one of them: opening it never brings back the Dock icon.
public enum AppWindow: String, CaseIterable, Sendable {
    case main
    case settings
}

/// Whether cmm has a Dock icon and a menu bar of its own (`regular`), or lives in the menu bar item alone (`accessory`).
public enum ActivationPolicy: Equatable, Sendable {
    case regular
    case accessory
}

/// The lifecycle rules (spec R12, and the owner's fifth decision), as pure functions of what is switched on, which of cmm's
/// windows are open and what the window is doing. The app turns the answers into calls on the system; nothing here calls
/// anything.
public enum LifecyclePolicy {
    /// One rule for the Dock: an icon while any cmm window is open, and always when the menu bar item is off (then cmm is an
    /// ordinary app, exactly as before the menu bar item existed).
    public static func activationPolicy(menuBarEnabled: Bool, openWindows: Set<AppWindow>) -> ActivationPolicy {
        !menuBarEnabled || !openWindows.isEmpty ? .regular : .accessory
    }

    /// With the menu bar item off, closing the last window quits, as it always did. With it on, the item stays, and Quit is in
    /// its `...` menu.
    public static func terminatesAfterLastWindowClosed(menuBarEnabled: Bool) -> Bool {
        !menuBarEnabled
    }

    /// A launch that Open at login caused opens no window when the menu bar item is on: only the item appears. Any other
    /// launch opens the window, and so does a login launch without the item (there would be nothing else to see).
    public static func opensWindowAtLaunch(menuBarEnabled: Bool, launchedAtLogin: Bool) -> Bool {
        !(menuBarEnabled && launchedAtLogin)
    }

    /// What closing the main window asks of what is on it.
    public enum ClosingStep: Equatable, Sendable {
        /// A cleaning is asked to stop after the item it is on (the person walked away; doing less than they confirmed is always
        /// safe). It is the Stop button's request: the result screen then says that it was stopped.
        case stopCleaning
        /// The confirmation card is answered with Cancel, which runs nothing: nobody is there to answer it.
        case cancelConfirmation
    }

    /// The steps for closing the main window. A scan is left to finish (it only looks, and the menu bar item shows what it
    /// found); every other screen stays as it is, to be seen when the window opens again.
    public static func stepsWhenMainWindowCloses(phase: AppModel.Phase, confirmationOpen: Bool) -> [ClosingStep] {
        var steps: [ClosingStep] = []
        if phase == .cleaning { steps.append(.stopCleaning) }
        if confirmationOpen { steps.append(.cancelConfirmation) }
        return steps
    }

    /// Whether a screen of the window is in someone's use, so that nothing but the person may take it away: a scan would end
    /// the confirmation card and the done and error screens, and nothing may interrupt a cleaning. The card counts wherever the
    /// window is; the cleaning always; the done and error screens while the window is open (closed, they were left behind, as
    /// closing the window always dismissed them).
    public static func screenInUse(phase: AppModel.Phase, confirmationOpen: Bool, mainWindowOpen: Bool) -> Bool {
        if confirmationOpen || phase == .cleaning { return true }
        return mainWindowOpen && (phase == .done || phase == .failed)
    }
}

/// What the Apple event that launched the app said, as plain numbers. The app reads it from the system when it has finished
/// launching (`LaunchEventSource`); a test writes one by hand.
public struct LaunchEvent: Equatable, Sendable {
    /// `kCoreEventClass`, `kAEOpenApplication`, `keyAEPropData` and `keyAELaunchedAsLogInItem`, spelled as the system spells them
    /// (a test checks them against the SDK's own constants).
    public static let coreEventClass = fourCharacterCode("aevt")
    public static let openApplication = fourCharacterCode("oapp")
    public static let propertyData = fourCharacterCode("prdt")
    public static let launchedAsLogInItem = fourCharacterCode("lgit")

    public let eventClass: UInt32
    public let eventID: UInt32
    /// The event's property data, as an enumerated code, when it carries one.
    public let propertyData: UInt32?

    public init(eventClass: UInt32, eventID: UInt32, propertyData: UInt32?) {
        self.eventClass = eventClass
        self.eventID = eventID
        self.propertyData = propertyData
    }

    /// The system opened the app because the person logged in.
    public var isLoginLaunch: Bool {
        eventClass == Self.coreEventClass && eventID == Self.openApplication && propertyData == Self.launchedAsLogInItem
    }

    /// Four ASCII letters as one number, the way the Apple event constants are made.
    public static func fourCharacterCode(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Where the app finds the launch's Apple event (in the app, the event manager's current event while it finishes launching).
@MainActor
public protocol LaunchEventSource {
    func launchEvent() -> LaunchEvent?
}

/// The lifecycle as it happens: which of cmm's windows are open, what the activation policy should be, and, once, whether the
/// window that opened with the app should stay. It tells the system only when the policy changes (`setPolicy`), and holds no
/// reference to the system itself, so that its rules are tested with a closure that writes them down.
@MainActor
public final class Lifecycle {
    public private(set) var openWindows: Set<AppWindow> = []
    /// The policy last handed to the system.
    public private(set) var policy: ActivationPolicy?

    private let menuBarEnabled: () -> Bool
    private let setPolicy: (ActivationPolicy) -> Void
    /// Whether the window that opened with the app should stay, once the launch is known.
    private var launchDecision: Bool?
    /// A login launch with the menu bar item on: the window that opened with the app is to close, and until it has, it does not
    /// bring the Dock icon back.
    private var launchWindowUnwanted = false
    /// The main window was told once that it should not stay.
    private var launchWindowRefused = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    public init(menuBarEnabled: @escaping () -> Bool, setPolicy: @escaping (ActivationPolicy) -> Void) {
        self.menuBarEnabled = menuBarEnabled
        self.setPolicy = setPolicy
    }

    public var terminatesAfterLastWindowClosed: Bool {
        LifecyclePolicy.terminatesAfterLastWindowClosed(menuBarEnabled: menuBarEnabled())
    }

    /// The app has finished launching. Returns whether the window that opens with it should stay open. Only the first call
    /// decides.
    @discardableResult
    public func launched(by event: LaunchEvent?) -> Bool {
        if let launchDecision { return launchDecision }
        let opens = LifecyclePolicy.opensWindowAtLaunch(menuBarEnabled: menuBarEnabled(), launchedAtLogin: event?.isLoginLaunch ?? false)
        launchDecision = opens
        launchWindowUnwanted = !opens
        // The window that opens with the app counts from the start, so the Dock icon does not blink while it comes forward.
        if opens { openWindows.insert(.main) }
        update()
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume(returning: opens) }
        return opens
    }

    /// Asked by the main window when it appears: should it stay? Only the window that opened with a login launch (with the menu
    /// bar item on) is told no, and only once; a window the person opens is always told yes. Waits for the launch to be known,
    /// but never for more than `limit` seconds: then the launch is taken to be an ordinary one.
    public func mainWindowShouldStay(limit: TimeInterval = 3) async -> Bool {
        if launchDecision == nil {
            let fallback = Task { @MainActor in
                try? await Task.sleep(for: .seconds(limit))
                if !Task.isCancelled { self.launched(by: nil) }
            }
            _ = await waitForLaunch()
            fallback.cancel()
        }
        guard launchWindowUnwanted, !launchWindowRefused else { return true }
        launchWindowRefused = true
        return false
    }

    private func waitForLaunch() async -> Bool {
        if let launchDecision { return launchDecision }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// The person asked for the main window (the popover, the notification, the Dock or the app opened again): it is wanted,
    /// and the Dock icon comes back at once, so that the window can come forward.
    public func openingMainWindow() {
        launchWindowUnwanted = false
        launchWindowRefused = true
        openWindows.insert(.main)
        update()
    }

    /// One of cmm's windows opened or came forward.
    public func windowOpened(_ window: AppWindow) {
        openWindows.insert(window)
        update()
    }

    /// One of cmm's windows is closing.
    public func windowClosed(_ window: AppWindow) {
        openWindows.remove(window)
        if window == .main { launchWindowUnwanted = false }
        update()
    }

    /// The menu bar item was switched on or off.
    public func menuBarChanged() {
        update()
    }

    private func update() {
        var counted = openWindows
        if launchWindowUnwanted { counted.remove(.main) }
        let next = LifecyclePolicy.activationPolicy(menuBarEnabled: menuBarEnabled(), openWindows: counted)
        guard next != policy else { return }
        policy = next
        setPolicy(next)
    }
}
