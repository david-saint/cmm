import XCTest
@testable import CmmKit

/// Decoding `cmm history --json` and `cmm sample --json`: the engine's golden document, what may be missing, what is
/// ignored, what is refused, and what is left out (and counted) because the app cannot use it.
final class HistoryReportTests: XCTestCase {
    private func parse(_ json: String) throws -> HistoryReport {
        try HistoryReport.parse(Data(json.utf8))
    }

    // MARK: the golden document

    func testDecodesTheEnginesGoldenDocument() throws {
        let report = try HistoryReport.parse(Fixture.data("history-v1.json"))

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.generatedAt, TestTime.utc("2026-10-15T09:00:00Z"))
        XCTAssertEqual(report.host.volume, "/System/Volumes/Data")
        XCTAssertEqual(report.host.freeBytes, 24_000_000_000)
        XCTAssertEqual(report.host.capacityBytes, 245_107_195_904)
        XCTAssertEqual(report.unreadableLines, 0)
        XCTAssertEqual(report.ignoredEntries, 0)

        XCTAssertEqual(report.runs.count, 1)
        let run = report.runs[0]
        XCTAssertEqual(run.startedAt, TestTime.utc("2026-10-14T12:00:00Z"))
        XCTAssertEqual(run.finishedAt, TestTime.utc("2026-10-14T12:00:42Z"))
        XCTAssertEqual([run.deleted, run.skipped, run.failed], [3, 1, 1])
        XCTAssertEqual(run.freedBytes, 4_642_000_000)
        XCTAssertEqual(run.freedInsideBytes, 6_200_000_000, "Docker's figure is its own field, never part of freed")
        XCTAssertEqual(run.freeBefore, 19_800_000_000)
        XCTAssertEqual(run.freeAfter, 24_442_000_000)
        XCTAssertEqual(run.capacityBytes, 245_107_195_904)
        XCTAssertFalse(run.stopped)
        XCTAssertEqual(run.itemsOmitted, 0)

        XCTAssertEqual(run.items.map(\.rule), ["go-build", "docker", "uv-cache"])
        XCTAssertEqual(run.items.map(\.status), [.deleted, .deleted, .failed])
        XCTAssertEqual(run.items[0].group, "Go build cache")
        XCTAssertEqual(run.items[0].path, "/Users/test/Library/Caches/go-build")
        XCTAssertEqual(run.items[0].bytes, 3_715_000_000)
        XCTAssertEqual(run.items[0].freedBytes, 3_715_000_000)
        XCTAssertNil(run.items[0].freesInside)
        XCTAssertNil(run.items[0].reason)
        XCTAssertEqual(run.items[1].path, "docker: unused images", "a command's label is its path, as in a plan")
        XCTAssertEqual(run.items[1].freesInside, "Docker's disk image")
        XCTAssertEqual(run.items[2].reason, "permission denied")
        XCTAssertEqual(run.items[2].freedBytes, 0)

