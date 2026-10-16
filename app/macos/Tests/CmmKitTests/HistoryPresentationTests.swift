import XCTest
@testable import CmmKit

/// The History face from one report (spec R1 to R4, and the six states of the board `C-History-States`): the paragraph, the
/// line, the weeks, and what to say when there is nothing yet.
final class HistoryPresentationTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    private let now = TestTime.utc("2026-10-15T09:00:00Z")

    private func present(_ report: HistoryReport, historyEnabled: Bool = true) -> HistoryPresentation {
        HistoryPresentation(report: report, historyEnabled: historyEnabled, now: now, calendar: rome, locale: british, home: "/Users/test")
    }

    private func report(runs: [String] = [], samples: [String] = [], host: String? = nil) throws -> HistoryReport {
        var json = HistoryJSON()
        json.runs = runs
        json.samples = samples
        if let host { json.host = host }
        return try json.report()
    }

    private let runs = [
        HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4)),
        HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2.2)),
        HistoryJSON.run(finished: "2026-09-29T08:02:00Z", freed: gigabytes(36.4)),
    ]

    private var weekAgo: String { TestTime.iso(now.addingTimeInterval(-7 * 86_400)) }

    // MARK: 1 · first run

    func testWithNothingAtAllTheFaceSaysOnlyThatNothingWasCleaned() throws {
        let face = present(try report())
        XCTAssertEqual(face.emptyMessage, "Nothing cleaned yet. When you clean, it shows up here.")
        XCTAssertEqual(HistoryPresentation.emptyMessage, face.emptyMessage)
        XCTAssertNil(face.summary, "no sentence")
        XCTAssertNil(face.timeline, "no line, and not even the words under it")
        XCTAssertTrue(face.rows.isEmpty, "no list")
    }

    func testTheFirstRunSaysTheSameWhetherOrNotCmmCouldReadTheDisk() throws {
        // cmm has read the disk (or could not), but there is still no line and no cleaning: nothing true to say yet
        for host in [#"{"volume":"/System/Volumes/Data","free_bytes":24000000000}"#, #"{"volume":"","free_bytes":0}"#] {
            let face = present(try report(host: host))
            XCTAssertNil(face.timeline, host)
            XCTAssertNotNil(face.emptyMessage, host)
            XCTAssertNil(face.summary, host)
        }
    }

    // MARK: 2 · a few samples

    func testCleaningsButNoLineYetShowTheWordsAndTheList() throws {
        let face = present(try report(runs: [runs[0]]))
        XCTAssertNil(face.emptyMessage)
        XCTAssertEqual(face.summary, "Freed 5.4 GB in 1 cleaning since 14 Oct.")
        XCTAssertNil(face.timeline?.chart, "no line yet")
        XCTAssertEqual(face.timeline?.caption, "History fills in as cmm runs.")
        XCTAssertEqual(face.rows.weeks.flatMap(\.rows).count, 1)
    }

    func testAShortLineIsDrawnWithItsCaption() throws {
        let samples = [
            HistoryJSON.sample("2026-10-12T09:00:00Z", free: gigabytes(20)),
            HistoryJSON.sample("2026-10-13T09:00:00Z", free: gigabytes(18)),
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: gigabytes(24)),
        ]
        let face = present(try report(runs: [runs[0]], samples: samples))
        XCTAssertNotNil(face.timeline?.chart)
        XCTAssertEqual(face.timeline?.caption, "History fills in as cmm runs: 2 days so far.")
    }

    // MARK: the whole face

    func testTheBoardsParagraphLineAndWeeks() throws {
        let samples = [
            HistoryJSON.sample(weekAgo, free: gigabytes(27.1)),
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: gigabytes(20)),
        ]
        let face = present(try report(runs: runs, samples: samples, host: #"{"volume":"/System/Volumes/Data","free_bytes":24000000000}"#))
        XCTAssertEqual(face.summary, "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago.")
        XCTAssertNotNil(face.timeline?.chart)
        XCTAssertNil(face.emptyMessage)
        XCTAssertEqual(face.rows.weeks.flatMap(\.rows).count, 3)
        XCTAssertEqual(face.rows.weeks.map(\.title), ["This week", "Last week", "28 Sep – 4 Oct"])
    }

    func testTheGoldenReportFromCmmIsDrawnAsTheBoardsDraw() throws {
        let golden = try HistoryReport.parse(Fixture.data("history-v1.json"))
        let face = present(golden)
        XCTAssertEqual(face.summary?.hasPrefix("Freed 4.6 GB in 1 cleaning since 14 Oct."), true, "Docker's 6.2 GB inside its disk image is not in it")
        XCTAssertNotNil(face.timeline?.chart)
        XCTAssertEqual(face.rows.weeks.count, 1)
        XCTAssertNil(face.emptyMessage)
    }

    // MARK: history switched off

    func testWithTheHistoryOffTheCleaningsAreStillListedButThereIsNoLineAndNoWeekChange() throws {
        let samples = [HistoryJSON.sample(weekAgo, free: gigabytes(27.1))]
        let report = try report(runs: runs, samples: samples, host: #"{"volume":"/System/Volumes/Data","free_bytes":24000000000}"#)
        let on = present(report)
        XCTAssertEqual(on.summary, "Freed 44.0 GB in 3 cleanings since 29 Sep. Free space is 3.1 GB lower than a week ago.")

        let off = present(report, historyEnabled: false)
        XCTAssertEqual(off.summary, "Freed 44.0 GB in 3 cleanings since 29 Sep.", "the sentence stays, without 'lower than a week ago'")
        XCTAssertNil(off.timeline, "no line")
        XCTAssertEqual(off.rows, on.rows, "the list is the same")
        XCTAssertNil(off.emptyMessage)
    }

    func testWithTheHistoryOffAndNoCleaningTheFaceIsTheFirstRun() throws {
        let samples = [HistoryJSON.sample(weekAgo, free: gigabytes(27.1))]
        let face = present(try report(samples: samples, host: #"{"volume":"/System/Volumes/Data","free_bytes":24000000000}"#), historyEnabled: false)
        XCTAssertNil(face.summary)
        XCTAssertNil(face.timeline)
        XCTAssertNotNil(face.emptyMessage)
    }

    // MARK: a line and no cleaning

    func testALineWithNoCleaningKeepsTheLineAndTheMessageWhereTheListWouldBe() throws {
        let samples = [
            HistoryJSON.sample(weekAgo, free: gigabytes(27.1)),
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: gigabytes(20)),
        ]
        let face = present(try report(samples: samples, host: #"{"volume":"/System/Volumes/Data","free_bytes":24000000000}"#))
        XCTAssertNotNil(face.timeline?.chart)
        XCTAssertEqual(face.summary, "Free space is 3.1 GB lower than a week ago.", "only the half that is true")
        XCTAssertNotNil(face.emptyMessage)
        XCTAssertTrue(face.rows.isEmpty)
    }

    // MARK: Docker-only

    func testARunThatOnlyPrunedDockerIsListedAndLeftOutOfTheParagraph() throws {
        let face = present(try report(runs: [HistoryJSON.run(finished: "2026-10-14T12:20:00Z", freed: 0, inside: gigabytes(9))]))
        XCTAssertNil(face.summary, "no sentence: nothing came back to the disk")
        XCTAssertNil(face.emptyMessage, "but a cleaning was made, and it is listed")
        XCTAssertEqual(face.rows.weeks.flatMap(\.rows).count, 1)
        XCTAssertEqual(face.rows.weeks.first?.rows.first?.freedText, "0 GB freed")
    }
}

/// The History model: the last report cmm gave, and one read at a time.
@MainActor
final class HistoryModelTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    private let now = TestTime.utc("2026-10-15T09:00:00Z")

    private func report(freed: Double) throws -> HistoryReport {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(freed))]
        return try json.report()
    }

    private func face(_ model: HistoryModel, historyEnabled: Bool = true) -> HistoryPresentation? {
        model.presentation(historyEnabled: historyEnabled, now: now, calendar: rome, locale: british, home: "/Users/test")
    }

    func testBeforeAnyReadThereIsNothingToShow() {
        let model = HistoryModel(client: FakeCmmClient(plans: []))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.report)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(face(model))
    }

    func testAReadFillsTheFaceAndAsksCmmForTheHistoryAndNothingElse() async throws {
        let fake = FakeCmmClient(plans: [], histories: [.success(try report(freed: 5.4))])
        let model = HistoryModel(client: fake)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(fake.historyCalls, 1)
        XCTAssertEqual(fake.planCalls, 0)
        XCTAssertEqual(fake.sampleCalls, 0)
        XCTAssertTrue(fake.applyCalls.isEmpty)
        XCTAssertEqual(fake.stopCalls, 0)
        XCTAssertEqual(face(model)?.summary, "Freed 5.4 GB in 1 cleaning since 14 Oct.")
    }

    func testAReadThatFailsSaysSoInWordsAndLeavesNothingToShow() async {
        let fake = FakeCmmClient(plans: [], histories: [.failure(.historyFailed(status: 1, stderr: "could not read /Users/saint/secret"))])
        let model = HistoryModel(client: fake)
        await model.load()
        guard case .failed(let title, let detail) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(title, "cmm could not read the history")
        XCTAssertTrue(detail.contains("Exit status 1"), detail)
        XCTAssertNil(model.report)
        XCTAssertNil(face(model))
        XCTAssertFalse(model.isLoading)
    }

    func testALaterFailureKeepsTheLastGoodReportAndSaysItFailed() async throws {
        let fake = FakeCmmClient(plans: [], histories: [.success(try report(freed: 5.4)), .failure(.historyFailed(status: 2, stderr: ""))])
        let model = HistoryModel(client: fake)
        await model.load()
        await model.load()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertNotNil(model.report, "the last good report stays")
        XCTAssertEqual(face(model)?.summary, "Freed 5.4 GB in 1 cleaning since 14 Oct.")
    }

    func testALaterReadThatWorksClearsTheFailure() async throws {
        let fake = FakeCmmClient(plans: [], histories: [.failure(.historyFailed(status: 2, stderr: "")), .success(try report(freed: 1))])
        let model = HistoryModel(client: fake)
        await model.load()
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(face(model)?.summary, "Freed 1.0 GB in 1 cleaning since 14 Oct.")
    }

    func testAskingWhileAReadIsOutReadsOnceMoreAfterItHoweverManyTimesAsked() async throws {
        let fake = FakeCmmClient(plans: [], histories: [.success(try report(freed: 1)), .success(try report(freed: 2))])
        let gate = fake.holdHistories()
        let model = HistoryModel(client: fake)
        let first = Task { await model.load() }
        await eventuallyOnMain(timeout: 3) { fake.historyCalls == 1 }
        XCTAssertTrue(model.isLoading)

        // a cleaning ended while the first read was out: five asks, and one more read
        var more: [Task<Void, Never>] = []
        for _ in 0..<5 { more.append(Task { await model.load() }) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fake.historyCalls, 1, "none of them starts a second read at once")

        gate.open()
        await first.value
        for task in more { await task.value }
        XCTAssertEqual(fake.historyCalls, 2, "one more read, not five")
        XCTAssertEqual(face(model)?.summary, "Freed 2.0 GB in 1 cleaning since 14 Oct.", "the face has the newer report")
        XCTAssertFalse(model.isLoading)
    }

    func testAnAskAfterTheReadIsDoneMakesANewRead() async throws {
        let fake = FakeCmmClient(plans: [], histories: [.success(try report(freed: 1))])
        let model = HistoryModel(client: fake)
        await model.load()
        await model.load()
        XCTAssertEqual(fake.historyCalls, 2, "no stale follow-up, and a read of its own each time")
    }

    func testTheFaceFollowsTheHistorySwitchAndTheClockItIsGiven() async throws {
        let fake = FakeCmmClient(plans: [], histories: [.success(try report(freed: 5.4))])
        let model = HistoryModel(client: fake)
        await model.load()
        XCTAssertNotNil(face(model, historyEnabled: true)?.timeline)
        XCTAssertNil(face(model, historyEnabled: false)?.timeline)
        // the sentence is about the last ninety days of the clock it is given; the list is whatever cmm remembers
        let later = model.presentation(historyEnabled: true, now: now.addingTimeInterval(100 * 86_400), calendar: rome, locale: british, home: "/Users/test")
        XCTAssertNil(later?.summary, "a hundred days on, the cleaning is outside the window")
        XCTAssertEqual(later?.rows.weeks.flatMap(\.rows).count, 1)
    }
}
