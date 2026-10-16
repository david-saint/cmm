import Observation
import XCTest
@testable import CmmKit

/// Preferences in a dictionary in memory, with a note of every write: no test touches the real ones.
final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
    private struct Contents {
        var values: [String: Any] = [:]
        var writes: [String] = []
    }

    private let box = Locked(Contents())

    init(_ values: [SettingsKey: Any] = [:]) {
        box.withLock { contents in
            for (key, value) in values { contents.values[key.rawValue] = value }
        }
    }

    func value(for key: SettingsKey) -> Any? {
        box.withLock { $0.values[key.rawValue] }
    }

    func set(_ value: Any?, for key: SettingsKey) {
        box.withLock {
            $0.writes.append(key.rawValue)
            $0.values[key.rawValue] = value
        }
    }

    /// The keys that hold something, sorted.
    var keys: [String] { box.withLock { $0.values.keys.sorted() } }
    /// Every key written, in order, one entry per write.
    var writes: [String] { box.withLock { $0.writes } }
}

/// The system's login item, by hand.
final class FakeLoginItem: LoginItem, @unchecked Sendable {
    struct Refused: Error {}

    private struct Contents {
        var system = LoginItemState.off
        var calls: [Bool] = []
        var refuses = false
        var needsApproval = false
    }

    private let box = Locked(Contents())

    init(_ initial: LoginItemState = .off) {
        box.withLock { $0.system = initial }
    }

    /// What the system says now (a test changes it to play the person turning it off in System Settings).
    var state: LoginItemState {
        get { box.withLock { $0.system } }
        set { box.withLock { $0.system = newValue } }
    }

    /// Every `setEnabled` call, in order.
    var calls: [Bool] { box.withLock { $0.calls } }

    var refuses: Bool {
        get { box.withLock { $0.refuses } }
        set { box.withLock { $0.refuses = newValue } }
    }

    /// Registering works, but the person has to allow it in System Settings.
    var needsApproval: Bool {
        get { box.withLock { $0.needsApproval } }
        set { box.withLock { $0.needsApproval = newValue } }
    }

    func setEnabled(_ enabled: Bool) throws {
        try box.withLock { contents in
            contents.calls.append(enabled)
            if contents.refuses { throw Refused() }
            contents.system = enabled ? (contents.needsApproval ? .needsApproval : .on) : .off
        }
    }
}

/// The system's question about notifications, by hand.
final class FakeNotificationPermission: NotificationPermission, @unchecked Sendable {
    private struct Contents {
        var current: NotificationAuthorization
        var answer: NotificationAuthorization
        var statusCalls = 0
        var requestCalls = 0
        var gate: FakeCmmClient.Gate?
    }

    private let box: Locked<Contents>

    /// `current` is what the system says now; `answer` is what the person picks if it asks.
    init(_ current: NotificationAuthorization = .notAsked, personAnswers answer: NotificationAuthorization = .allowed) {
        box = Locked(Contents(current: current, answer: answer))
    }

    var current: NotificationAuthorization {
        get { box.withLock { $0.current } }
        set { box.withLock { $0.current = newValue } }
    }

    var statusCalls: Int { box.withLock { $0.statusCalls } }
    var requestCalls: Int { box.withLock { $0.requestCalls } }

    /// Holds the question open (macOS's sheet is on the screen) until the test opens the gate.
    func holdTheQuestion() -> FakeCmmClient.Gate {
        let gate = FakeCmmClient.Gate()
        box.withLock { $0.gate = gate }
        return gate
    }

    func status() async -> NotificationAuthorization {
        box.withLock {
            $0.statusCalls += 1
            return $0.current
        }
    }

    func request() async -> NotificationAuthorization {
        let gate = box.withLock { contents -> FakeCmmClient.Gate? in
            contents.requestCalls += 1
            return contents.gate
        }
        await gate?.wait()
        return box.withLock {
            if $0.current == .notAsked { $0.current = $0.answer }
            return $0.current
        }
    }
}

