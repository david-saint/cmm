import CoreServices
import XCTest
@testable import CmmKit

/// The lifecycle rules (spec R12, the owner's fifth decision): the Dock icon, quitting when the last window closes, the window
/// of a login launch, what closing the main window asks of what is on it, and when a screen is in someone's use.
final class LifecyclePolicyTests: XCTestCase {
    private let windowSets: [Set<AppWindow>] = [[], [.main], [.settings], [.main, .settings]]
    private let phases: [AppModel.Phase] = [.idle, .scanning, .ready, .empty, .cleaning, .done, .failed]

    // MARK: the Dock

    func testWithTheMenuBarItemOffCmmIsAnOrdinaryAppWhateverIsOpen() {
        for windows in windowSets {
            XCTAssertEqual(LifecyclePolicy.activationPolicy(menuBarEnabled: false, openWindows: windows), .regular, "\(windows)")
        }
    }

    func testWithTheMenuBarItemOnTheDockIconIsThereWhileAWindowOfCmmIsOpen() {
        XCTAssertEqual(LifecyclePolicy.activationPolicy(menuBarEnabled: true, openWindows: []), .accessory)
        for windows in windowSets where !windows.isEmpty {
            XCTAssertEqual(LifecyclePolicy.activationPolicy(menuBarEnabled: true, openWindows: windows), .regular, "\(windows)")
        }
    }

    // MARK: quitting

    func testClosingTheLastWindowQuitsOnlyWithoutTheMenuBarItem() {
        XCTAssertTrue(LifecyclePolicy.terminatesAfterLastWindowClosed(menuBarEnabled: false))
        XCTAssertFalse(LifecyclePolicy.terminatesAfterLastWindowClosed(menuBarEnabled: true))
    }

    // MARK: launching

    func testOnlyALoginLaunchWithTheMenuBarItemOnOpensNoWindow() {
        XCTAssertTrue(LifecyclePolicy.opensWindowAtLaunch(menuBarEnabled: false, launchedAtLogin: false))
        XCTAssertTrue(LifecyclePolicy.opensWindowAtLaunch(menuBarEnabled: false, launchedAtLogin: true), "without the item there is nothing else to see")
        XCTAssertTrue(LifecyclePolicy.opensWindowAtLaunch(menuBarEnabled: true, launchedAtLogin: false))
        XCTAssertFalse(LifecyclePolicy.opensWindowAtLaunch(menuBarEnabled: true, launchedAtLogin: true))
    }

    func testTheLaunchEventsCodesAreTheSystemsOwn() {
        XCTAssertEqual(LaunchEvent.coreEventClass, UInt32(kCoreEventClass))
        XCTAssertEqual(LaunchEvent.openApplication, UInt32(kAEOpenApplication))
        XCTAssertEqual(LaunchEvent.propertyData, UInt32(keyAEPropData))
        XCTAssertEqual(LaunchEvent.launchedAsLogInItem, UInt32(keyAELaunchedAsLogInItem))
    }

    func testOnlyAnOpenApplicationEventThatSaysLoginItemIsALoginLaunch() {
        let login = LaunchEvent(eventClass: UInt32(kCoreEventClass), eventID: UInt32(kAEOpenApplication), propertyData: UInt32(keyAELaunchedAsLogInItem))
        XCTAssertTrue(login.isLoginLaunch)
        XCTAssertFalse(LaunchEvent(eventClass: UInt32(kCoreEventClass), eventID: UInt32(kAEOpenApplication), propertyData: nil).isLoginLaunch, "a double click")
        XCTAssertFalse(LaunchEvent(eventClass: UInt32(kCoreEventClass), eventID: UInt32(kAEReopenApplication), propertyData: UInt32(keyAELaunchedAsLogInItem)).isLoginLaunch)
        XCTAssertFalse(LaunchEvent(eventClass: UInt32(kCoreEventClass), eventID: UInt32(kAEOpenApplication), propertyData: UInt32(keyAELaunchedAsServiceItem)).isLoginLaunch)
        XCTAssertFalse(LaunchEvent(eventClass: LaunchEvent.fourCharacterCode("misc"), eventID: UInt32(kAEOpenApplication), propertyData: UInt32(keyAELaunchedAsLogInItem)).isLoginLaunch)
    }

