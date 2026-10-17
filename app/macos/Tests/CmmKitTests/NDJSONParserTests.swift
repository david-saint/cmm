import XCTest
@testable import CmmKit

final class NDJSONParserTests: XCTestCase {
    // MARK: expected events

    private let sampleEvents: [ApplyEvent] = [
        .start(StartEvent(selected: 2, matched: 2, bytes: 1_765_167_104, freeBytes: 27_633_246_208)),
        .item(ItemEvent(
            rule: "go-build", group: "Go build cache", path: "/Users/test/Library/Caches/go-build",
            status: .deleted, reason: "", bytes: 927_080_448, freedBytes: 927_080_448
        )),
        .item(ItemEvent(
            rule: "lane-deps",
            group: "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)",
            path: "/Users/test/lane-builds/x/node_modules",
            status: .skipped, reason: "in use: node (pid 1234) has files open", bytes: 838_086_656, freedBytes: 0
        )),
        .done(DoneEvent(
            deleted: 1, skipped: 1, failed: 0, freedBytes: 927_080_448,
            freeBefore: 27_633_246_208, freeAfter: 28_560_326_656,
            stopped: false, warnings: [], log: "/Users/test/.local/state/cmm/cleanup.log"
        )),
    ]

    private func sampleData() throws -> Data { try Fixture.data("apply-events.ndjson") }

    private func parse(_ chunks: [Data]) -> [ApplyEvent] {
        var parser = NDJSONParser()
        var events: [ApplyEvent] = []
        for chunk in chunks { events += parser.feed(chunk) }
        events += parser.finish()
        return events
    }

    private func parse(_ text: String) -> [ApplyEvent] {
        parse([Data(text.utf8)])
    }

    // MARK: the sample from the spec

    func testParsesTheSpecStreamInOneChunk() throws {
        XCTAssertEqual(parse([try sampleData()]), sampleEvents)
    }

