import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// Renders every screen of the window offscreen, in light and dark, to prove that each one draws, that all of
/// them follow the system appearance (no hard-coded colors that vanish in one of the modes) and that the
/// states are reachable through the real view model. Set CMM_SNAPSHOT_DIR to a folder to keep the pictures.
///
/// What a picture cannot show (labels, shortcuts, which button is the default) is covered by the source checks
/// in SafetyRulesTests and by the view model tests.
@MainActor
final class AppViewsTests: XCTestCase {
    static let home = "/Users/test"
    static let windowSize = CGSize(width: 880, height: 680)

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    // MARK: rendering

    func render<V: View>(
        _ view: V,
        name: String,
        appearance: NSAppearance.Name,
        size: CGSize = AppViewsTests.windowSize
    ) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))  // let SwiftUI settle
        hosting.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        if let directory = ProcessInfo.processInfo.environment["CMM_SNAPSHOT_DIR"], !directory.isEmpty {
            let label = appearance == .darkAqua ? "dark" : "light"
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(label).png")
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url) }
        }
        window.contentView = nil
        return bitmap
    }

    /// Mean brightness (0 black ... 1 white) over a grid of pixels.
    func brightness(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0.0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 20) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 20) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
    }

    /// How many distinct colors a grid of pixels has; a blank render has one.
    func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return seen.count
    }

    // MARK: scenarios: each screen of the window, reached through the real view model

    enum Scenario: String, CaseIterable {
        case scanning, ready, readyOpen, readyMixed, empty, cleaning
        case done, doneWithProblems, doneStopped, scanFailed, cmmMissing, schemaMismatch, cleanFailed
    }

    /// A model in the state of `scenario`, and what to call when the picture is taken to let it wind down.
    struct Rig {
        let model: AppModel
        var expanded: Set<String> = []
        var finish: () async -> Void = {}
    }

    func rig(for scenario: Scenario) async throws -> Rig {
        let plan = try TestPlans.fixture("plan-v1.json")
        let paths = plan.items.map(\.path)

        switch scenario {
        case .scanning:
            let fake = FakeCmmClient(plan: plan)
            let gate = fake.holdPlans()
            let model = AppModel(client: fake)
            let task = Task { await model.scan() }
            await eventuallyOnMain { model.phase == .scanning }
            return Rig(model: model, finish: { gate.open(); await task.value })

        case .ready, .readyOpen, .readyMixed:
            let model = AppModel(client: FakeCmmClient(plan: plan))
            await model.scan()
            if scenario == .readyMixed, let group = model.selection?.groups.first, let item = group.items.first {
                model.toggle(item)  // one of two ticked: the group shows the "mixed" dash
                if let last = model.selection?.groups.last { model.toggle(last) }
            }
            let open = scenario == .ready ? [] : Set((model.selection?.groups ?? []).map(\.name))
            return Rig(model: model, expanded: open)

        case .empty:
            let model = AppModel(client: FakeCmmClient(plan: try TestPlans.fixture("plan-empty.json")))
            await model.scan()
            return Rig(model: model)

        case .cleaning:
            let fake = FakeCmmClient(plan: plan)
            let model = AppModel(client: fake)
            await model.scan()
            model.requestClean()
            let confirmation = try XCTUnwrap(model.confirmation)
            let task = Task { await model.confirmClean(confirmation) }
            _ = await fake.waitForApply()
            fake.send(Events.start(selected: 4, bytes: 3_081_535_488))
            fake.send(Events.item(paths[0], .deleted, bytes: 927_080_448))
            fake.send(Events.item(paths[1], .skipped, bytes: 838_086_656, reason: "in use: node (pid 1234) has files open"))
            fake.send(Events.item(paths[2], .failed, bytes: 612_368_384, reason: "remove failed: permission denied"))
            await eventuallyOnMain { model.progress.items.count == 3 }
            return Rig(model: model, finish: {
                fake.send(Events.done(deleted: 1, skipped: 1, failed: 1, freed: 927_080_448))
                fake.finish()
                await task.value
            })

        case .done, .doneWithProblems, .doneStopped:
            let fake = FakeCmmClient(plan: plan)
            let problems = scenario == .doneWithProblems
            let stopped = scenario == .doneStopped
            var events: [ApplyEvent] = [
                Events.start(selected: 4),
                Events.item(paths[0], .deleted, bytes: 927_080_448),
                Events.item(paths[3], .deleted, bytes: 704_000_000),
            ]
            if problems {
                events.append(Events.item(paths[1], .skipped, bytes: 838_086_656, reason: "in use: node (pid 1234) has files open"))
                events.append(Events.item(paths[2], .failed, bytes: 612_368_384, reason: "remove failed: permission denied"))
                events.append(.unreadable("garbage {"))
            }
            events.append(Events.done(
                deleted: 2, skipped: problems ? 1 : 0, failed: problems ? 1 : 0, freed: 1_631_080_448,
                before: 27_633_246_208, stopped: stopped,
                warnings: problems ? ["could not write the cleanup log: permission denied"] : [],
                log: problems ? nil : "/Users/test/.local/state/cmm/cleanup.log"
            ))
            fake.script(.replay(events, error: nil))
            let model = AppModel(client: fake)
            await model.scan()
            model.requestClean()
            await model.confirmClean(try XCTUnwrap(model.confirmation))
            return Rig(model: model)

        case .scanFailed, .cmmMissing, .schemaMismatch:
            let error: CmmError = switch scenario {
            case .cmmMissing: .binaryNotFound(path: "/Applications/Cmm.app/Contents/Resources/cmm")
            case .schemaMismatch: .unsupportedSchema(found: 2)
            default: .planFailed(status: 2, stderr: "cmm: cannot read the free space of /System/Volumes/Data")
            }
            let model = AppModel(client: FakeCmmClient(plans: [.failure(error)]))
            await model.scan()
            return Rig(model: model)

        case .cleanFailed:
            let fake = FakeCmmClient(plan: plan)
            fake.script(.replay([
                Events.start(selected: 4),
                Events.item(paths[0], .deleted, bytes: 927_080_448),
                Events.item(paths[1], .skipped, bytes: 838_086_656, reason: "in use: node (pid 1234) has files open"),
            ], error: .applyFailed(status: 1, stderr: "cmm: the volume went away")))
            let model = AppModel(client: fake)
            await model.scan()
            model.requestClean()
            await model.confirmClean(try XCTUnwrap(model.confirmation))
            return Rig(model: model)
        }
    }

    // MARK: tests

    func testEveryScreenDrawsInLightAndDarkAndFollowsTheSystemAppearance() async throws {
        for scenario in Scenario.allCases {
            let rig = try await rig(for: scenario)
            let view = RootView(model: rig.model, home: Self.home, expanded: rig.expanded)

            let light = try render(view, name: scenario.rawValue, appearance: .aqua)
            let dark = try render(view, name: scenario.rawValue, appearance: .darkAqua)
            await rig.finish()

            XCTAssertEqual(light.pixelsWide, Int(Self.windowSize.width) * Int(light.pixelsWide / Int(Self.windowSize.width)))
            XCTAssertGreaterThan(distinctColors(light), 8, "\(scenario) looks blank in light mode")
            XCTAssertGreaterThan(distinctColors(dark), 8, "\(scenario) looks blank in dark mode")
            XCTAssertGreaterThan(brightness(light), 0.6, "\(scenario) is not light in light mode")
            XCTAssertLessThan(brightness(dark), 0.4, "\(scenario) is not dark in dark mode")
        }
    }

    func testTheModelReachedEachScenarioItClaims() async throws {
        let expected: [Scenario: AppModel.Phase] = [
            .scanning: .scanning, .ready: .ready, .readyOpen: .ready, .readyMixed: .ready, .empty: .empty,
            .cleaning: .cleaning, .done: .done, .doneWithProblems: .done, .doneStopped: .done,
            .scanFailed: .failed, .cmmMissing: .failed, .schemaMismatch: .failed, .cleanFailed: .failed,
        ]
        for scenario in Scenario.allCases {
            let rig = try await rig(for: scenario)
            XCTAssertEqual(rig.model.phase, expected[scenario], "\(scenario)")
            await rig.finish()
        }
    }

    func testTheConfirmationSheetDrawsInBothAppearances() async throws {
        let plan = try TestPlans.fixture("plan-v1.json")
        let model = AppModel(client: FakeCmmClient(plan: plan))
        await model.scan()
        model.requestClean()
        let confirmation = try XCTUnwrap(model.confirmation)
        // A sheet gets its background from the sheet window; offscreen it has to be supplied.
        let sheet = ConfirmSheet(confirmation: confirmation, cancel: {}, clean: {})
            .background(Color(nsColor: .windowBackgroundColor))
        let size = CGSize(width: 440, height: 150)

        let light = try render(sheet, name: "sheet", appearance: .aqua, size: size)
        let dark = try render(sheet, name: "sheet", appearance: .darkAqua, size: size)

        XCTAssertGreaterThan(distinctColors(light), 8)
        XCTAssertGreaterThan(distinctColors(dark), 8)
        XCTAssertGreaterThan(brightness(light), 0.6)
        XCTAssertLessThan(brightness(dark), 0.4)
    }

    func testTheWindowStillDrawsWithAHundredGroupsOfTwentyItems() async throws {
        // A big plan must not break the layout or take forever (the list is lazy).
        var items: [PlanItem] = []
        for g in 0..<100 {
            for i in 0..<20 {
                items.append(TestPlans.item(
                    "/Users/test/projects/p\(g)/node_modules/pkg\(i)", group: "Project \(g) dependencies",
                    bytes: Int64(1_000_000 * (g + 1) + i), note: i == 0 ? "untouched for 9+ days" : nil
                ))
            }
        }
        let model = AppModel(client: FakeCmmClient(plan: TestPlans.plan(items)))
        await model.scan()
        let start = Date()
        let bitmap = try render(
            RootView(model: model, home: Self.home, expanded: ["Project 99 dependencies"]),
            name: "big-plan", appearance: .aqua
        )
        XCTAssertGreaterThan(distinctColors(bitmap), 8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(model.selection?.selectedCount, 2000)
    }
}