    // MARK: closing the main window

    func testClosingTheMainWindowStopsACleaningAndCancelsTheCardAndLeavesEverythingElse() {
        for phase in phases {
            for card in [false, true] {
                let steps = LifecyclePolicy.stepsWhenMainWindowCloses(phase: phase, confirmationOpen: card)
                var expected: [LifecyclePolicy.ClosingStep] = []
                if phase == .cleaning { expected.append(.stopCleaning) }
                if card { expected.append(.cancelConfirmation) }
                XCTAssertEqual(steps, expected, "\(phase), card \(card)")
            }
        }
        XCTAssertEqual(LifecyclePolicy.stepsWhenMainWindowCloses(phase: .scanning, confirmationOpen: false), [], "a scan only looks: it finishes")
    }

    // MARK: a screen in use

    func testTheCardAndTheCleaningAreAlwaysInUseAndTheResultScreensWhileTheWindowIsOpen() {
        for phase in phases {
            for card in [false, true] {
                for open in [false, true] {
                    let inUse = LifecyclePolicy.screenInUse(phase: phase, confirmationOpen: card, mainWindowOpen: open)
                    let expected = card || phase == .cleaning || (open && (phase == .done || phase == .failed))
                    XCTAssertEqual(inUse, expected, "\(phase), card \(card), window open \(open)")
                }
            }
        }
        XCTAssertFalse(LifecyclePolicy.screenInUse(phase: .ready, confirmationOpen: false, mainWindowOpen: true), "the rest screen can be scanned again")
        XCTAssertTrue(LifecyclePolicy.screenInUse(phase: .done, confirmationOpen: false, mainWindowOpen: true))
        XCTAssertFalse(LifecyclePolicy.screenInUse(phase: .done, confirmationOpen: false, mainWindowOpen: false), "a closed window's done screen was left behind")
    }
}

/// The lifecycle as it happens, with a recorder in place of the system.
@MainActor
final class LifecycleTests: XCTestCase {
    @MainActor
    private final class Rig {
        var menuBar: Bool
        var policies: [ActivationPolicy] = []
        var lifecycle: Lifecycle!

        init(menuBar: Bool) {
            self.menuBar = menuBar
            lifecycle = Lifecycle(menuBarEnabled: { [unowned self] in self.menuBar }, setPolicy: { [unowned self] in self.policies.append($0) })
        }
    }

    private let login = LaunchEvent(eventClass: LaunchEvent.coreEventClass, eventID: LaunchEvent.openApplication, propertyData: LaunchEvent.launchedAsLogInItem)
    private let doubleClick = LaunchEvent(eventClass: LaunchEvent.coreEventClass, eventID: LaunchEvent.openApplication, propertyData: nil)

    func testWithoutTheMenuBarItemItIsAlwaysAnOrdinaryAppAndClosingTheWindowQuits() async {
        let rig = Rig(menuBar: false)
        XCTAssertTrue(rig.lifecycle.launched(by: doubleClick))
        rig.lifecycle.windowOpened(.main)
        let stays = await rig.lifecycle.mainWindowShouldStay()
        XCTAssertTrue(stays)
        rig.lifecycle.windowClosed(.main)
        XCTAssertEqual(rig.policies, [.regular], "told once, and never anything else")
        XCTAssertTrue(rig.lifecycle.terminatesAfterLastWindowClosed)
    }

    func testWithTheMenuBarItemTheDockIconFollowsTheWindows() {
        let rig = Rig(menuBar: true)
        rig.lifecycle.launched(by: doubleClick)
        XCTAssertEqual(rig.policies, [.regular], "the window that opens with the app counts at once: no blink")
        rig.lifecycle.windowOpened(.main)
        rig.lifecycle.windowOpened(.settings)
        rig.lifecycle.windowClosed(.main)
        XCTAssertEqual(rig.policies.last, .regular, "the Settings window is still open")
        rig.lifecycle.windowClosed(.settings)
        XCTAssertEqual(rig.policies.last, .accessory, "only the menu bar item is left")
        rig.lifecycle.windowOpened(.settings)
        XCTAssertEqual(rig.policies.last, .regular)
        XCTAssertFalse(rig.lifecycle.terminatesAfterLastWindowClosed)
        XCTAssertEqual(rig.policies, [.regular, .accessory, .regular], "the system is told only of changes")
    }