/// The preferences, typed (spec R9): what is kept, under which keys, and what a damaged value reads as.
final class SettingsTests: XCTestCase {
    private func settings(_ values: [SettingsKey: Any] = [:]) -> (Settings, MemorySettingsStore) {
        let store = MemorySettingsStore(values)
        return (Settings(store: store), store)
    }

    // MARK: the keys

    func testTheAppKeepsExactlyTheseKeysAndNothingElse() {
        XCTAssertEqual(
            SettingsKey.allCases.map(\.rawValue),
            ["detailsFace", "menuBarEnabled", "weeklyReminderEnabled", "historyEnabled", "optInAnswered", "lastWeeklyDate",
             "weeklyWeekday", "weeklyMinuteOfDay"]
        )
    }

    // MARK: what nothing kept reads as

    func testWithNothingKeptEveryBehaviourIsOffAndTheWindowIsAsItWas() {
        let (settings, store) = settings()
        XCTAssertEqual(settings.detailsFace, .map, "the face the window opens on today")
        XCTAssertFalse(settings.menuBarEnabled)
        XCTAssertFalse(settings.weeklyReminderEnabled)
        XCTAssertFalse(settings.historyEnabled)
        XCTAssertFalse(settings.optInAnswered, "the card has not been answered")
        XCTAssertNil(settings.lastWeeklyDate)
        XCTAssertEqual(settings.weeklySchedule, .standard, "Monday at 10:00")
        XCTAssertTrue(store.writes.isEmpty, "reading keeps nothing")
        XCTAssertTrue(store.keys.isEmpty)
    }

    // MARK: what is chosen is read back

    func testEverythingChosenIsReadBackByANewSettingsOverTheSameStore() {
        let (settings, store) = settings()
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        settings.detailsFace = .list
        settings.menuBarEnabled = true
        settings.weeklyReminderEnabled = true
        settings.historyEnabled = true
        settings.optInAnswered = true
        settings.lastWeeklyDate = when
        settings.weeklySchedule = WeeklySchedule(weekday: 4, hour: 7, minute: 45)

        let again = Settings(store: store)
        XCTAssertEqual(again.detailsFace, .list)
        XCTAssertTrue(again.menuBarEnabled)
        XCTAssertTrue(again.weeklyReminderEnabled)
        XCTAssertTrue(again.historyEnabled)
        XCTAssertTrue(again.optInAnswered)
        XCTAssertEqual(again.lastWeeklyDate, when)
        XCTAssertEqual(again.weeklySchedule, WeeklySchedule(weekday: 4, hour: 7, minute: 45))
        XCTAssertEqual(store.keys, SettingsKey.allCases.map(\.rawValue).sorted(), "all eight keys, and no other")
    }

    func testEachChoiceWritesItsOwnKeyAndOnlyThat() {
        let cases: [(String, (Settings) -> Void, [String])] = [
            ("face", { $0.detailsFace = .list }, ["detailsFace"]),
            ("menu bar", { $0.menuBarEnabled = true }, ["menuBarEnabled"]),
            ("reminder", { $0.weeklyReminderEnabled = true }, ["weeklyReminderEnabled"]),
            ("history", { $0.historyEnabled = true }, ["historyEnabled"]),
            ("card", { $0.optInAnswered = true }, ["optInAnswered"]),
            ("last check", { $0.lastWeeklyDate = Date(timeIntervalSince1970: 5) }, ["lastWeeklyDate"]),
            ("schedule", { $0.weeklySchedule = WeeklySchedule(weekday: 3, hour: 8, minute: 15) }, ["weeklyWeekday", "weeklyMinuteOfDay"]),
        ]
        for (name, change, keys) in cases {
            let (settings, store) = settings()
            change(settings)
            XCTAssertEqual(store.writes, keys, name)
        }
    }

