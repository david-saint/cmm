import AppKit
import CmmKit
import SwiftUI
import os

/// The one owner of the app's objects: the window's model and state, the History's model, the settings, the lifecycle, the menu
/// bar item's memory and the background services, so that the scenes, the application delegate and the background services share
/// exactly one of each. It is made once, when the app starts (`CmmApp.init`), around the models that the one engine client serves
/// (and the sampler, which asks that client for its notes); it holds no client of its own.
///
/// What it decides, it asks CmmKit: the Dock icon and quitting (`Lifecycle`), what closing the window asks of a cleaning and the
/// card (`LifecyclePolicy`), what "at rest" means (`WindowState.comeToRest`), when the sampler and the reminder run
/// (`BackgroundServices`) and what the reminder scans (`WeeklyScan`). What is left here is telling the system.
@MainActor
final class AppServices {
    /// The services of the running app. The application delegate is made by SwiftUI, and reaches them here.
    private(set) static var shared: AppServices?

    let model: AppModel
    let window: WindowState
    let history: HistoryModel
    let settings: SettingsModel
    let lifecycle: Lifecycle
    let menuBar: MenuBarModel
    /// Hears of the window's scans and cleanings, window or no window.
    let watcher: AppModelWatcher
    /// The free-space sampler and the Monday reminder, each while its switch is on.
    let background: BackgroundServices

    /// One quiet line for what went wrong in the background (never a path: the lines are made in CmmKit without one).
    nonisolated static let log = Logger(subsystem: "com.davidsaint.cmm", category: "background")

    /// SwiftUI's own way to open the main window, kept from a view that has it: a click on the notification and cmm opened again
    /// from Finder come from outside SwiftUI.
    var openWindow: OpenWindowAction?

    /// cmm's own windows, as the system has them, and what they are. Held weakly: a window the system lets go is forgotten.
    private var tracked: [TrackedWindow] = []
    private var menuBarWatch: Watch<Bool>?
    private var historyWatch: Watch<HistoryReport?>?
    /// The notification centre's delegate, kept here (the centre holds it weakly).
    private var notificationClicks: NotificationClickHandler?

    private final class TrackedWindow {
        weak var window: NSWindow?
        let kind: AppWindow
        var observers: [NSObjectProtocol] = []

        init(window: NSWindow, kind: AppWindow) {
            self.window = window
            self.kind = kind
        }
    }

    /// Makes the services of the running app, once. `sampler` makes the free-space sampler, handing its notes to the given
    /// function (the sampler is made where the engine client is, which it asks for them).
    static func start(
        model: AppModel, window: WindowState, history: HistoryModel,
        sampler: (_ onSample: @escaping @MainActor (SampleResult, Date) -> Void) -> SamplerSchedule
    ) -> AppServices {
        let services = AppServices(model: model, window: window, history: history, sampler: sampler)
        shared = services
        services.follow()
        return services
    }

    private init(
        model: AppModel, window: WindowState, history: HistoryModel,
        sampler makeSampler: (_ onSample: @escaping @MainActor (SampleResult, Date) -> Void) -> SamplerSchedule
    ) {
        self.model = model
        self.window = window
        self.history = history
        let permission = SystemNotificationPermission()
        let settings = SettingsModel(settings: .standard, loginItem: SystemLoginItem(), notifications: permission)
        self.settings = settings
        let lifecycle = Lifecycle(
            menuBarEnabled: { settings.menuBarEnabled },
            setPolicy: { policy in _ = NSApp.setActivationPolicy(policy == .regular ? .regular : .accessory) }
        )
        self.lifecycle = lifecycle
        let menuBar = MenuBarModel()
        self.menuBar = menuBar
        let watcher = AppModelWatcher(
            model: model,
            scanFinished: { plan in menuBar.recordScan(plan) },
            cleaningEnded: { _ in }
        )
        self.watcher = watcher

        let log: @Sendable (String) -> Void = { line in AppServices.log.notice("\(line, privacy: .public)") }
        let delivery = NotificationDelivery(permission: permission, poster: SystemNotificationPoster())
        let weekly = WeeklyScan(
            model: model, mainWindowOpen: { lifecycle.openWindows.contains(.main) }, lastScanAt: { watcher.lastScanAt },
            now: { Date() }
        )
        let reminder = WeeklyReminder(
            settings: settings, calendar: .autoupdatingCurrent, now: { Date() },
            scan: { try await weekly.scan() },
            deliver: { note in await delivery.deliver(note) },
            log: log
        )
        background = BackgroundServices(
            settings: settings,
            sampler: makeSampler { result, at in menuBar.recordSample(result, receivedAt: at) },
            reminder: reminder,
            timer: SystemWallClock(),
            heartbeat: SystemActivityScheduler(identifier: "com.davidsaint.cmm.weekly"),
            now: { Date() }
        )
    }

    /// From now on the menu bar item, the sampler and the History hear of the window's scans and cleanings, and the menu bar item
    /// of every history report, whoever asked for it.
    private func follow() {
        watcher.cleaningEnded = { [weak self] summary in self?.cleaningEnded(summary) }
        watcher.start()
        historyWatch = Watch({ [history] in history.report }, changed: { [menuBar] report in
            if let report { menuBar.recordHistory(report) }
        })
    }

    /// A cleaning of the window's ended: the menu bar item says so for an hour, the sampler takes a note of the new free space,
    /// and the History reads cmm's record of the run.
    private func cleaningEnded(_ summary: CleanSummary?) {
        if let summary { menuBar.recordCleaning(summary) }
        Task { await background.cleaningEnded() }
        Task { await history.load() }
    }

    // MARK: launching

    /// cmm is about to finish launching: a click on the weekly note, which may be what launched it, opens the window at rest.
    func willFinishLaunching() {
        notificationClicks = NotificationClickHandler.install { [weak self] in self?.openMainWindow() }
    }

