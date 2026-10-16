import AppKit
import CmmKit
import SwiftUI

/// The app: one window called "cmm" with no title bar, opening on a scan. Nothing here can delete anything: cleaning
/// needs the confirmation card (see `AppModel`).
@main
struct CmmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var window: WindowState
    @State private var history: HistoryModel
    @State private var services: AppServices

    /// One engine client for everything that talks to cmm: the window's scans and cleanups, and the History face's reads.
    /// The services own what is shared beyond the window (the settings, the lifecycle) and hold no client of their own.
    init() {
        let client = ProcessCmmClient()
        let model = AppModel(client: client)
        let window = WindowState(face: FacePreference.load())
        let history = HistoryModel(client: client)
        _model = State(initialValue: model)
        _window = State(initialValue: window)
        _history = State(initialValue: history)
        _services = State(initialValue: AppServices.start(model: model, window: window, history: history))
    }

    var body: some Scene {
        Window("cmm", id: "main") {
            RootView(model: model, window: window)
                .environment(history)
                .environment(services.settings)
                .frame(minWidth: HeroLayout.minimumWidth, minHeight: HeroLayout.minimumHeight)
                .background(WindowChrome())
                .modifier(MainWindowHandOff(services: services))
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CmmCommands(model: model, window: window) }

        // The menu bar item, while the person has it switched on (they can also take it out of the menu bar themselves).
        MenuBarExtra(isInserted: menuBarShown) {
            MenuBarPopoverHost(services: services)
        } label: {
            MenuBarItemLabel(services: services)
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar switch, read here so that the scene follows it.
    private var menuBarShown: Binding<Bool> {
        let settings = services.settings
        return Binding(get: { settings.menuBarEnabled }, set: { settings.menuBarEnabled = $0 })
    }
}

/// The menu: Rescan (⌘R) and Show or Hide Details (⌘I). They live here, not on the buttons, so they work wherever the
/// focus is, and they are off while a scan or a cleanup runs or the confirmation card is open.
struct CmmCommands: Commands {
    let model: AppModel
    let window: WindowState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Rescan") { Task { await model.scan() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.phase == .scanning || model.phase == .cleaning || model.confirmation != nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(window.detailsOpen ? "Hide Details" : "Show Details") { window.toggleDetails() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.phase != .ready || model.confirmation != nil)
        }
    }
}

/// A window without a title bar still has to be draggable, and its content runs under where the bar would be.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Self.configure(view.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

/// The application's delegate, which SwiftUI makes: the lifecycle's moments, handed to the services.
///
/// With the menu bar item off, closing the window ends the app, as it always did. With it on, the app stays in the menu bar
/// (`Lifecycle`). Either way a cleanup that is still running when the window closes is asked to stop after the item it is on
/// (the person walked away; doing less than they confirmed is always safe). When the app then quits, it exits at once, so cmm
/// may be ended by a broken pipe at its next line of output; what it already logged stays logged.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices? { AppServices.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        services?.didFinishLaunching(event: AppleEventLaunchSource().launchEvent())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        services?.lifecycle.terminatesAfterLastWindowClosed ?? true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.reopen(hasVisibleWindows: flag) ?? true
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.model.shutdown()
    }
}