        XCTAssertEqual(report.samples.map(\.t), [
            TestTime.utc("2026-10-13T08:00:00Z"), TestTime.utc("2026-10-14T12:00:00Z"), TestTime.utc("2026-10-14T12:00:42Z"),
        ], "oldest first, as cmm sends them")
        XCTAssertEqual(report.samples.map(\.freeBytes), [21_000_000_000, 19_800_000_000, 24_442_000_000])
        XCTAssertEqual(report.samples[0].capacityBytes, 245_107_195_904)
    }

    /// The fixture is a copy, so a change to the engine's contract must show up here: when this runs inside the
    /// repository, the copy must still be the engine's golden file, byte for byte.
    func testTheFixtureIsStillTheEnginesGoldenFile() throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // app/macos
            .deletingLastPathComponent().deletingLastPathComponent()  // the repository
            .appendingPathComponent("pkg/engine/testdata/history_v1.golden.json")
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("not inside the cmm repository: the engine's golden file is not at \(engine.path)")
        }
        XCTAssertEqual(try Fixture.data("history-v1.json"), try Data(contentsOf: engine), "copy the golden file again")
    }

    func testAnEmptyHistoryIsValid() throws {
        let report = try HistoryJSON().report()
        XCTAssertTrue(report.runs.isEmpty)
        XCTAssertTrue(report.samples.isEmpty)
        XCTAssertEqual(report.host.freeBytes, 24_000_000_000)
    }

    // MARK: what may be missing, what is extra

    func testOptionalFieldsMayBeMissing() throws {
        var json = HistoryJSON()
        json.host = #"{"volume":"/","free_bytes":5000000000}"#
        json.runs = [#"""
        {"schema_version":1,"started_at":"2026-10-14T12:00:00Z","finished_at":"2026-10-14T12:00:42Z",
         "deleted":1,"skipped":0,"failed":0,"freed_bytes":900,"free_before":10,"free_after":910,
         "items":[{"rule":"go-build","group":"Go build cache","path":"/p","status":"deleted","bytes":900,"freed_bytes":900}]}
        """#]
        json.samples = [#"{"t":"2026-10-14T12:00:00Z","free_bytes":10}"#]
        let report = try json.report()

        XCTAssertNil(report.host.capacityBytes)
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertNil(run.capacityBytes)
        XCTAssertEqual(run.freedInsideBytes, 0, "freed_inside_bytes is left out when there is none")
        XCTAssertEqual(run.itemsOmitted, 0, "items_omitted is left out when nothing was omitted")
        XCTAssertFalse(run.stopped, "a missing stopped is a run that was not stopped")
        XCTAssertNil(run.items[0].freesInside)
        XCTAssertNil(run.items[0].reason)
        XCTAssertNil(report.samples[0].capacityBytes)
    }

    func testAMissingGeneratedAtOrHostIsNotFatal() throws {
        let report = try parse(#"{"schema_version":1,"runs":[],"samples":[]}"#)
        XCTAssertNil(report.generatedAt)
        XCTAssertNil(report.host.freeBytes)
        XCTAssertEqual(report.host.volume, "")
        XCTAssertEqual(report.unreadableLines, 0)
    }

    func testAnUnreadableTimestampOfTheReportIsDroppedNotFatal() throws {
        var json = HistoryJSON()
        json.generatedAt = "a while ago"
        XCTAssertNil(try json.report().generatedAt)
    }

    func testUnknownFieldsAreIgnoredAtEveryLevel() throws {
        var json = HistoryJSON()
        json.host = #"{"volume":"/","free_bytes":5000000000,"capacity_bytes":9000000000,"inodes":12}"#
        json.runs = [HistoryJSON.run(
            finished: "2026-10-14T12:00:42Z", items: [HistoryJSON.item(), #"{"rule":"x","group":"X","path":"/x","status":"deleted","colour":"red"}"#],
            extra: #""host_name":"mac","tags":["a","b"]"#
        )]
        json.samples = [#"{"t":"2026-10-14T12:00:00Z","free_bytes":10,"source":"cron"}"#]
        let text = json.text.replacingOccurrences(of: #""unreadable_lines":0}"#, with: #""unreadable_lines":0,"future":{"a":1}}"#)
        let report = try parse(text)

        XCTAssertEqual(report.runs.count, 1)
        XCTAssertEqual(report.runs[0].items.count, 2)
        XCTAssertEqual(report.samples.count, 1)
        XCTAssertEqual(report.host.capacityBytes, 9_000_000_000)
        XCTAssertEqual(report.ignoredEntries, 0)
    }

    func testTheEnginesOwnUnreadableLineCountIsKept() throws {
        var json = HistoryJSON()
        json.unreadable = 3
        XCTAssertEqual(try json.report().unreadableLines, 3)
    }

    // MARK: schema

    func testASchemaOtherThanOneIsRefusedBeforeAnythingElseIsRead() throws {
        // a document of another schema may have another shape: "runs" here is an object, which a decoder that read the
        // body first would trip over with an unrelated message
        let text = #"{"schema_version":2,"generated_at":"2026-10-15T09:00:00Z","runs":{"by_week":[]}}"#
        XCTAssertThrowsError(try parse(text)) { error in
            XCTAssertEqual(error as? CmmError, .unsupportedHistorySchema(found: 2))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(HistoryReport.self, from: Data(text.utf8))) { error in
            XCTAssertEqual(error as? CmmError, .unsupportedHistorySchema(found: 2), "a plain decoder checks it first too")
        }
    }

    func testTheSchemaMessageSaysWhatTheAppReadsAndIsAboutTheHistory() {
        let error = CmmError.unsupportedHistorySchema(found: 3)
        XCTAssertTrue(error.localizedDescription.contains("this app reads schema 1"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("3"), error.localizedDescription)
        XCTAssertFalse(error.localizedDescription.contains("plan"), "it is not the plan's message")
    }

    func testAMissingSchemaVersionIsMalformedAndSaysSo() {
        XCTAssertThrowsError(try parse(#"{"runs":[],"samples":[]}"#)) { error in
            guard case .malformedHistory(let detail)? = error as? CmmError else { return XCTFail("got \(error)") }
            XCTAssertTrue(detail.contains("schema_version"), detail)
        }
    }

    func testTextThatIsNotJSONIsMalformed() {
        for text in ["", "No cleanups recorded yet.\n", "{", "[1,2,3]"] {
            XCTAssertThrowsError(try parse(text), text) { error in
                guard case .malformedHistory? = error as? CmmError else {
                    return XCTFail("expected malformedHistory for \(text.debugDescription), got \(error)")
                }
            }
        }
    }

    func testAShapeErrorAtTheTopLevelIsMalformedAndNamesTheDocumentAsTheHistory() {
        XCTAssertThrowsError(try parse(#"{"schema_version":1,"runs":"none"}"#)) { error in
            guard case .malformedHistory(let detail)? = error as? CmmError else { return XCTFail("got \(error)") }
            XCTAssertTrue(detail.contains("runs"), detail)
        }
        XCTAssertThrowsError(try parse(#"{"schema_version":"one"}"#)) { error in
            guard case .malformedHistory(let detail)? = error as? CmmError else { return XCTFail("got \(error)") }
            XCTAssertTrue(detail.contains("schema_version"), detail)
            XCTAssertFalse(detail.contains("plan"), detail)
        }
        XCTAssertThrowsError(try parse(#"[]"#)) { error in
            guard case .malformedHistory(let detail)? = error as? CmmError else { return XCTFail("got \(error)") }
            XCTAssertTrue(detail.contains("history"), "an array where the document should be: \(detail)")
            XCTAssertFalse(detail.contains("the plan"), detail)
        }
    }

    // MARK: the host

    func testAnUnreadableHostIsUnknownNotAnEmptyDisk() throws {
        // cmm writes exactly this when it cannot read the free space
        var json = HistoryJSON()
        json.host = #"{"volume":"","free_bytes":0}"#
        let report = try json.report()
        XCTAssertNil(report.host.freeBytes)
        XCTAssertNil(report.host.capacityBytes)

        json.host = #"{"volume":"/System/Volumes/Data","free_bytes":0}"#
        XCTAssertEqual(try json.report().host.freeBytes, 0, "a named volume with nothing free is a full disk")
    }

    func testAHostWithAFreeSpaceNoDiskHasIsUnknown() throws {
        for bad in ["-5", "9000000000000000000"] {
            var json = HistoryJSON()
            json.host = #"{"volume":"/","free_bytes":\#(bad)}"#
            XCTAssertNil(try json.report().host.freeBytes, bad)
        }
        var json = HistoryJSON()
        json.host = #"{"volume":"/","free_bytes":5,"capacity_bytes":-1}"#
        XCTAssertNil(try json.report().host.capacityBytes, "a capacity that cannot be is no capacity")
    }

    // MARK: runs that cannot be used

    func testARunTheAppCannotUseIsLeftOutAndCountedTheOthersSurvive() throws {
        var json = HistoryJSON()
        json.runs = [
            HistoryJSON.run(finished: "2026-10-14T12:00:42Z"),
            HistoryJSON.run(finished: "2026-10-13T12:00:42Z", freed: -5),
            HistoryJSON.run(finished: "2026-10-12T12:00:42Z", schema: 2),
            HistoryJSON.run(finished: "yesterday-ish"),
            #"{"schema_version":1,"started_at":"2026-10-14T12:00:00Z","deleted":1,"skipped":0,"failed":0,"freed_bytes":1,"free_before":1,"free_after":2,"stopped":false,"items":[]}"#,
            HistoryJSON.run(finished: "2026-10-11T12:00:42Z", deleted: -1),
            HistoryJSON.run(finished: "2026-10-10T12:00:42Z", freed: Int64.max),
            HistoryJSON.run(finished: "2026-10-09T12:00:42Z", inside: -1),
            HistoryJSON.run(finished: "2026-10-08T12:00:42Z", failed: 4_000_000_000),
            "7",
            #"{"schema_version":1,"started_at":"2026-10-14T12:00:00Z","finished_at":"2026-10-14T12:00:42Z","deleted":"many"}"#,
            HistoryJSON.run(finished: "2026-10-07T12:00:42Z"),
        ]
        let report = try json.report()
        XCTAssertEqual(report.runs.map(\.finishedAt), [TestTime.utc("2026-10-14T12:00:42Z"), TestTime.utc("2026-10-07T12:00:42Z")])
        XCTAssertEqual(report.ignoredEntries, 10)
    }

    func testARunThatEndedBeforeItStartedIsKeptItsEndIsWhatPlacesIt() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:00:00Z", started: "2026-10-14T12:30:00Z")]
        let run = try XCTUnwrap(try json.report().runs.first)
        XCTAssertEqual(run.finishedAt, TestTime.utc("2026-10-14T12:00:00Z"))
        XCTAssertGreaterThan(try XCTUnwrap(run.startedAt), run.finishedAt)
    }

    func testAMissingStartIsFine() throws {
        var json = HistoryJSON()
        json.runs = [#"{"schema_version":1,"finished_at":"2026-10-14T12:00:42Z","deleted":1,"skipped":0,"failed":0,"freed_bytes":1,"free_before":1,"free_after":2,"stopped":false,"items":[]}"#]
        let run = try XCTUnwrap(try json.report().runs.first)
        XCTAssertNil(run.startedAt)
    }

    // MARK: samples that cannot be used

    func testASampleTheAppCannotUseIsLeftOutAndCounted() throws {
        var json = HistoryJSON()
        json.samples = [
            HistoryJSON.sample("2026-10-13T08:00:00Z", free: 21_000_000_000),
            HistoryJSON.sample("2026-10-13T09:00:00Z", free: -1),
            HistoryJSON.sample("nonsense", free: 1),
            HistoryJSON.sample("2026-10-13T10:00:00Z", free: Int64.max),
            #"{"free_bytes":5}"#,
            "null",
            HistoryJSON.sample("2026-10-13T11:00:00Z", free: 20_000_000_000, capacity: -3),
        ]
        let report = try json.report()
        XCTAssertEqual(report.samples.map(\.freeBytes), [21_000_000_000, 20_000_000_000])
        XCTAssertNil(report.samples[1].capacityBytes, "a capacity that cannot be is dropped, the reading stays")
        XCTAssertEqual(report.ignoredEntries, 5)
    }

    // MARK: items

    func testAnItemWithoutAPathOrStatusIsDroppedAndItsRunStays() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:00:42Z", items: [
            HistoryJSON.item(path: "/kept"),
            #"{"rule":"x","group":"X","status":"deleted"}"#,
            #"{"rule":"x","group":"X","path":"/y"}"#,
            "3",
        ])]
        let report = try json.report()
        XCTAssertEqual(report.runs.count, 1)
        XCTAssertEqual(report.runs[0].items.map(\.path), ["/kept"])
        XCTAssertEqual(report.ignoredEntries, 0, "items are only what a row shows: the run is whole")
    }

    func testAnItemSizeNoDiskHasIsZeroNotARefusal() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:00:42Z", items: [
            HistoryJSON.item(bytes: -4, freed: Int64.max),
        ])]
        let item = try XCTUnwrap(try json.report().runs.first?.items.first)
        XCTAssertEqual(item.bytes, 0)
        XCTAssertEqual(item.freedBytes, 0)
    }

    func testAnEmptyPlaceOrReasonIsNoPlaceAndNoReason() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:00:42Z", items: [
            #"{"rule":"x","group":"X","path":"/y","status":"failed","bytes":1,"freed_bytes":0,"frees_inside":"","reason":""}"#,
        ])]
        let item = try XCTUnwrap(try json.report().runs.first?.items.first)
        XCTAssertNil(item.freesInside)
        XCTAssertNil(item.reason)
    }

    func testAnUnknownItemStatusIsKeptAsItIsWritten() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:00:42Z", items: [HistoryJSON.item(status: "quarantined")])]
        XCTAssertEqual(try json.report().runs.first?.items.first?.status, .other("quarantined"))
    }

    func testItemsOmittedIsKept() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-14T12:00:42Z", extra: #""items_omitted":812"#)]
        XCTAssertEqual(try json.report().runs.first?.itemsOmitted, 812)
    }

    // MARK: times

    func testTimesMayCarryFractionsAndOffsets() throws {
        var json = HistoryJSON()
        json.runs = [
            HistoryJSON.run(finished: "2026-10-14T12:00:42.5Z"),
            HistoryJSON.run(finished: "2026-10-14T14:00:42+02:00"),
        ]
        let report = try json.report()
        XCTAssertEqual(report.runs[0].finishedAt.timeIntervalSince1970, 1_791_979_242.5, accuracy: 0.001)
        XCTAssertEqual(report.runs[1].finishedAt, TestTime.utc("2026-10-14T12:00:42Z"))
    }

    // MARK: ids

    func testRunsHaveStableUniqueIdsEvenWhenTwoEndInTheSameSecond() throws {
        var json = HistoryJSON()
        json.runs = [
            HistoryJSON.run(finished: "2026-10-14T12:00:42Z"),
            HistoryJSON.run(finished: "2026-10-14T12:00:42Z"),
            HistoryJSON.run(finished: "2026-10-13T08:00:00Z"),
        ]
        let first = try json.report().runs.map(\.id)
        XCTAssertEqual(Set(first).count, 3, "no two runs share an id: \(first)")
        XCTAssertEqual(first[0], "1791979242", "the second the run ended")
        XCTAssertEqual(first, try json.report().runs.map(\.id), "the same document gives the same ids")
    }

    // MARK: as of a moment

    func testAsOfLeavesOutWhatIsDatedLaterAndCountsIt() throws {
        var json = HistoryJSON()
        json.runs = [
            HistoryJSON.run(finished: "2026-10-16T09:00:00Z"),
            HistoryJSON.run(finished: "2026-10-14T09:00:00Z"),
            HistoryJSON.run(finished: "2026-10-15T09:00:00Z"),
        ]
        json.samples = [
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: 1), HistoryJSON.sample("2026-10-15T09:00:01Z", free: 2),
            HistoryJSON.sample("2026-10-15T09:00:00Z", free: 3), HistoryJSON.sample("garbage", free: 4),
        ]
        let report = try json.report()
        XCTAssertEqual(report.ignoredEntries, 1, "the one sample with no time")

        let now = TestTime.utc("2026-10-15T09:00:00Z")
        let seen = report.asOf(now)
        XCTAssertEqual(seen.runs.map(\.finishedAt), [now, TestTime.utc("2026-10-14T09:00:00Z")], "exactly now is not the future")
        XCTAssertEqual(seen.samples.map(\.freeBytes), [1, 3])
        XCTAssertEqual(seen.ignoredEntries, 1 + 1 + 1, "a run and a sample from the future are counted with the rest")
        XCTAssertEqual(seen.host, report.host)
        XCTAssertEqual(seen.generatedAt, report.generatedAt)
        XCTAssertEqual(seen.unreadableLines, report.unreadableLines)
    }

    func testAsOfPutsSamplesOldestFirstAndRunsNewestFirstWhateverOrderTheyCameIn() throws {
        var json = HistoryJSON()
        json.runs = [
            HistoryJSON.run(finished: "2026-10-10T09:00:00Z"), HistoryJSON.run(finished: "2026-10-14T09:00:00Z"),
            HistoryJSON.run(finished: "2026-10-12T09:00:00Z"),
        ]
        json.samples = [
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: 3), HistoryJSON.sample("2026-10-10T09:00:00Z", free: 1),
            HistoryJSON.sample("2026-10-12T09:00:00Z", free: 2),
        ]
        let seen = try json.report().asOf(TestTime.utc("2026-10-15T09:00:00Z"))
        XCTAssertEqual(seen.runs.map(\.finishedAt), [
            TestTime.utc("2026-10-14T09:00:00Z"), TestTime.utc("2026-10-12T09:00:00Z"), TestTime.utc("2026-10-10T09:00:00Z"),
        ])
        XCTAssertEqual(seen.samples.map(\.freeBytes), [1, 2, 3])
    }

    func testAsOfKeepsTheOrderOfThingsThatHappenedAtTheSameMoment() throws {
        var json = HistoryJSON()
        json.samples = [
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: 5), HistoryJSON.sample("2026-10-14T09:00:00Z", free: 6),
            HistoryJSON.sample("2026-10-14T09:00:00Z", free: 7),
        ]
        json.runs = (1...3).map { HistoryJSON.run(finished: "2026-10-14T09:00:00Z", freed: Int64($0)) }
        let seen = try json.report().asOf(TestTime.utc("2026-10-15T09:00:00Z"))
        XCTAssertEqual(seen.samples.map(\.freeBytes), [5, 6, 7])
        XCTAssertEqual(seen.runs.map(\.freedBytes), [1, 2, 3])
    }

    func testAsOfOfAnAsOfChangesNothing() throws {
        var json = HistoryJSON()
        json.runs = [HistoryJSON.run(finished: "2026-10-16T09:00:00Z"), HistoryJSON.run(finished: "2026-10-14T09:00:00Z")]
        let once = try json.report().asOf(TestTime.utc("2026-10-15T09:00:00Z"))
        XCTAssertEqual(once.asOf(TestTime.utc("2026-10-15T09:00:00Z")), once)
    }

    // MARK: a big history

    func testTenThousandRunsAreDecoded() throws {
        var json = HistoryJSON()
        let start = TestTime.utc("2026-01-01T00:00:00Z")
        json.runs = (0..<10_000).map { index in
            HistoryJSON.run(finished: TestTime.iso(start.addingTimeInterval(Double(index) * 600)), items: [HistoryJSON.item()])
        }
        let report = try json.report()
        XCTAssertEqual(report.runs.count, 10_000)
        XCTAssertEqual(Set(report.runs.map(\.id)).count, 10_000)
    }
}

final class SampleResultTests: XCTestCase {
    private func parse(_ json: String) throws -> SampleResult {
        try SampleResult.parse(Data(json.utf8))
    }

    func testARecordedSample() throws {
        let result = try parse(#"{"recorded":true,"t":"2026-10-15T09:00:00Z","free_bytes":24000000000,"capacity_bytes":245107195904}"# + "\n")
        XCTAssertEqual(result, SampleResult(recorded: true, t: TestTime.utc("2026-10-15T09:00:00Z"), freeBytes: 24_000_000_000, capacityBytes: 245_107_195_904))
    }

    func testASampleThatWasNotDueStillSaysTheFreeSpace() throws {
        let result = try parse(#"{"recorded":false,"t":"2026-10-15T09:00:00Z","free_bytes":24000000000}"#)
        XCTAssertFalse(result.recorded)
        XCTAssertEqual(result.freeBytes, 24_000_000_000)
        XCTAssertNil(result.capacityBytes, "capacity_bytes is left out when unknown")
    }

    func testUnknownFieldsAreIgnoredAndAnUnreadableTimeIsDropped() throws {
        let result = try parse(#"{"recorded":true,"t":"soon","free_bytes":5,"capacity_bytes":"lots","next":"later"}"#)
        XCTAssertTrue(result.recorded)
        XCTAssertNil(result.t)
        XCTAssertNil(result.capacityBytes)
        XCTAssertEqual(result.freeBytes, 5)
    }

    func testWhatIsNotTheContractIsMalformedAndSaysWhere() {
        for text in ["", "Recorded: 19.6 GB free.\n", "[]", #"{"free_bytes":5}"#, #"{"recorded":true}"#, #"{"recorded":true,"free_bytes":-5}"#,
                     #"{"recorded":"yes","free_bytes":5}"#, #"{"recorded":true,"free_bytes":9000000000000000000}"#] {
            XCTAssertThrowsError(try parse(text), text) { error in
                guard case .malformedSample? = error as? CmmError else {
                    return XCTFail("expected malformedSample for \(text.debugDescription), got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try parse(#"{"free_bytes":5}"#)) { error in
            guard case .malformedSample(let detail)? = error as? CmmError else { return XCTFail("got \(error)") }
            XCTAssertTrue(detail.contains("recorded"), detail)
        }
    }
}
