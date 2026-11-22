import AppKit
import CmmKit
import SwiftUI

/// The menu bar item's popover (the boards `C-MenuBar-Dark`, drawn at its real size, and `C-MenuBar-States`): the free space in
/// the header, the one number to act on with a serif sentence, the three largest groups, the disk band, a quiet "Last cleaned"
/// row that opens the History, `Scan` and `Open cmm`, and a `...` menu with Open cmm, Settings... and Quit cmm.
///
/// Everything it says comes from `MenuBarPopover`; everything it can do is a `MenuBarAction`, which has no way to clean: a
/// cleaning goes through the window's confirmation card and nowhere else. The system draws the panel it sits on.
struct MenuBarPopoverView: View {
    let presentation: MenuBarPresentation
    /// The window's own rule for ⌘R, and never while a screen of the window is in use (`MenuBarModel.scanEnabled`).
    let scanEnabled: Bool
    let perform: (MenuBarAction) -> Void
    /// Whether the popover sizes the panel it sits in to its content height (on in the menu bar's real panel, off when a test
    /// renders the view on a fixed board canvas).
    var fitsPanel = false

    static let width = 320.0
    private static let inset = 18.0

    @State private var panel = PopoverPanel()

    private var popover: MenuBarPopover { presentation.popover }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
                moreMenu
            }
            .frame(height: 26)

            Group {
                if let number = popover.number {
                    numberBlock(number)
                } else {
                    workingBlock
                }
            }
            .accessibilityHidden(true)  // the header, the number and the sentence are read as one sentence (below)

            if let band = popover.band {
                PopoverBand(band: band, width: Self.width - 2 * Self.inset)
                    .padding(.top, 12)
            }

            if !popover.groups.isEmpty {
                groupList
                    .padding(.top, 12)
            }

            if let row = popover.historyRow {
                historyButton(row)
                    .padding(.top, popover.groups.isEmpty ? 12 : 6)
            }

            buttons
                .padding(.top, 10)
        }
        .padding(.top, 16)
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 16)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                PopoverKeys(panel: panel, contentSize: proxy.size, fitsPanel: fitsPanel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("cmm")
    }

    // MARK: the header, the number and the sentence

    /// The header line, which also carries what VoiceOver reads for the top of the popover: the one thing to act on, then the
    /// free space ("Freed 5.4 GB. 25.2 GB free.").
    private var summary: some View {
        HStack(spacing: 5) {
            if let lead = popover.header.lead {
                Circle().fill(Theme.low).frame(width: 7, height: 7)
                Text(lead).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Text("\u{00B7} \(popover.header.detail)")
            } else {
                Text(popover.header.detail)
            }
        }
        .font(Typeface.ui(11.5, .medium))
        .foregroundStyle(Theme.ink2)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(popover.spoken)
        .accessibilityAddTraits(.isHeader)
    }

    /// `8.4 GB` in a hairline weight and `can go.` in New York under it.
    private func numberBlock(_ number: SizeText.Parts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number.value)
                    .font(Typeface.ui(60, .thin))
                    .tracking(-60 * 0.045)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                Text(number.unit)
                    .font(Typeface.ui(20, .light))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 60 * 0.95)
            .padding(.top, 4)
            sentence
                .padding(.top, 2)
        }
    }

    /// While cmm looks or cleans (and before it has looked): a turning arc and the sentence, and while it looks, that it only looks.
    private var workingBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if popover.isBusy { QuietSpinner(size: 16) }
                sentence
            }
            .padding(.top, 14)
            if let note = popover.note {
                Text(note)
                    .font(Typeface.ui(12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private var sentence: some View {
        Text(popover.sentence)
            .font(Typeface.serif(22))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 22 * 1.2, alignment: .center)
    }

    // MARK: the groups and the history row

    private var groupList: some View {
        VStack(spacing: 0) {
            ForEach(Array(popover.groups.enumerated()), id: \.offset) { _, group in
                HStack {
                    Text(group.title).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(group.sizeText).foregroundStyle(Theme.ink2).monospacedDigit()
                }
                .font(Typeface.ui(13))
                .frame(height: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.title), \(group.sizeText)")
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// "Last cleaned Tue · 5.4 GB" (or "See it in History" right after a cleaning): opens the window on History.
    private func historyButton(_ row: MenuBarPopover.HistoryRow) -> some View {
        Button {
            panel.close()
            perform(.openHistory)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11.5, weight: .medium))
                Text(row.text).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(Typeface.ui(12))
            .foregroundStyle(Theme.ink2)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietRowStyle())
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
        .accessibilityLabel(row.text.replacingOccurrences(of: " \u{00B7} ", with: ", "))
        .accessibilityHint("Opens the History in the cmm window")
    }

    // MARK: the buttons

    private var buttons: some View {
        HStack {
            Button {
                perform(.scan)
            } label: {
                HStack(spacing: 6) {
                    if !popover.isBusy {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(popover.scanTitle)
                }
                .font(Typeface.ui(13, .medium))
                .foregroundStyle(popover.isBusy ? Theme.ink2 : Theme.ink)
                .padding(.horizontal, 4)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietRowStyle())
            .disabled(!scanEnabled)
            .accessibilityLabel(popover.scanTitle.replacingOccurrences(of: "\u{2026}", with: ""))
            .accessibilityHint("Checks what can go. Nothing is removed from here.")

            Spacer()

            Button {
                panel.close()
                perform(.openWindow)
            } label: {
                Text("Open cmm")
            }
            .buttonStyle(PillStyle(look: .solid, height: 32, horizontal: 16, fontSize: 13, shadowed: false))
            .accessibilityHint("Brings the cmm window forward")
        }
    }

    /// `...`: Open cmm, Settings... and Quit cmm, so that Quit is there when the window is closed.
    private var moreMenu: some View {
        Menu {
            Button("Open cmm") {
                panel.close()
                perform(.openWindow)
            }
            Button("Settings\u{2026}") {
                panel.close()
                perform(.openSettings)
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit cmm") { perform(.quit) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .background(Circle().fill(Theme.soft))
        .contentShape(Circle())
        .accessibilityLabel("More")
        .accessibilityHint("Open cmm, Settings and Quit cmm")
    }
}

// MARK: parts

/// The disk band at the popover's size (5 pt): the window's band, segment for segment (`DiskBand`), on the popover's own track.
/// Used is the quiet grey, Docker's review stretch is dotted, what can go is green, what was just freed is a green outline, and
/// free space is a hairline outline.
struct PopoverBand: View {
    let band: DiskBand
    let width: CGFloat
    var height: CGFloat = 5

    var body: some View {
        let frames = band.frames(width: Double(width), gap: 2, minimum: 2)
        ZStack(alignment: .topLeading) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                segment(frame)
                    .frame(width: frame.width, height: height)
                    .offset(x: frame.x)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func segment(_ frame: DiskBand.Frame) -> some View {
        let radius = height / 2
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: frame.roundsLeading ? radius : 0, bottomLeadingRadius: frame.roundsLeading ? radius : 0,
            bottomTrailingRadius: frame.roundsTrailing ? radius : 0, topTrailingRadius: frame.roundsTrailing ? radius : 0,
            style: .continuous
        )
        switch frame.kind {
        case .used: shape.fill(Theme.popoverTrack)
        case .review: DottedFill().clipShape(shape)
        case .selected: shape.fill(Theme.accent)
        case .freed: shape.strokeBorder(Theme.accent, lineWidth: 1)
        case .free: shape.strokeBorder(Theme.hair, lineWidth: 1)
        }
    }
}

/// A button that only dims while it is pressed or switched off: the history row and Scan.
struct QuietRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration)
    }

    private struct QuietBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
        }
    }
}