    /// The app has finished launching: the launch's Apple event says whether the window stays (a login launch with the menu bar
    /// item on shows none), and the Dock icon follows the menu bar switch from now on. With the menu bar item on, the history is
    /// read once, for its "Last cleaned" row.
    func didFinishLaunching(event: LaunchEvent?) {
        menuBarWatch = Watch({ [settings] in settings.menuBarEnabled }, changed: { [weak self] on in
            self?.lifecycle.menuBarChanged()
            if on { self?.readHistoryForTheMenuBar() }
        })
        if settings.menuBarEnabled { readHistoryForTheMenuBar() }
        if lifecycle.launched(by: event) { NSApp.activate() }
        Task { await background.start() }
    }

    private func readHistoryForTheMenuBar() {
        guard history.report == nil, !history.isLoading else { return }
        Task { await history.load() }
    }

    // MARK: cmm's windows

    /// A window of cmm's own is there: from now on its coming forward and its closing are followed.
    func track(_ nsWindow: NSWindow, as kind: AppWindow) {
        tracked.removeAll { entry in
            guard entry.window == nil else { return false }
            for observer in entry.observers { NotificationCenter.default.removeObserver(observer) }
            return true
        }
        guard !tracked.contains(where: { $0.window === nsWindow }) else { return }

        let entry = TrackedWindow(window: nsWindow, kind: kind)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            entry.observers.append(center.addObserver(forName: name, object: nsWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lifecycle.windowOpened(kind) }
            })
        }
        entry.observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose(kind) }
        })
        tracked.append(entry)
        if nsWindow.isVisible { lifecycle.windowOpened(kind) }
    }

    /// Whether the main window is open (on the screen or in the Dock).
    var mainWindowOpen: Bool { lifecycle.openWindows.contains(.main) }

    private func windowWillClose(_ kind: AppWindow) {
        if kind == .main {
            let steps = LifecyclePolicy.stepsWhenMainWindowCloses(phase: model.phase, confirmationOpen: model.confirmation != nil)
            for step in steps {
                switch step {
                case .stopCleaning: model.stop()
                case .cancelConfirmation: model.cancelClean()
                }
            }
        }
        lifecycle.windowClosed(kind)
    }

    // MARK: opening the window

    /// Brings cmm forward with its window at rest: the Dock icon back, the pane closed, nothing focused, and an open card
    /// answered with Cancel (which runs nothing). What the window shows otherwise (a scan, a result) stays as it is.
    func openMainWindow() {
        if model.confirmation != nil { model.cancelClean() }
        window.comeToRest()
        bringMainWindowForward()
    }

    /// The menu bar item's "Last cleaned" row: the window at rest, with the pane open on History.
    func openHistory() {
        if model.confirmation != nil { model.cancelClean() }
        window.comeToRestOnHistory()
        bringMainWindowForward()
    }

    private func bringMainWindowForward() {
        lifecycle.opening(.main)
        if let openWindow {
            openWindow(id: "main")
        } else {
            tracked.first { $0.kind == .main }?.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// cmm was opened again (from Finder, the Dock or Spotlight) while it runs. With the menu bar item on, that is a way of opening
    /// the window, so it opens at rest; without it, the system does what it always did. Returns whether the system should still
    /// do its own part.
    func reopen(hasVisibleWindows: Bool) -> Bool {
        guard settings.menuBarEnabled, !hasVisibleWindows else { return true }
        openMainWindow()
        return false
    }

    /// The Settings window, from the popover's `...` menu: the Dock icon back, then the window, then cmm forward.
    func openSettings(_ openSettings: OpenSettingsAction) {
        lifecycle.opening(.settings)
        openSettings()
        NSApp.activate()
    }

    // MARK: the menu bar item

    /// What the menu bar item and its popover show at this moment.
    func menuBarPresentation() -> MenuBarPresentation {
        menuBar.presentation(
            phase: model.phase, confirmationOpen: model.confirmation != nil,
            volumeName: { VolumeName.display(forVolume: $0) }, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent
        )
    }

    /// Whether the popover's Scan may scan now (`MenuBarModel.scanEnabled`).
    func menuBarScanEnabled(_ presentation: MenuBarPresentation) -> Bool {
        MenuBarModel.scanEnabled(
            presentation.popover, phase: model.phase, confirmationOpen: model.confirmation != nil, mainWindowOpen: mainWindowOpen
        )
    }

    /// The popover's Scan: the window's own scan, asked again at the moment of the click, so that it never takes a screen from
    /// someone using it.
    func scanFromMenuBar() {
        guard menuBarScanEnabled(menuBarPresentation()) else { return }
        Task { await model.scan() }
    }
}

/// Tells the services which of cmm's windows a view is in, as soon as it is in one.
struct WindowTracker: NSViewRepresentable {
    let kind: AppWindow
    let services: AppServices

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.report = { [services, kind] window in services.track(window, as: kind) }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var report: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { report?(window) }
        }
    }
}

/// What the main window hands the services: which window it is, SwiftUI's way to open it again, and, once, whether the window
/// that opened with the app should stay (it is the window, not the app, that can close itself). Then the first scan, as before.
struct MainWindowHandOff: ViewModifier {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .background(WindowTracker(kind: .main, services: services))
            .onAppear { services.openWindow = openWindow }
            .task {
                // A login launch with the menu bar item on shows no window: the one SwiftUI opened with the app closes at once,
                // and does not scan.
                let stays = await services.lifecycle.mainWindowShouldStay()
                guard !Task.isCancelled else { return }
                guard stays else { return dismissWindow(id: "main") }
                if services.model.phase == .idle { await services.model.scan() }
            }
    }
}