    func testSeveralEventsInOneChunkAreAllReturnedInOrder() throws {
        var parser = NDJSONParser()
        let events = parser.feed(try sampleData())
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events, sampleEvents)
        XCTAssertEqual(parser.finish(), [])
    }

    func testSplitAtEveryByteOffsetGivesTheSameEvents() throws {
        let data = try sampleData()
        for offset in 1..<data.count {
            let events = parse([data.prefix(offset), data.dropFirst(offset)].map { Data($0) })
            XCTAssertEqual(events, sampleEvents, "split at byte \(offset)")
        }
    }

    func testOneByteAtATime() throws {
        let data = try sampleData()
        XCTAssertEqual(parse(data.map { Data([$0]) }), sampleEvents)
    }

    func testAPartialLineWaitsForItsNewline() throws {
        var parser = NDJSONParser()
        let line = Data(#"{"event":"item","path":"/Users/test/a","status":"deleted"}"#.utf8)
        XCTAssertEqual(parser.feed(line.prefix(20)), [])
        XCTAssertEqual(parser.feed(line.dropFirst(20)), [], "no newline yet, so the line is not complete")
        let events = parser.feed(Data("\n".utf8))
        XCTAssertEqual(events.count, 1)
        guard case .item(let item) = events[0] else { return XCTFail("expected an item") }
        XCTAssertEqual(item.path, "/Users/test/a")
    }

    func testAChunkMayEndInTheMiddleOfTheNextLine() throws {
        let data = try sampleData()
        let firstLineEnd = try XCTUnwrap(data.firstIndex(of: 0x0A))
        var parser = NDJSONParser()
        XCTAssertEqual(parser.feed(data.prefix(firstLineEnd + 1 + 10)), [sampleEvents[0]])
        XCTAssertEqual(parser.feed(data.dropFirst(firstLineEnd + 1 + 10)), Array(sampleEvents.dropFirst()))
    }

    func testTheLastLineWithoutANewlineIsFlushedByFinish() {
        var parser = NDJSONParser()
        let text = #"{"event":"start","schema_version":1,"selected":1,"matched":1,"bytes":5,"free_bytes":9}"#
        XCTAssertEqual(parser.feed(Data(text.utf8)), [])
        XCTAssertEqual(
            parser.finish(),
            [.start(StartEvent(selected: 1, matched: 1, bytes: 5, freeBytes: 9))]
        )
        XCTAssertEqual(parser.finish(), [], "finish is idempotent")
    }

    func testWindowsLineEndingsAndBlankLinesAreTolerated() {
        let text = "\r\n"
            + #"{"event":"start","selected":1,"matched":1,"bytes":5,"free_bytes":9}"# + "\r\n"
            + "   \n\n"
            + #"{"event":"item","path":"/Users/test/a","status":"deleted"}"# + "\r\n"
        let events = parse(text)
        XCTAssertEqual(events.count, 2)
    }

    func testPathsWithNonASCIICharactersSurviveBeingSplitInsideACharacter() throws {
        let line = #"{"event":"item","path":"/Users/test/Café 📦/node_modules","status":"deleted"}"# + "\n"
        let data = Data(line.utf8)
        for offset in 1..<data.count {
            let events = parse([Data(data.prefix(offset)), Data(data.dropFirst(offset))])
            guard events.count == 1, case .item(let item) = events[0] else {
                return XCTFail("split at \(offset) gave \(events)")
            }
            XCTAssertEqual(item.path, "/Users/test/Café 📦/node_modules", "split at byte \(offset)")
        }
    }

    // MARK: bad lines

    func testABadLineIsReportedAndTheLinesAroundItStillParse() throws {
        let good1 = #"{"event":"start","selected":1,"matched":1,"bytes":5,"free_bytes":9}"#
        let good2 = #"{"event":"item","path":"/Users/test/a","status":"deleted"}"#
        let events = parse("\(good1)\nthis is not json at all\n\(good2)\n")

        XCTAssertEqual(events.count, 3)
        guard case .start = events[0] else { return XCTFail("first should be start: \(events[0])") }
        guard case .unreadable(let preview) = events[1] else { return XCTFail("second should be unreadable: \(events[1])") }
        XCTAssertEqual(preview, "this is not json at all")
        guard case .item = events[2] else { return XCTFail("third should be item: \(events[2])") }
    }

    func testEveryKindOfBrokenLineBecomesUnreadableNeverACrashOrAGuess() {
        let broken = [
            #"{"event":"item","path":"#,                                   // cut off
            "[1,2,3]",                                                      // not an object
            "42",
            #""just a string""#,
            #"{"event":"item","status":"deleted"}"#,                         // item without a path
            #"{"event":"item","path":"/Users/test/a"}"#,                     // item without a status
            #"{"event":"start","selected":"two","matched":1,"bytes":1,"free_bytes":1}"#, // wrong type
            #"{"event":"done","deleted":1}"#,                                 // done without its counters
            #"{"event":7}"#,                                                  // event is not a string
            #"{"no_event_key":true}"#,
        ]
        for line in broken {
            let events = parse(line + "\n")
            XCTAssertEqual(events.count, 1, line)
            guard case .unreadable? = events.first else { XCTFail("not unreadable: \(line) -> \(events)"); continue }
        }
    }

    func testAnEventWithoutItsSummaryFieldsIsNotInventedFromDefaults() {
        let events = parse(#"{"event":"done","deleted":1,"skipped":0,"failed":0}"# + "\n")
        XCTAssertEqual(events.count, 1)
        guard case .unreadable? = events.first else { return XCTFail("a half done event must not become a summary") }
    }

    func testUnknownEventKindsAreIgnoredForForwardCompatibility() {
        let text = #"{"event":"progress","percent":50}"# + "\n"
            + #"{"event":"item","path":"/Users/test/a","status":"deleted"}"# + "\n"
        let events = parse(text)
        XCTAssertEqual(events.count, 1)
        guard case .item? = events.first else { return XCTFail("got \(events)") }
    }

    func testUnreadablePreviewIsShortened() {
        let events = parse(String(repeating: "x", count: 5_000) + "\n")
        guard case .unreadable(let preview)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertLessThanOrEqual(preview.count, 201)
    }

    func testAnOverlongLineIsDroppedAndTheStreamRecovers() {
        var parser = NDJSONParser()
        let block = Data(repeating: UInt8(ascii: "a"), count: 256 * 1024)
        var events: [ApplyEvent] = []
        for _ in 0..<8 { events += parser.feed(block) }          // 2 MiB and still no newline
        events += parser.feed(Data("\n".utf8))
        events += parser.feed(Data(#"{"event":"item","path":"/Users/test/a","status":"deleted"}"#.utf8) + Data("\n".utf8))
        events += parser.finish()

        XCTAssertEqual(events.count, 2, "\(events)")
        guard case .unreadable? = events.first else { return XCTFail("first should be unreadable: \(events)") }
        guard case .item(let item)? = events.last else { return XCTFail("last should be the item: \(events)") }
        XCTAssertEqual(item.path, "/Users/test/a")
    }

    // MARK: what each event carries

    func testItemStatuses() {
        func status(_ text: String) -> ItemStatus? {
            let events = parse(#"{"event":"item","path":"/p","status":"\#(text)"}"# + "\n")
            guard case .item(let item)? = events.first else { return nil }
            return item.status
        }
        XCTAssertEqual(status("deleted"), .deleted)
        XCTAssertEqual(status("skipped"), .skipped)
        XCTAssertEqual(status("failed"), .failed)
        XCTAssertEqual(status("dry-run"), .dryRun)
        XCTAssertEqual(status("quarantined"), .other("quarantined"))
    }

    func testAnItemNeedsOnlyAPathAndAStatus() {
        let events = parse(#"{"event":"item","path":"/p","status":"skipped"}"# + "\n")
        guard case .item(let item)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(item, ItemEvent(rule: "", group: "", path: "/p", status: .skipped, reason: "", bytes: 0, freedBytes: 0))
    }

    func testDoneWithoutWarningsOrLog() {
        let events = parse(
            #"{"event":"done","deleted":2,"skipped":0,"failed":0,"freed_bytes":10,"free_before":100,"free_after":110,"stopped":false}"#
                + "\n"
        )
        guard case .done(let done)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(done.warnings, [])
        XCTAssertNil(done.log)
        XCTAssertEqual(done.freedBytes, 10)
        XCTAssertFalse(done.stopped)
    }

    func testFailedStreamFixture() throws {
        let events = parse([try Fixture.data("apply-events-failed.ndjson")])
        XCTAssertEqual(events.count, 5)
        guard case .item(let failed) = events[2], case .done(let done) = events[4] else { return XCTFail("shape: \(events)") }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.reason, "remove /Users/test/.npm/_cacache/content-v2: permission denied")
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.warnings, ["could not write the cleanup log: permission denied"])
        XCTAssertNil(done.log, "log is present only when something was logged")
    }

    func testStoppedStreamFixture() throws {
        let events = parse([try Fixture.data("apply-events-stopped.ndjson")])
        guard case .done(let done)? = events.last else { return XCTFail("no done: \(events)") }
        XCTAssertTrue(done.stopped)
        XCTAssertEqual(done.deleted, 1)
    }

    func testUnknownFieldsInEventsAreIgnored() {
        let events = parse(#"{"event":"item","path":"/p","status":"deleted","extra":{"a":[1,2]},"pid":7}"# + "\n")
        XCTAssertEqual(events.count, 1)
        guard case .item? = events.first else { return XCTFail("got \(events)") }
    }
}
