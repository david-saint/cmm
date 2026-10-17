import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// The accessibility tree a hosted view really has, read through the accessibility API and nothing else (as `MapAccessibilityTests`
/// reads the window's): what VoiceOver finds, and what it does when it presses something.
@MainActor
struct AXNode {
    let object: NSObject

    var role: String { (object.value(forKey: "accessibilityRole") as? String) ?? "" }
    var label: String { (object.value(forKey: "accessibilityLabel") as? String) ?? "" }
    var help: String { (object.value(forKey: "accessibilityHelp") as? String) ?? "" }
    var value: String {
        let value = object.value(forKey: "accessibilityValue")
        return value.map { String(describing: $0) } ?? ""
    }
    var isEnabled: Bool { (object.value(forKey: "isAccessibilityEnabled") as? Bool) ?? true }
    var children: [AXNode] {
        ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(AXNode.init) }
    }

    func find(label: String) -> AXNode? {
        if self.label == label { return self }
        for child in children { if let found = child.find(label: label) { return found } }
        return nil
    }

    func all(where test: (AXNode) -> Bool) -> [AXNode] {
        (test(self) ? [self] : []) + children.flatMap { $0.all(where: test) }
    }

    /// Every label in the tree.
    var labels: [String] { all { !$0.label.isEmpty }.map(\.label) }

    /// What VoiceOver does when the person activates the element (VO-Space).
    @discardableResult
    func press() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

/// A view hosted in a real window kept off every screen, with the accessibility tree built (it is only built for someone who
/// asks, so the test asks as an assistive app does).
@MainActor
final class HostedForAccessibility {
    let window: OffscreenWindow
    let hosting: NSView

    var root: AXNode { AXNode(object: hosting) }

    init<V: View>(_ view: V, size: CGSize, test: XCTestCase) async {
        _ = NSApplication.shared
        func ask(_ on: Bool) {
            // (the AppKit call that an assistive app's request ends in has no replacement, only a deprecation)
            let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
            for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                _ = NSApp.perform(selector, with: NSNumber(value: on), with: attribute as NSString)
            }
        }
        ask(true)
        let hosting = NSHostingView(rootView: view.environment(\.cmm, AppViewsTests.env).frame(width: size.width, height: size.height))
        let window = OffscreenWindow(size: size)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.hosting = hosting
        test.addTeardownBlock { @MainActor in
            ask(false)
            window.contentView = nil
            window.orderOut(nil)
        }
        try? await Task.sleep(for: .seconds(0.5))
    }

    /// A click in the middle of an element, as the system sends it to the window (for controls whose accessibility node offers no
    /// press of its own, such as the form's switches).
    func click(_ node: AXNode) async {
        guard let frame = (node.object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for (type, number) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!
            NSApp.sendEvent(event)
        }
        try? await Task.sleep(for: .seconds(0.2))
    }

    /// A key, as the system sends it to the window.
    func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
        NSApp.sendEvent(event)
        try? await Task.sleep(for: .seconds(0.15))
    }
}