/// The popover's arc, turning once every 1.1 s in the quiet ink (as on the board), and holding still with Reduce Motion.
struct QuietSpinner: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let turn = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The panel the popover is in, as the popover knows it: so that Esc, and a button that opens a window, can close it.
@MainActor
final class PopoverPanel {
    weak var window: NSWindow?

    func close() {
        window?.close()
    }

    /// The panel's frame resized to `targetHeight` with its top edge (under the menu bar) held fixed.
    nonisolated static func resizedFrame(current: NSRect, targetHeight: CGFloat) -> NSRect {
        var frame = current
        frame.origin.y += frame.height - targetHeight
        frame.size.height = targetHeight
        return frame
    }
}

/// Esc closes the popover, and the system panel is kept at the popover's content height from its top edge.
///
/// The popover sits in a panel of the system's, which does not close on Esc by itself, and which grows with its content
/// but does not reliably shrink (leaving the outer panel and its shadow at the old height while the inner content shrinks
/// inside it). A representable view in the panel answers Esc as a key equivalent, reads the SwiftUI content's measured size,
/// refreshes the hosting view's constraints and panel bounds, and keeps the panel and shadow matched to the content.
struct PopoverKeys: NSViewRepresentable {
    let panel: PopoverPanel
    let contentSize: CGSize
    let fitsPanel: Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.configure(panel: panel, contentSize: contentSize, fitsPanel: fitsPanel)
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.configure(panel: panel, contentSize: contentSize, fitsPanel: fitsPanel)
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.tearDown()
    }

    private final class ObserverTokens {
        private var tokens: [NSObjectProtocol] = []

        func replace(with newTokens: [NSObjectProtocol]) {
            clear()
            tokens = newTokens
        }

        func clear() {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            tokens.removeAll()
        }

        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    final class KeyView: NSView {
        private static let maxFitAttempts = 6
        private static let heightTolerance: CGFloat = 1.0

        var panel: PopoverPanel?
        private var targetContentSize: CGSize = .zero
        private var fitsPanel = false
        private var observedWindowID: ObjectIdentifier?
        private let windowObservers = ObserverTokens()
        private var fitScheduled = false
        private var isResizing = false
        private var lastTargetHeight: CGFloat = 0
        private var attemptsForTarget = 0
        private var retryTask: Task<Void, Never>?

        func configure(panel: PopoverPanel, contentSize: CGSize, fitsPanel: Bool) {
            self.panel = panel
            self.fitsPanel = fitsPanel
            if contentSize.width > 0, contentSize.height > 0 {
                targetContentSize = contentSize
            }
            panel.window = window
            observeWindow(window)
            scheduleFit()
        }

        func tearDown() {
            retryTask?.cancel()
            retryTask = nil
            observeWindow(nil)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow !== window {
                retryTask?.cancel()
                retryTask = nil
                observeWindow(nil)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            panel?.window = window
            observeWindow(window)
            attemptsForTarget = 0
            scheduleFit()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if newSize.width > 0, newSize.height > 0, targetContentSize == .zero {
                targetContentSize = newSize
            }
            scheduleFit()
        }

        override func layout() {
            super.layout()
            scheduleFit()
        }

        private func observeWindow(_ newWindow: NSWindow?) {
            let target = fitsPanel ? newWindow : nil
            let newID = target.map(ObjectIdentifier.init)
            guard newID != observedWindowID else { return }
            windowObservers.clear()
            observedWindowID = newID
            guard let target else { return }
            let center = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []
            tokens.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: target, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowDidResize() }
                }
            )
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                tokens.append(
                    center.addObserver(forName: name, object: target, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.windowDidShow() }
                    }
                )
            }
            windowObservers.replace(with: tokens)
        }

        private func windowDidResize() {
            guard !isResizing else { return }
            scheduleFit()
        }

        private func windowDidShow() {
            guard !isResizing else { return }
            attemptsForTarget = 0
            scheduleFit()
        }

        private func desiredContentSize() -> CGSize? {
            let raw = targetContentSize.height > 0 ? targetContentSize : bounds.size
            guard raw.width > 0, raw.height > 0 else { return nil }
            return CGSize(width: ceil(raw.width), height: ceil(raw.height))
        }

        private func scheduleFit(after delayMilliseconds: Int = 0) {
            guard fitsPanel, let window, window.isVisible, !isResizing else { return }
            guard let content = desiredContentSize() else { return }
            let height = ceil(window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).height)
            let heightChanged = abs(height - lastTargetHeight) > 0.5
            if heightChanged {
                lastTargetHeight = height
                attemptsForTarget = 0
                retryTask?.cancel()
                retryTask = nil
            }
            guard abs(window.frame.height - height) > Self.heightTolerance else {
                if heightChanged {
                    DispatchQueue.main.async { [weak window] in window?.invalidateShadow() }
                }
                return
            }
            guard attemptsForTarget < Self.maxFitAttempts else { return }

            if delayMilliseconds > 0 {
                guard retryTask == nil else { return }
                retryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                    guard !Task.isCancelled, let self else { return }
                    self.retryTask = nil
                    self.performFit()
                }
                return
            }

            guard !fitScheduled else { return }
            fitScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.performFit()
            }
        }

        private func performFit() {
            fitScheduled = false
            guard fitsPanel, let window, window.isVisible, !isResizing else { return }
            guard let content = desiredContentSize() else { return }
            let height = ceil(window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).height)
            if abs(height - lastTargetHeight) > 0.5 {
                lastTargetHeight = height
                attemptsForTarget = 0
            }
            guard abs(window.frame.height - height) > Self.heightTolerance else {
                window.invalidateShadow()
                return
            }
            guard attemptsForTarget < Self.maxFitAttempts else { return }
            attemptsForTarget += 1

            isResizing = true
            let current = window.frame
            // Refresh SwiftUI's hosting view constraints before changing the panel's frame so AppKit does not clamp
            // the shrink back to the previous content height.
            var ancestor = superview
            while let view = ancestor {
                view.invalidateIntrinsicContentSize()
                view.needsUpdateConstraints = true
                if view === window.contentView { break }
                ancestor = view.superview
            }
            window.updateConstraintsIfNeeded()

            if window.contentMinSize.height > content.height {
                window.contentMinSize = NSSize(width: window.contentMinSize.width, height: content.height)
            }
            if window.minSize.height > height {
                window.minSize = NSSize(width: window.minSize.width, height: height)
            }
            if window.contentMaxSize.height > 0, window.contentMaxSize.height < content.height {
                window.contentMaxSize = NSSize(width: window.contentMaxSize.width, height: content.height)
            }
            if window.maxSize.height > 0, window.maxSize.height < height {
                window.maxSize = NSSize(width: window.maxSize.width, height: height)
            }

            let frame = PopoverPanel.resizedFrame(current: current, targetHeight: height)
            window.setFrame(frame, display: true, animate: false)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            window.invalidateShadow()
            isResizing = false

            // WindowServer can keep the old shadow until Core Animation commits the resized layer, and the system's
            // panel can finish settling constraints a beat later: refresh the shadow and re-check the height.
            DispatchQueue.main.async { [weak self, weak window] in
                window?.invalidateShadow()
                self?.scheduleFit(after: 20)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.type == .keyDown, event.keyCode == 53, modifiers.isEmpty, event.window === window else {
                return super.performKeyEquivalent(with: event)
            }
            panel?.close()
            return true
        }
    }
}