    func testTheFaceIsKeptAsItsWordAndTheOthersAsPlainValues() throws {
        let (settings, store) = settings()
        settings.detailsFace = .list
        settings.menuBarEnabled = true
        settings.lastWeeklyDate = Date(timeIntervalSince1970: 1_760_000_000)
        settings.weeklySchedule = WeeklySchedule(weekday: 4, hour: 7, minute: 45)
        XCTAssertEqual(store.value(for: .detailsFace) as? String, "list")
        XCTAssertEqual(store.value(for: .menuBarEnabled) as? Bool, true)
        XCTAssertEqual(store.value(for: .lastWeeklyDate) as? Date, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(store.value(for: .weeklyWeekday) as? Int, 4)
        XCTAssertEqual(store.value(for: .weeklyMinuteOfDay) as? Int, 7 * 60 + 45)
    }

    func testAClearedLastCheckRemovesItsKey() {
        let (settings, store) = settings([.lastWeeklyDate: Date(timeIntervalSince1970: 5)])
        settings.lastWeeklyDate = nil
        XCTAssertNil(settings.lastWeeklyDate)
        XCTAssertEqual(store.keys, [])
    }

    func testTheFaceThatWasKeptBeforeThisUpdateIsStillRead() {
        // the key and the words are the ones the app has always used
        XCTAssertEqual(settings([.detailsFace: "list"]).0.detailsFace, .list)
        XCTAssertEqual(settings([.detailsFace: "map"]).0.detailsFace, .map)
    }

    // MARK: damaged preferences

    func testAValueOfTheWrongKindReadsAsTheDefault() {
        let (settings, _) = settings([
            .detailsFace: 7, .menuBarEnabled: "yes", .weeklyReminderEnabled: ["a"], .historyEnabled: Date(timeIntervalSince1970: 0),
            .optInAnswered: "true", .lastWeeklyDate: "yesterday", .weeklyWeekday: "Monday", .weeklyMinuteOfDay: 9.5 as Double,
        ])
        XCTAssertEqual(settings.detailsFace, .map)
        XCTAssertFalse(settings.menuBarEnabled)
        XCTAssertFalse(settings.weeklyReminderEnabled)
        XCTAssertFalse(settings.historyEnabled)
        XCTAssertFalse(settings.optInAnswered)
        XCTAssertNil(settings.lastWeeklyDate)
        XCTAssertEqual(settings.weeklySchedule.weekday, 2, "Monday")
    }

    func testAFaceThatIsNotOneOfOursReadsAsTheMap() {
        XCTAssertEqual(settings([.detailsFace: "grid"]).0.detailsFace, .map)
        XCTAssertEqual(settings([.detailsFace: ""]).0.detailsFace, .map)
    }

    func testAScheduleOutOfRangeReadsAsTheNearestThatCanBe() {
        XCTAssertEqual(settings([.weeklyWeekday: 0, .weeklyMinuteOfDay: -5]).0.weeklySchedule, WeeklySchedule(weekday: 1, hour: 0, minute: 0))
        XCTAssertEqual(settings([.weeklyWeekday: 99, .weeklyMinuteOfDay: 99_999]).0.weeklySchedule, WeeklySchedule(weekday: 7, hour: 23, minute: 59))
        XCTAssertEqual(settings([.weeklyWeekday: Int.max, .weeklyMinuteOfDay: Int.min]).0.weeklySchedule, WeeklySchedule(weekday: 7, hour: 0, minute: 0))
    }

    func testTheEdgesOfTheDay() {
        XCTAssertEqual(settings([.weeklyMinuteOfDay: 0]).0.weeklySchedule, WeeklySchedule(weekday: 2, hour: 0, minute: 0))
        XCTAssertEqual(settings([.weeklyMinuteOfDay: 1_439]).0.weeklySchedule, WeeklySchedule(weekday: 2, hour: 23, minute: 59))
        XCTAssertEqual(settings([.weeklyMinuteOfDay: 1_440]).0.weeklySchedule, WeeklySchedule(weekday: 2, hour: 23, minute: 59), "there is no 24:00")
        XCTAssertEqual(settings([.weeklyMinuteOfDay: 600]).0.weeklySchedule, .standard, "10:00 is 600 minutes")
    }

    func testOneDamagedHalfOfTheScheduleDoesNotTakeTheOtherHalfWithIt() {
        let (damagedDay, _) = settings([.weeklyWeekday: "x", .weeklyMinuteOfDay: 9 * 60 + 30])
        XCTAssertEqual(damagedDay.weeklySchedule, WeeklySchedule(weekday: 2, hour: 9, minute: 30))
        let (damagedTime, _) = settings([.weeklyWeekday: 5, .weeklyMinuteOfDay: "x"])
        XCTAssertEqual(damagedTime.weeklySchedule, WeeklySchedule(weekday: 5, hour: 10, minute: 0))
    }
}

/// The preferences as the Settings window and the one-time card use them (spec R8 and R9).
@MainActor
final class SettingsModelTests: XCTestCase {
    private struct Rig {
        let model: SettingsModel
        let store: MemorySettingsStore
        let login: FakeLoginItem
        let permission: FakeNotificationPermission
    }