    func testSwitchingTheItemOffBringsTheDockIconBackAndClosingTheLastWindowQuitsAgain() {
        let rig = Rig(menuBar: true)
        rig.lifecycle.launched(by: doubleClick)
        rig.lifecycle.windowOpened(.settings)
        rig.menuBar = false
        rig.lifecycle.menuBarChanged()
        rig.lifecycle.windowClosed(.settings)
        XCTAssertEqual(rig.policies.last, .regular)
        XCTAssertTrue(rig.lifecycle.terminatesAfterLastWindowClosed, "the switch is read when the window closes, not at launch")
    }

    func testALoginLaunchWithTheItemOnClosesTheWindowItOpenedWithAndNeverShowsTheDockIcon() async {
        let rig = Rig(menuBar: true)
        XCTAssertFalse(rig.lifecycle.launched(by: login))
        XCTAssertEqual(rig.policies, [.accessory])
        rig.lifecycle.windowOpened(.main)  // the window SwiftUI opened with the app came forward
        XCTAssertEqual(rig.policies, [.accessory], "the window on its way out does not bring the Dock icon back")
        let first = await rig.lifecycle.mainWindowShouldStay()
        XCTAssertFalse(first)
        let again = await rig.lifecycle.mainWindowShouldStay()
        XCTAssertTrue(again, "it is told no once")
        rig.lifecycle.windowClosed(.main)
        XCTAssertEqual(rig.policies, [.accessory])

        // the person opens it from the menu bar item
        rig.lifecycle.openingMainWindow()
        XCTAssertEqual(rig.policies.last, .regular)
        let opened = await rig.lifecycle.mainWindowShouldStay()
        XCTAssertTrue(opened)
    }

    func testAWindowThePersonOpensIsNeverRefusedEvenIfTheLaunchWindowNeverAppeared() async {
        let rig = Rig(menuBar: true)
        rig.lifecycle.launched(by: login)
        rig.lifecycle.openingMainWindow()
        let stays = await rig.lifecycle.mainWindowShouldStay()
        XCTAssertTrue(stays)
        XCTAssertEqual(rig.policies, [.accessory, .regular])
    }

    func testALoginLaunchWithoutTheItemOpensTheWindowAsAlways() async {
        let rig = Rig(menuBar: false)
        XCTAssertTrue(rig.lifecycle.launched(by: login))
        let stays = await rig.lifecycle.mainWindowShouldStay()
        XCTAssertTrue(stays)
        XCTAssertEqual(rig.policies, [.regular])
    }

    func testAWindowThatAsksBeforeTheLaunchIsKnownWaitsForIt() async {
        let rig = Rig(menuBar: true)
        let answer = Task { @MainActor in await rig.lifecycle.mainWindowShouldStay(limit: 30) }
        try? await Task.sleep(for: .milliseconds(50))
        rig.lifecycle.launched(by: login)
        let stays = await answer.value
        XCTAssertFalse(stays)
    }

    func testALaunchThatIsNeverAnnouncedIsTakenToBeAnOrdinaryOne() async {
        let rig = Rig(menuBar: true)
        let started = Date()
        let stays = await rig.lifecycle.mainWindowShouldStay(limit: 0.1)
        XCTAssertTrue(stays)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(rig.lifecycle.launched(by: login), "the launch was already decided, as an ordinary one")
    }

    func testOnlyTheFirstAnnouncementOfTheLaunchDecides() {
        let rig = Rig(menuBar: true)
        XCTAssertTrue(rig.lifecycle.launched(by: doubleClick))
        XCTAssertTrue(rig.lifecycle.launched(by: login))
        XCTAssertEqual(rig.policies, [.regular])
    }
}
