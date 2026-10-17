import AppKit
import CmmKit
import ServiceManagement

// The thin adaptors between CmmKit's protocols and what macOS keeps: Open at login (`SMAppService`) and the Apple event the app
// was launched with. Each one only passes things through; the rules they serve are CmmKit's, tested with fakes. No test makes
// one of these (a source test checks it), so no test can touch the person's login items.

/// Whether the app runs from its bundle (`build/Cmm.app`). `swift run Cmm` starts the bare executable, which macOS's login items
/// and notifications do not know (asking them from there can even end the process), so the adaptors then do nothing.
enum SystemBundle {
    static var isApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}

/// Open at login, as macOS keeps it: the app itself as a login item (`SMAppService.mainApp`). What macOS says is what the switch
/// shows; the app never keeps it.
struct SystemLoginItem: LoginItem {
    struct NotAnApp: Error {}

    var state: LoginItemState {
        guard SystemBundle.isApp else { return .off }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard SystemBundle.isApp else { throw NotAnApp() }
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    /// System Settings > General > Login Items, where the person can see and undo it.
    @MainActor
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The Apple event the app is being launched with, read while it finishes launching (the only moment it is there).
@MainActor
struct AppleEventLaunchSource: LaunchEventSource {
    func launchEvent() -> LaunchEvent? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        let data = event.paramDescriptor(forKeyword: AEKeyword(LaunchEvent.propertyData))
        return LaunchEvent(eventClass: event.eventClass, eventID: event.eventID, propertyData: data?.enumCodeValue)
    }
}
