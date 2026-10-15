import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// 14:03 in Berlin, the time on the done board; "now" is the same afternoon.
enum BoardClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    static let finished = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 14, minute: 3))!
    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 30))!
}

/// Renders every screen of design C offscreen, in light and dark (and two screens with Increase Contrast), to prove that
/// each draws, follows the appearance and is reachable through the real view model. Set CMM_SNAPSHOT_DIR to a folder to
/// keep the pictures, one PNG per screen and appearance.
///
/// What a picture cannot show (labels, shortcuts, which button is the default) is covered by the source checks in
/// SafetyRulesTests and by the tests of the pure types they are built from.
@MainActor
final class AppViewsTests: XCTestCase {
    static let windowSize = CGSize(width: 1100, height: 720)

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    // MARK: rendering

    /// `increasedContrast` draws as the system does with Increase Contrast on; a window's appearance cannot flip that
    /// switch, so the views' own environment value stands in for it.
    func render<V: View>(
        _ view: V, name: String, appearance: NSAppearance.Name, increasedContrast: Bool = false, save: Bool = true,
        size: CGSize = AppViewsTests.windowSize
    ) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view.environment(\.cmmIncreasedContrast, increasedContrast).frame(width: size.width, height: size.height)
        )
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))  // let SwiftUI settle (preferences, the card's placement)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        if save, let directory = ProcessInfo.processInfo.environment["CMM_SNAPSHOT_DIR"], !directory.isEmpty {
            let label = (appearance == .darkAqua ? "dark" : "light") + (increasedContrast ? "-contrast" : "")
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

    /// The lowest brightness (0 black ... 1 white) among the pixels of a region (top-left origin).
    func darkest(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Double {
        var lowest = 1.0
        for x in Int(rect.minX)..<Int(rect.maxX) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                lowest = min(lowest, 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
            }
        }
        return lowest
    }

    /// How many distinct colours a grid of pixels has; a blank render has one.
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

    // MARK: the screens, each reached through the real view model

    enum Scenario: String, CaseIterable {
        case scanning
        case rest, restReview, restUnticked, restNoCapacity, restDockerTicked
        case details, detailsExpanded, detailsReviewExpanded
        case sheet, sheetDockerTicked
        case cleaning, cleaningInside, done, doneProblems, doneStopped, doneInside
        case empty
        case errorScan, errorClean, errorMissing
    }

    static let env = ViewEnvironment(
        home: "/Users/test",
        volumeName: { _ in "Macintosh HD" },
        now: { BoardClock.now },
        calendar: BoardClock.calendar,
        locale: Locale(identifier: "en_GB"),
        reveal: { _ in },
        shadowDirection: -1  // cacheDisplay draws layer shadows upside down; see ViewEnvironment
    )

    struct Rig {
        let model: AppModel
        let window: WindowState
        var finish: () async -> Void = {}
    }

    private func gb(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    private func boardPlan() throws -> Plan { try TestPlans.fixture("plan-c.json") }

    /// The board's data without the Docker group: nothing for review.
    private func safeOnlyPlan() throws -> Plan {
        let board = try boardPlan()
        let items = board.items.filter { $0.tier == .safe }
        return TestPlans.plan(items, skipped: board.skipped, freeBytes: board.host.freeBytes, capacityBytes: board.host.capacityBytes)
    }

    private func readyModel(_ plan: Plan, clock: Date = BoardClock.finished, script: FakeCmmClient.ApplyScript? = nil) async -> (AppModel, FakeCmmClient) {
        let fake = FakeCmmClient(plan: plan)
        if let script { fake.script(script) }
        let model = AppModel(client: fake, now: { clock })
        await model.scan()
        return (model, fake)
    }

    func rig(for scenario: Scenario) async throws -> Rig {
        let board = try boardPlan()
        let safe = board.items.filter { $0.tier == .safe }

        func item(_ path: String) throws -> PlanItem { try XCTUnwrap(board.items.first { $0.path == path }, path) }
        func event(_ path: String, _ status: ItemStatus, reason: String = "") throws -> ApplyEvent {
            let planned = try item(path)
            return .item(ItemEvent(rule: planned.rule, group: planned.group, path: planned.path, status: status, reason: reason,
                                   bytes: planned.bytes, freedBytes: status == .deleted ? planned.bytes : 0,
                                   freesInside: planned.freesInside))
        }
        /// The board's data with Docker's 6.2 GB of unused images ticked: removed, but freed inside Docker's disk image.
        func tickDockerImages(_ model: AppModel) throws {
            model.toggle(try XCTUnwrap(model.selection?.groups.first { $0.section == .review }?.items.first { $0.path == "docker: unused images" }))
        }

        switch scenario {
        case .scanning:
            let fake = FakeCmmClient(plan: board)
            let gate = fake.holdPlans()
            let model = AppModel(client: fake)
            let task = Task { await model.scan() }
            await eventuallyOnMain { model.phase == .scanning }
            return Rig(model: model, window: WindowState(), finish: { gate.open(); await task.value })

        case .rest:
            let (model, _) = await readyModel(try safeOnlyPlan())
            return Rig(model: model, window: WindowState())

        case .restReview:
            let (model, _) = await readyModel(board)
            return Rig(model: model, window: WindowState())

        case .restUnticked:
            let (model, _) = await readyModel(board)
            let lane = try XCTUnwrap(model.selection?.groups.first { $0.rule == "lane-deps" }?.items.first)
            model.toggle(lane)
            model.toggle(try XCTUnwrap(model.selection?.groups.first { $0.rule == "uv-cache" }))
            return Rig(model: model, window: WindowState())

        case .restDockerTicked:
            let (model, _) = await readyModel(board)
            try tickDockerImages(model)
            return Rig(model: model, window: WindowState())

        case .restNoCapacity:
            let plan = TestPlans.plan(safe, skipped: board.skipped, freeBytes: board.host.freeBytes, capacityBytes: nil)
            let (model, _) = await readyModel(plan)
            return Rig(model: model, window: WindowState())

        case .details:
            let (model, _) = await readyModel(board)
            return Rig(model: model, window: WindowState(detailsOpen: true))

        case .detailsExpanded:
            let (model, _) = await readyModel(board)
            let lanes = try XCTUnwrap(model.selection?.groups.first { $0.rule == "lane-deps" })
            return Rig(model: model, window: WindowState(detailsOpen: true, expanded: [lanes.id]))

        case .detailsReviewExpanded:
            let (model, _) = await readyModel(board)
            let docker = try XCTUnwrap(model.selection?.groups.first { $0.section == .review })
            model.toggle(try XCTUnwrap(docker.items.first))
            return Rig(model: model, window: WindowState(detailsOpen: true, expanded: [docker.id]))

        case .sheet:
            let (model, _) = await readyModel(board)
            model.requestClean()
            return Rig(model: model, window: WindowState())

        case .sheetDockerTicked:
            let (model, _) = await readyModel(board)
            try tickDockerImages(model)
            model.requestClean()
            return Rig(model: model, window: WindowState())

        case .cleaning:
            let fake = FakeCmmClient(plan: board)
            fake.script(.live)
            let model = AppModel(client: fake, now: { BoardClock.finished })
            await model.scan()
            model.requestClean()
            let confirmation = try XCTUnwrap(model.confirmation)
            let task = Task { await model.confirmClean(confirmation) }
            _ = await fake.waitForApply()
            fake.send(Events.start(selected: 9, bytes: gb(8.4), free: gb(19.8)))
            for (path, status, reason) in [
                ("/Users/test/lane-builds/lane-a/node_modules", ItemStatus.deleted, ""),
                ("/Users/test/lane-builds/lane-a/ios/Pods", .deleted, ""),
                ("/Users/test/lane-builds/lane-b/node_modules", .deleted, ""),
                ("/Users/test/lane-builds/lane-c/node_modules", .failed, "permission denied"),
                ("/Users/test/.cache/uv", .skipped, "uv is running"),
            ] {
                fake.send(try event(path, status, reason: reason))
            }
            await eventuallyOnMain { model.progress.items.count == 5 }
            return Rig(model: model, window: WindowState(), finish: {
                fake.send(Events.done(deleted: 3, skipped: 1, failed: 1, freed: self.gb(3.1)))
                fake.finish()
                await task.value
            })

        case .cleaningInside:
            // Docker's images are confirmed with the safe items. cmm has gone through go-build, npm, bun, uv (skipped),
            // Homebrew and the images; the lane directories are next.
            let fake = FakeCmmClient(plan: board)
            fake.script(.live)
            let model = AppModel(client: fake, now: { BoardClock.finished })
            await model.scan()
            try tickDockerImages(model)
            model.requestClean()
            let confirmation = try XCTUnwrap(model.confirmation)
            let task = Task { await model.confirmClean(confirmation) }
            _ = await fake.waitForApply()
            fake.send(Events.start(selected: 10, bytes: gb(14.6), free: gb(19.8)))
            for (path, status, reason) in [
                ("/Users/test/Library/Caches/go-build", ItemStatus.deleted, ""),
                ("/Users/test/.npm/_cacache", .deleted, ""),
                ("/Users/test/.bun/install/cache", .deleted, ""),
                ("/Users/test/.cache/uv", .skipped, "uv is running"),
                ("homebrew: cleanup", .deleted, ""),
                ("docker: unused images", .deleted, ""),
            ] {
                fake.send(try event(path, status, reason: reason))
            }
            await eventuallyOnMain { model.progress.items.count == 6 }
            return Rig(model: model, window: WindowState(), finish: {
                fake.send(Events.done(deleted: 5, skipped: 1, freed: self.gb(2.3), freedInside: self.gb(6.2)))
                fake.finish()
                await task.value
            })

        case .doneInside:
            var events: [ApplyEvent] = [Events.start(selected: 10, bytes: gb(14.6), free: gb(19.8))]
            for planned in safe { events.append(try event(planned.path, .deleted)) }
            events.append(try event("docker: unused images", .deleted))
            events.append(Events.done(
                deleted: 10, freed: gb(8.4), freedInside: gb(6.2), before: gb(19.8),
                log: "/Users/test/.local/state/cmm/cleanup.log"
            ))
            let (model, _) = await readyModel(board, script: .replay(events, error: nil))
            try tickDockerImages(model)
            model.requestClean()
            await model.confirmClean(try XCTUnwrap(model.confirmation))
            return Rig(model: model, window: WindowState())

        case .done, .doneProblems, .doneStopped:
            let problems = scenario != .done
            var events: [ApplyEvent] = [Events.start(selected: 9, bytes: gb(8.4), free: gb(19.8))]
            for planned in safe {
                if problems && (planned.path == "/Users/test/.cache/uv" || planned.path == "/Users/test/lane-builds/lane-c/node_modules") { continue }
                events.append(try event(planned.path, .deleted))
            }
            if problems {
                events.append(try event("/Users/test/.cache/uv", .skipped, reason: "uv was running"))
                events.append(try event("/Users/test/lane-builds/lane-c/node_modules", .failed, reason: "permission denied"))
            }
            let stopped = scenario == .doneStopped
            events.append(Events.done(
                deleted: problems ? 7 : 9, skipped: problems ? 1 : 0, failed: problems ? 1 : 0,
                freed: problems ? gb(5.4) : gb(8.4), before: gb(19.8), stopped: stopped,
                log: "/Users/test/.local/state/cmm/cleanup.log"
            ))
            let (model, _) = await readyModel(board, script: .replay(events, error: nil))
            model.requestClean()
            await model.confirmClean(try XCTUnwrap(model.confirmation))
            return Rig(model: model, window: WindowState())

        case .empty:
            let json = #"""
            {"schema_version":1,"generated_at":"2026-10-15T15:29:40+02:00",
             "host":{"volume":"/System/Volumes/Data","free_bytes":28200000000,"capacity_bytes":228000000000},
             "items":[],"skipped":[{"rule":"uv-cache","reason":"uv cache (Python packages; downloads again on demand): uv is running"}],
             "total_bytes":0}
            """#
            let (model, _) = await readyModel(try Plan.parse(Data(json.utf8)))
            return Rig(model: model, window: WindowState())

        case .errorScan, .errorMissing:
            let error: CmmError = scenario == .errorMissing
                ? .binaryNotFound(path: "/Applications/Cmm.app/Contents/Resources/cmm")
                : .planFailed(status: 2, stderr: "cmm: cannot read the free space of /System/Volumes/Data")
            let model = AppModel(client: FakeCmmClient(plans: [.failure(error)]))
            await model.scan()
            return Rig(model: model, window: WindowState())

        case .errorClean:
            let events: [ApplyEvent] = [
                Events.start(selected: 9, free: gb(19.8)),
                try event("/Users/test/lane-builds/lane-a/node_modules", .deleted),
                try event("/Users/test/.cache/uv", .skipped, reason: "uv is running"),
            ]
            let (model, _) = await readyModel(board, script: .replay(events, error: .applyFailed(status: 1, stderr: "cmm: the volume went away")))
            model.requestClean()
            await model.confirmClean(try XCTUnwrap(model.confirmation))
            return Rig(model: model, window: WindowState())
        }
    }

    // MARK: tests

    func testEveryScreenDrawsInLightAndDarkAndFollowsTheAppearance() async throws {
        for scenario in Scenario.allCases {
            let rig = try await rig(for: scenario)
            let view = RootView(model: rig.model, window: rig.window, env: Self.env)

            let light = try render(view, name: scenario.rawValue, appearance: .aqua)
            let dark = try render(view, name: scenario.rawValue, appearance: .darkAqua)
            await rig.finish()

            XCTAssertGreaterThan(distinctColors(light), 8, "\(scenario) looks blank in light mode")
            XCTAssertGreaterThan(distinctColors(dark), 8, "\(scenario) looks blank in dark mode")
            XCTAssertGreaterThan(brightness(light), 0.6, "\(scenario) is not light in light mode")
            XCTAssertLessThan(brightness(dark), 0.4, "\(scenario) is not dark in dark mode")
        }
    }

    func testIncreaseContrastDrawsToo() async throws {
        for scenario in [Scenario.restReview, .detailsExpanded] {
            let rig = try await rig(for: scenario)
            let view = RootView(model: rig.model, window: rig.window, env: Self.env)
            let light = try render(view, name: scenario.rawValue, appearance: .aqua, increasedContrast: true)
            let dark = try render(view, name: scenario.rawValue, appearance: .darkAqua, increasedContrast: true)
            let plainLight = try render(view, name: scenario.rawValue, appearance: .aqua, save: false)
            XCTAssertGreaterThan(distinctColors(light), 8, "\(scenario)")
            XCTAssertGreaterThan(distinctColors(dark), 8, "\(scenario)")
            XCTAssertGreaterThan(brightness(light), 0.6, "\(scenario)")
            XCTAssertLessThan(brightness(dark), 0.4, "\(scenario)")
            // The strong variants are really drawn: the quiet ink is darker with Increase Contrast on.
            XCTAssertLessThan(darkest(light, in: CGRect(x: 100, y: 600, width: 100, height: 30)),
                              darkest(plainLight, in: CGRect(x: 100, y: 600, width: 100, height: 30)), "\(scenario)")
        }
    }

    func testTheModelReachedEachScenarioItClaims() async throws {
        let expected: [Scenario: AppModel.Phase] = [
            .scanning: .scanning, .rest: .ready, .restReview: .ready, .restUnticked: .ready, .restNoCapacity: .ready,
            .details: .ready, .detailsExpanded: .ready, .detailsReviewExpanded: .ready, .sheet: .ready,
            .restDockerTicked: .ready, .sheetDockerTicked: .ready, .cleaningInside: .cleaning, .doneInside: .done,
            .cleaning: .cleaning, .done: .done, .doneProblems: .done, .doneStopped: .done, .empty: .empty,
            .errorScan: .failed, .errorClean: .failed, .errorMissing: .failed,
        ]
        for scenario in Scenario.allCases {
            let rig = try await rig(for: scenario)
            XCTAssertEqual(rig.model.phase, expected[scenario], "\(scenario)")
            if scenario == .sheet || scenario == .sheetDockerTicked { XCTAssertNotNil(rig.model.confirmation) }
            await rig.finish()
        }
    }

    func testTheWindowStillDrawsWithAHundredGroupsOfTwentyItems() async throws {
        // A big plan must not break the layout or take forever (the list is lazy).
        var items: [PlanItem] = []
        for g in 0..<100 {
            for i in 0..<20 {
                items.append(TestPlans.item(
                    "/Users/test/projects/p\(g)/node_modules/pkg\(i)", group: "Project \(g) dependencies",
                    rule: "lane-deps", bytes: Int64(1_000_000 * (g + 1) + i), note: i == 0 ? "untouched for 9+ days" : nil
                ))
            }
        }
        let plan = TestPlans.plan(items, freeBytes: gb(19.8), capacityBytes: gb(228))
        let model = AppModel(client: FakeCmmClient(plan: plan))
        await model.scan()
        let open = Set(model.selection?.groups.prefix(1).map(\.id) ?? [])
        let start = Date()
        let bitmap = try render(
            RootView(model: model, window: WindowState(detailsOpen: true, expanded: open), env: Self.env),
            name: "big-plan", appearance: .aqua
        )
        XCTAssertGreaterThan(distinctColors(bitmap), 8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(model.selection?.selectedCount, 2000)
    }

    func testTheWindowDrawsAtItsSmallestSize() async throws {
        let rig = try await rig(for: .detailsExpanded)
        let size = CGSize(width: HeroLayout.minimumWidth, height: HeroLayout.minimumHeight)
        let bitmap = try render(RootView(model: rig.model, window: rig.window, env: Self.env), name: "details-smallest", appearance: .aqua, size: size)
        XCTAssertGreaterThan(distinctColors(bitmap), 8)
    }
}
