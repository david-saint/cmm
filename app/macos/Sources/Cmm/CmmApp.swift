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

    /// One engine client for everything that talks to cmm: the window's scans and cleanups, and the History face's reads.
    init() {
        let client = ProcessCmmClient()
        _model = State(initialValue: AppModel(client: client))
        _window = State(initialValue: WindowState(face: FacePreference.load()))
        _history = State(initialValue: HistoryModel(client: client))
    }

    var body: some Scene {
        Window("cmm", id: "main") {
            RootView(model: model, window: window)
                .environment(history)
                .frame(minWidth: HeroLayout.minimumWidth, minHeight: HeroLayout.minimumHeight)
                .background(WindowChrome())
                .onAppear { delegate.model = model }
                .task {
                    if model.phase == .idle { await model.scan() }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CmmCommands(model: model, window: window) }
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

/// Closing the window ends the app. A cleanup that is still running is asked to stop after the item it is on (the
/// person walked away; doing less than they confirmed is always safe). The app then exits at once, so cmm may be ended
/// by a broken pipe at its next line of output; what it already logged stays logged.
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