    private func rig(
        _ values: [SettingsKey: Any] = [:], login: LoginItemState = .off,
        permission: NotificationAuthorization = .notAsked, personAnswers: NotificationAuthorization = .allowed
    ) -> Rig {
        let store = MemorySettingsStore(values)
        let loginItem = FakeLoginItem(login)
        let fake = FakeNotificationPermission(permission, personAnswers: personAnswers)
        return Rig(
            model: SettingsModel(settings: Settings(store: store), loginItem: loginItem, notifications: fake),
            store: store, login: loginItem, permission: fake
        )
    }

    // MARK: starting

    func testItStartsFromWhatIsKeptAndKeepsNothingAtStart() {
        let rig = rig([.menuBarEnabled: true, .detailsFace: "list", .weeklyWeekday: 6, .weeklyMinuteOfDay: 8 * 60])
        XCTAssertTrue(rig.model.menuBarEnabled)
        XCTAssertFalse(rig.model.weeklyReminderEnabled)
        XCTAssertEqual(rig.model.detailsFace, .list)
        XCTAssertEqual(rig.model.weeklySchedule, WeeklySchedule(weekday: 6, hour: 8, minute: 0))
        XCTAssertTrue(rig.store.writes.isEmpty, "starting writes nothing")
    }

    func testStartingAsksMacOSNothingAndTheLoginItemNothing() {
        let rig = rig()
        XCTAssertEqual(rig.permission.requestCalls, 0)
        XCTAssertEqual(rig.permission.statusCalls, 0)
        XCTAssertTrue(rig.login.calls.isEmpty)
    }

    func testWithNothingKeptEverythingIsOffAndTheCardIsWaiting() {
        let model = rig().model
        XCTAssertFalse(model.menuBarEnabled)
        XCTAssertFalse(model.weeklyReminderEnabled)
        XCTAssertFalse(model.historyEnabled)
        XCTAssertFalse(model.optInAnswered)
        XCTAssertEqual(model.openAtLogin, .off)
        XCTAssertEqual(model.notifications, .notAsked)
        XCTAssertFalse(model.reminderIsSilenced)
    }

    // MARK: choices are kept as they are made

