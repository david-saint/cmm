import AppKit

/// A window that stays where it is put, however far off the screen that is, so a test can have a real, key window with a real
/// first responder (and a real accessibility tree) without showing anything to the person running it.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A borderless window of this size, far to the left of and above every screen.
    convenience init(size: CGSize) {
        self.init(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
    }
}
