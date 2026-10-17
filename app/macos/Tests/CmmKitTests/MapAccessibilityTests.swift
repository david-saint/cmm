import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// What VoiceOver finds, read from the accessibility tree the hosted window really has (it is only built for something
/// that asks, so the tests ask as an assistive app does): the map is a group of buttons, each one saying what it is, how big
/// it is, what tier and whether it is ticked, and pressing one does what the click does.
@MainActor
final class MapAccessibilityTests: XCTestCase {
    /// One node of the tree, read through the accessibility API and nothing else.
    private struct Node {
        let object: NSObject

        var role: String { (object.value(forKey: "accessibilityRole") as? String) ?? "" }
        var label: String { (object.value(forKey: "accessibilityLabel") as? String) ?? "" }
        var value: String {
            let value = object.value(forKey: "accessibilityValue")
            return value.map { String(describing: $0) } ?? ""
        }
        var help: String { (object.value(forKey: "accessibilityHelp") as? String) ?? "" }
        var selected: Bool {
            object.responds(to: NSSelectorFromString("isAccessibilitySelected")) && (object.value(forKey: "isAccessibilitySelected") as? Bool) == true
        }
        var children: [Node] { ((object.value(forKey: "accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(Node.init) } }
        var customActions: [String] { ((object.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []).map(\.name) }

        func find(label: String) -> Node? {
            if self.label == label { return self }
            for child in children { if let found = child.find(label: label) { return found } }
            return nil
        }

        func all(where test: (Node) -> Bool) -> [Node] {
            (test(self) ? [self] : []) + children.flatMap { $0.all(where: test) }
        }

        /// What VoiceOver does when the person activates the element (VO-Space).
        @discardableResult
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        }
    }

    private struct Rig {
        let model: AppModel
        let state: WindowState
        let hosting: NSView
        let map: MapModel
        var root: Node { Node(object: hosting) }
    }

    private let size = CGSize(width: 1100, height: 720)

    private func rig(detailsOpen: Bool = true, face: DetailsFace = .map, ticking: (AppModel) -> Void = { _ in }) async throws -> Rig {
        _ = NSApplication.shared
        // an assistive app asking for the tree is what makes SwiftUI build it
        func ask(_ on: Bool) {
            // (the AppKit call that an assistive app's request ends in has no replacement, only a deprecation)
            let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
            for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                _ = NSApp.perform(selector, with: NSNumber(value: on), with: attribute as NSString)
            }
        }
        ask(true)
        addTeardownBlock { @MainActor in ask(false) }

        let model = AppModel(client: FakeCmmClient(plan: try TestPlans.fixture("plan-c.json")), now: { BoardClock.finished })
        await model.scan()
        ticking(model)
        let state = WindowState(detailsOpen: detailsOpen, face: face)
        let hosting = NSHostingView(rootView: RootView(model: model, window: state, env: AppViewsTests.env).frame(width: size.width, height: size.height))
        let window = OffscreenWindow(size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.orderOut(nil)
        }
        let map = MapModel(selection: try XCTUnwrap(model.selection), size: HeroLayout.mapArea(windowHeight: size.height), home: "/Users/test")
        try? await Task.sleep(for: .seconds(0.5))
        return Rig(model: model, state: state, hosting: hosting, map: map)
    }

    private func mapGroup(_ rig: Rig) throws -> Node {
        try XCTUnwrap(rig.root.find(label: "Reclaimable space map"), "the map is a group of its own")
    }

    // MARK: the map

    func testTheMapIsOneGroupWithAButtonPerTileInTheOrderOfTheLayout() async throws {
        let rig = try await rig()
        let group = try mapGroup(rig)
        XCTAssertEqual(group.role, "AXGroup")
        let buttons = group.children
        XCTAssertEqual(buttons.map(\.role), Array(repeating: "AXButton", count: rig.map.tiles.count))
        XCTAssertEqual(buttons.map(\.label), rig.map.tiles.map(\.accessibilityLabel), "in reading order: the layout's order, largest first")
        XCTAssertEqual(buttons.count, 10, "Docker's three cleanups are one tile")
    }

    func testEachTileSaysItsNameItsSizeItsTierAndWhetherItIsTicked() async throws {
        let rig = try await rig()
        let group = try mapGroup(rig)
        func spoken(_ label: String) throws -> String {
            let node = try XCTUnwrap(group.find(label: label), label)
            return "\(node.label), \(node.value)"
        }
        XCTAssertEqual(try spoken("lane-a node_modules"), "lane-a node_modules, 1.4 GB, safe to remove, ticked")
        XCTAssertEqual(try spoken("Docker"), "Docker, 9.0 GB, review, not ticked")
        XCTAssertEqual(try spoken("uv cache"), "uv cache, 2.5 GB, safe to remove, ticked")
        XCTAssertEqual(group.find(label: "Docker")?.help, "Ticks or unticks all 3 cleanups")
        XCTAssertEqual(group.find(label: "uv cache")?.help, "Ticks or unticks this item")
    }

    func testEveryTilesSpeechIsWhatTheMapModelSays() async throws {
        let rig = try await rig()
        for (node, tile) in zip(try mapGroup(rig).children, rig.map.tiles) {
            XCTAssertEqual("\(node.label), \(node.value)", tile.spoken)
            XCTAssertEqual(node.help, tile.accessibilityHint)
        }
    }

    func testPressingATileAsVoiceOverDoesTicksItAndWhatItSaysFollows() async throws {
        let rig = try await rig()
        let before = rig.model.selection?.selectedCount ?? -1
        let docker = try XCTUnwrap(try mapGroup(rig).find(label: "Docker"))
        XCTAssertTrue(docker.press())
        try? await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(rig.model.selection?.selectedCount, before + 3, "the default action ticks Docker's three cleanups")
        let again = try XCTUnwrap(try mapGroup(rig).find(label: "Docker"))
        XCTAssertEqual(again.value, "9.0 GB, review, ticked")
        XCTAssertTrue(again.press())
        try? await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(rig.model.selection?.selectedCount, before)
        XCTAssertEqual(try mapGroup(rig).find(label: "Docker")?.value, "9.0 GB, review, not ticked")
    }

    func testTheHeadlineIsAHeadingAndFollowsWhatIsTicked() async throws {
        let rig = try await rig { model in
            model.toggle(model.selection!.groups.first { $0.rule == "uv-cache" }!.items[0])
        }
        let heading = try XCTUnwrap(rig.root.all { $0.role == "AXHeading" && $0.label.hasSuffix("will go.") }.first)
        XCTAssertEqual(heading.label, "5.9 GB will go.")
        XCTAssertEqual(heading.value, "Macintosh HD · 19.8 GB free of 228 GB")
    }

    // MARK: the band

    func testTheBandIsOneSentenceThatOffersToShowTheMapAndItsSlicesAreNotInTheTree() async throws {
        let rig = try await rig()  // the map is open: the band is magnified and its slices are there for the pointer
        let sentence = "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB needs your review"
        let band = try XCTUnwrap(rig.root.find(label: sentence))
        XCTAssertEqual(band.customActions, ["Show the map"])
        XCTAssertTrue(band.children.isEmpty, "the slices are the pointer's: VoiceOver has the map's tiles")
        // and nothing else in the window is a button without a name
        let nameless = rig.root.all { $0.role == "AXButton" && $0.label.isEmpty }
        XCTAssertTrue(nameless.isEmpty, "every button says what it is")
    }

    // MARK: the other face, the switch and the card

    func testTheListIsTheFullAccessibleRepresentationToo() async throws {
        let rig = try await rig(face: .list)
        XCTAssertNil(rig.root.find(label: "Reclaimable space map"))
        let rows = rig.root.all { $0.role == "AXButton" && $0.label.contains(" GB") }.map(\.label)
        XCTAssertTrue(rows.contains("Idle lane dependencies, 4 items, 3.6 GB"))
        XCTAssertTrue(rows.contains("uv cache, 1 item, 2.5 GB"))
        XCTAssertTrue(rows.contains("Docker, 3 items, 9.0 GB, needs your review"))
    }

    func testTheSwitchSaysWhichFaceIsShowing() async throws {
        let map = try await rig(face: .map)
        XCTAssertTrue(try XCTUnwrap(map.root.find(label: "Map")).selected)
        XCTAssertFalse(try XCTUnwrap(map.root.find(label: "List")).selected)
        XCTAssertEqual(try XCTUnwrap(map.root.find(label: "List")).help, "Shows the list of what cmm found")

        let list = try await rig(face: .list)
        XCTAssertTrue(try XCTUnwrap(list.root.find(label: "List")).selected)
        XCTAssertFalse(try XCTUnwrap(list.root.find(label: "Map")).selected)
        XCTAssertEqual(try XCTUnwrap(list.root.find(label: "Map")).help, "Shows the map of what cmm found")
    }

    func testBehindTheCardOnlyTheCardIsReachable() async throws {
        let rig = try await rig()
        rig.model.requestClean()
        try? await Task.sleep(for: .seconds(0.6))
        XCTAssertNil(rig.root.find(label: "Reclaimable space map"), "the screen behind the card is hidden from VoiceOver")
        XCTAssertNotNil(rig.root.all { $0.label.hasPrefix("Confirm: Delete") }.first)
        XCTAssertNotNil(rig.root.find(label: "Cancel"))
    }
}
