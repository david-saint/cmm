import AppKit
import CmmKit
import SwiftUI

/// The menu bar item's label, as the app shows it: what the services say now. It lives as long as the item is in the menu bar,
/// so it is also where SwiftUI's way to open the main window is kept from, for a click on the notification while no window is
/// open.
struct MenuBarItemLabel: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(item: services.menuBarPresentation().item)
            .onAppear { services.openWindow = openWindow }
    }
}

/// The popover, as the app shows it: what the services say now, and what each of its actions does. There are five, and none of
/// them cleans (`MenuBarAction`).
struct MenuBarPopoverHost: View {
    let services: AppServices
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = services.menuBarPresentation()
        MenuBarPopoverView(presentation: presentation, scanEnabled: services.menuBarScanEnabled(presentation), perform: perform)
            .onAppear { services.openWindow = openWindow }
    }

    private func perform(_ action: MenuBarAction) {
        switch action {
        case .scan: services.scanFromMenuBar()
        case .openWindow: services.openMainWindow()
        case .openHistory: services.openHistory()
        case .openSettings: services.openSettings(openSettings)
        case .quit: NSApp.terminate(nil)
        }
    }
}
