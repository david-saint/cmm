import AppKit
import CmmKit
import SwiftUI

/// The app: one window called "cmm". It starts scanning when the window first appears and does nothing that can
/// delete anything on its own; cleaning needs the confirmation sheet (see `AppModel`).
@main
struct CmmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(client: ProcessCmmClient())

    var body: some Scene {
        Window("cmm", id: "main") {
            RootView(model: model)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear { delegate.model = model }
                .task {
                    if model.phase == .idle { await model.scan() }
                }
        }
        .defaultSize(width: 880, height: 680)
        .windowResizability(.contentMinSize)
    }
}

/// Quitting: closing the window ends the app, and a cleanup that is still running is asked to stop after the item
/// it is on (the person walked away; doing less than they confirmed is always safe).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