    func testEachChoiceIsKeptTheMomentItIsMade() async {
        let rig = rig()
        let model = rig.model
        model.menuBarEnabled = true
        XCTAssertEqual(rig.store.writes, ["menuBarEnabled"])
        model.historyEnabled = true
        await model.setWeeklyReminder(true)
        model.declineOptIn()
        model.detailsFace = .list
        model.lastWeeklyDate = Date(timeIntervalSince1970: 1_760_000_000)
        model.weeklySchedule = WeeklySchedule(weekday: 5, hour: 18, minute: 30)
        XCTAssertEqual(
            rig.store.writes,
            ["menuBarEnabled", "historyEnabled", "weeklyReminderEnabled", "optInAnswered", "detailsFace", "lastWeeklyDate",
             "weeklyWeekday", "weeklyMinuteOfDay"]
        )
        let again = Settings(store: rig.store)
        XCTAssertTrue(again.menuBarEnabled)
        XCTAssertTrue(again.historyEnabled)
        XCTAssertTrue(again.weeklyReminderEnabled)
        XCTAssertTrue(again.optInAnswered)
        XCTAssertEqual(again.detailsFace, .list)
        XCTAssertEqual(again.lastWeeklyDate, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(again.weeklySchedule, WeeklySchedule(weekday: 5, hour: 18, minute: 30))
    }

    func testChoosingWhatIsAlreadyChosenKeepsNothingAgain() {
        let rig = rig([.menuBarEnabled: true])
        rig.model.menuBarEnabled = true
        rig.model.historyEnabled = false
        rig.model.detailsFace = .map
        rig.model.weeklySchedule = .standard
        XCTAssertTrue(rig.store.writes.isEmpty)
    }

    func testSwitchingOffKeepsTheOff() {
        let rig = rig([.menuBarEnabled: true])
        rig.model.menuBarEnabled = false
        XCTAssertFalse(Settings(store: rig.store).menuBarEnabled)
        XCTAssertEqual(rig.store.writes, ["menuBarEnabled"])
    }

    func testAClearedLastCheckIsRemovedFromWhatIsKept() {
        let rig = rig([.lastWeeklyDate: Date(timeIntervalSince1970: 5)])
        XCTAssertEqual(rig.model.lastWeeklyDate, Date(timeIntervalSince1970: 5))
        rig.model.lastWeeklyDate = nil
        XCTAssertNil(Settings(store: rig.store).lastWeeklyDate)
        XCTAssertEqual(rig.store.keys, [])
    }

    func testAScheduleOutOfRangeIsKeptAsTheNearestThatCanBe() {
        let rig = rig()
        rig.model.weeklySchedule = WeeklySchedule(weekday: 12, hour: 40, minute: 99)
        XCTAssertEqual(rig.model.weeklySchedule, WeeklySchedule(weekday: 7, hour: 23, minute: 59))
        XCTAssertEqual(Settings(store: rig.store).weeklySchedule, WeeklySchedule(weekday: 7, hour: 23, minute: 59))
    }

    func testAViewIsToldWhenAChoiceChanges() {
        let model = rig().model
        let told = Locked(0)
        withObservationTracking({ _ = model.menuBarEnabled }, onChange: { told.withLock { $0 += 1 } })
        model.historyEnabled = true
        XCTAssertEqual(told.withLock { $0 }, 0, "another choice is not this one")
        model.menuBarEnabled = true
        XCTAssertEqual(told.withLock { $0 }, 1)
    }

    // MARK: the one-time card (R8)

    func testTurnOnTurnsOnTheFourThingsAndAsksMacOSOnce() async {
        let rig = rig()
        await rig.model.turnOnEverything()
        let model = rig.model
        XCTAssertTrue(model.menuBarEnabled)
        XCTAssertTrue(model.weeklyReminderEnabled)
        XCTAssertTrue(model.historyEnabled)
        XCTAssertEqual(model.openAtLogin, .on)
        XCTAssertTrue(model.optInAnswered, "the card is not shown again")
        XCTAssertEqual(rig.login.calls, [true])
        XCTAssertEqual(rig.permission.requestCalls, 1)
        XCTAssertEqual(model.notifications, .allowed)
        let kept = Settings(store: rig.store)
        XCTAssertTrue(kept.menuBarEnabled && kept.weeklyReminderEnabled && kept.historyEnabled && kept.optInAnswered)
        XCTAssertEqual(rig.store.keys, ["historyEnabled", "menuBarEnabled", "optInAnswered", "weeklyReminderEnabled"], "Open at login is not kept")
    }

    func testNotNowTurnsNothingOnAndAsksNothing() async {
        let rig = rig()
        rig.model.declineOptIn()
        XCTAssertTrue(rig.model.optInAnswered, "and the card is not shown again")
        XCTAssertFalse(rig.model.menuBarEnabled)
        XCTAssertFalse(rig.model.weeklyReminderEnabled)
        XCTAssertFalse(rig.model.historyEnabled)
        XCTAssertEqual(rig.model.openAtLogin, .off)
        XCTAssertTrue(rig.login.calls.isEmpty)
        XCTAssertEqual(rig.permission.requestCalls, 0)
        XCTAssertEqual(rig.permission.statusCalls, 0)
        XCTAssertEqual(rig.store.writes, ["optInAnswered"])
    }

    func testTheCardIsAnsweredAndTheRestIsOnEvenWhenTheSystemRefusesTheLoginItem() async {
        let rig = rig()
        rig.login.refuses = true
        await rig.model.turnOnEverything()
        XCTAssertTrue(rig.model.optInAnswered)
        XCTAssertTrue(rig.model.menuBarEnabled)
        XCTAssertTrue(rig.model.weeklyReminderEnabled)
        XCTAssertTrue(rig.model.historyEnabled)
        XCTAssertEqual(rig.model.openAtLogin, .off, "what the system says")
        XCTAssertTrue(rig.model.openAtLoginFailed)
        XCTAssertEqual(rig.permission.requestCalls, 1, "and macOS is still asked")
    }

    func testTheCardIsAnsweredWhileMacOSsQuestionIsStillOnTheScreen() async {
        let rig = rig()
        let question = rig.permission.holdTheQuestion()
        let model = rig.model
        let turningOn = Task { await model.turnOnEverything() }
        await eventuallyOnMain(timeout: 3) { rig.permission.requestCalls == 1 }
        XCTAssertEqual(rig.permission.requestCalls, 1, "macOS is being asked")
        XCTAssertTrue(model.optInAnswered, "the card is answered and gone before the person has answered macOS")
        XCTAssertTrue(model.menuBarEnabled)
        XCTAssertTrue(model.weeklyReminderEnabled)
        XCTAssertTrue(model.historyEnabled)
        XCTAssertEqual(model.openAtLogin, .on)
        XCTAssertEqual(rig.store.writes.first, "optInAnswered", "the answer is kept first")
        question.open()
        await turningOn.value
        XCTAssertEqual(model.notifications, .allowed)
    }

    func testAnApprovalTheSystemStillWantsIsShownAsThat() async {
        let rig = rig()
        rig.login.needsApproval = true
        await rig.model.turnOnEverything()
        XCTAssertEqual(rig.model.openAtLogin, .needsApproval)
        XCTAssertFalse(rig.model.openAtLoginFailed)
    }

    // MARK: Open at login is the system's

    func testOpenAtLoginIsReadFromTheSystemAtStart() {
        XCTAssertEqual(rig(login: .on).model.openAtLogin, .on)
        XCTAssertEqual(rig(login: .needsApproval).model.openAtLogin, .needsApproval)
    }

    func testTheSwitchAsksTheSystemAndShowsWhatTheSystemSaysAndKeepsNothing() {
        let rig = rig()
        rig.model.setOpenAtLogin(true)
        XCTAssertEqual(rig.login.calls, [true])
        XCTAssertEqual(rig.model.openAtLogin, .on)
        rig.model.setOpenAtLogin(false)
        XCTAssertEqual(rig.login.calls, [true, false])
        XCTAssertEqual(rig.model.openAtLogin, .off)
        XCTAssertTrue(rig.store.writes.isEmpty, "the app does not keep it")
    }

    func testARefusalIsShownAsWhatTheSystemSaysAndAsAFailure() {
        let rig = rig()
        rig.login.refuses = true
        rig.model.setOpenAtLogin(true)
        XCTAssertEqual(rig.model.openAtLogin, .off)
        XCTAssertTrue(rig.model.openAtLoginFailed)
        rig.login.refuses = false
        rig.model.setOpenAtLogin(true)
        XCTAssertFalse(rig.model.openAtLoginFailed, "the next try that works clears it")
        XCTAssertEqual(rig.model.openAtLogin, .on)
    }

    func testWhatThePersonDidInSystemSettingsIsPickedUpWhenTheWindowComesForward() async {
        let rig = rig(login: .on, permission: .allowed)
        XCTAssertEqual(rig.model.openAtLogin, .on)
        rig.login.state = .off
        rig.permission.current = .denied
        await rig.model.refresh()
        XCTAssertEqual(rig.model.openAtLogin, .off)
        XCTAssertEqual(rig.model.notifications, .denied)
        XCTAssertEqual(rig.permission.requestCalls, 0, "looking is not asking")
        XCTAssertTrue(rig.store.writes.isEmpty)
        XCTAssertTrue(rig.login.calls.isEmpty)
    }

    // MARK: notifications are asked about when the reminder is turned on, and then only

    func testTurningTheReminderOnAsksMacOSAndTurningItOffDoesNot() async {
        let rig = rig()
        await rig.model.setWeeklyReminder(true)
        XCTAssertTrue(rig.model.weeklyReminderEnabled)
        XCTAssertEqual(rig.permission.requestCalls, 1)
        XCTAssertEqual(rig.model.notifications, .allowed)
        await rig.model.setWeeklyReminder(false)
        XCTAssertFalse(rig.model.weeklyReminderEnabled)
        XCTAssertEqual(rig.permission.requestCalls, 1)
        XCTAssertEqual(rig.store.writes, ["weeklyReminderEnabled", "weeklyReminderEnabled"])
    }

    func testMacOSIsAskedOnlyWhenItHasNotBeenAsked() async {
        let allowed = rig(permission: .allowed)
        await allowed.model.setWeeklyReminder(true)
        XCTAssertEqual(allowed.permission.requestCalls, 0)
        XCTAssertEqual(allowed.model.notifications, .allowed)

        let denied = rig(permission: .denied)
        await denied.model.setWeeklyReminder(true)
        XCTAssertEqual(denied.permission.requestCalls, 0, "no second question after a no")
        XCTAssertEqual(denied.model.notifications, .denied)
    }

    func testNoOtherChoiceAsksMacOSAnything() async {
        let rig = rig()
        rig.model.menuBarEnabled = true
        rig.model.historyEnabled = true
        rig.model.detailsFace = .list
        rig.model.setOpenAtLogin(true)
        rig.model.weeklySchedule = WeeklySchedule(weekday: 3, hour: 9, minute: 0)
        rig.model.declineOptIn()
        await rig.model.refresh()
        XCTAssertEqual(rig.permission.requestCalls, 0)
    }

    func testAPersonWhoSaysNoLeavesTheSwitchOnAndTheReminderSilenced() async {
        let rig = rig(personAnswers: .denied)
        await rig.model.setWeeklyReminder(true)
        XCTAssertTrue(rig.model.weeklyReminderEnabled, "it is their switch")
        XCTAssertEqual(rig.model.notifications, .denied)
        XCTAssertTrue(rig.model.reminderIsSilenced, "so the row can say macOS will not show it")
        await rig.model.setWeeklyReminder(false)
        XCTAssertFalse(rig.model.reminderIsSilenced, "off is off")
    }

    func testTheReminderIsNotSilencedWhileMacOSAllowsIt() async {
        let rig = rig(permission: .allowed)
        await rig.model.setWeeklyReminder(true)
        XCTAssertFalse(rig.model.reminderIsSilenced)
    }
}
