import XCTest
@testable import CmmKit

final class PlanDecodingTests: XCTestCase {
    // MARK: the sample from the spec

    func testDecodesTheSpecSamplePlan() throws {
        let plan = try Plan.parse(Fixture.data("plan-v1.json"))

        XCTAssertEqual(plan.schemaVersion, 1)
        XCTAssertEqual(plan.host.volume, "/System/Volumes/Data")
        XCTAssertEqual(plan.host.freeBytes, 27_633_246_208)
        XCTAssertEqual(plan.totalBytes, 3_081_535_488)
        XCTAssertEqual(plan.items.count, 4)

        let goBuild = plan.items[0]
        XCTAssertEqual(goBuild.rule, "go-build")
        XCTAssertEqual(goBuild.group, "Go build cache")
        XCTAssertEqual(goBuild.path, "/Users/test/Library/Caches/go-build")
        XCTAssertEqual(goBuild.bytes, 927_080_448)
        XCTAssertEqual(goBuild.tier, .safe)
        XCTAssertEqual(goBuild.action, .delete)
        XCTAssertNil(goBuild.note, "note is optional")

        let lane = plan.items[1]
        XCTAssertEqual(lane.rule, "lane-deps")
        XCTAssertEqual(lane.note, "lane ios27-scene-cloud-mobile: untouched for 5+ days")

        let brew = plan.items[3]
        XCTAssertEqual(brew.action, .command)
        XCTAssertEqual(brew.path, "homebrew: cleanup", "the path of a command item is an opaque identity")
        XCTAssertEqual(brew.note, "boost 1.85.0, 0.5 GB; python@3.14 3.14.7, 81 MB")

        XCTAssertEqual(plan.skipped, [
            Skip(rule: "uv-cache", reason: "uv is running"),
            Skip(rule: "xcode-module-cache", reason: "Xcode is running"),
        ])
    }

    func testTotalAgreesWithTheItemsOfTheFixture() throws {
        let plan = try Plan.parse(Fixture.data("plan-v1.json"))
        XCTAssertEqual(plan.items.reduce(0) { $0 + $1.bytes }, plan.totalBytes)
    }

    func testEmptyPlanKeepsItsSkipReasons() throws {
        let plan = try Plan.parse(Fixture.data("plan-empty.json"))
        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.totalBytes, 0)
        XCTAssertEqual(plan.skipped.map(\.rule), ["go-build", "homebrew"])
        XCTAssertEqual(plan.host.freeBytes, 31_200_000_000)
    }

    // MARK: generated_at

    func testGeneratedAtWithFractionalSecondsAndOffset() throws {
        let plan = try Plan.parse(Fixture.data("plan-v1.json"))
        let date = try XCTUnwrap(plan.generatedAt)
        // 2026-10-15T09:38:54.530781+02:00 is 07:38:54Z
        XCTAssertEqual(date.timeIntervalSince1970, 1_792_049_934.530781, accuracy: 0.001)
    }

    func testGeneratedAtWithZuluSuffixAndWithoutFraction() throws {
        let plan = try Plan.parse(Fixture.data("plan-unknown-fields.json"))
        XCTAssertEqual(try XCTUnwrap(plan.generatedAt).timeIntervalSince1970, 1_791_979_200, accuracy: 0.001)
    }

    func testGeneratedAtWithOffsetButNoFraction() throws {
        let plan = try Plan.parse(Fixture.data("plan-empty.json"))
        XCTAssertEqual(try XCTUnwrap(plan.generatedAt).timeIntervalSince1970, 1_792_051_500, accuracy: 0.001)
    }

    func testAnUnreadableTimestampDoesNotRejectThePlan() throws {
        let json = #"""
        {"schema_version":1,"generated_at":"yesterday-ish","host":{"volume":"/","free_bytes":1},
         "items":[],"skipped":[],"total_bytes":0}
        """#
        let plan = try Plan.parse(Data(json.utf8))
        XCTAssertNil(plan.generatedAt, "the timestamp is informational, so a bad one is dropped, not fatal")
    }

    // MARK: unknown fields

    func testIgnoresUnknownFieldsAtEveryLevel() throws {
        let plan = try Plan.parse(Fixture.data("plan-unknown-fields.json"))
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].path, "/Users/test/Library/Caches/go-build")
        XCTAssertEqual(plan.items[0].bytes, 3_715_000_000)
        XCTAssertEqual(plan.host.freeBytes, 27_583_119_360)
        XCTAssertEqual(plan.skipped, [Skip(rule: "uv-cache", reason: "uv is running")])
        XCTAssertEqual(plan.totalBytes, 3_715_000_000)
    }

    func testUnknownTierAndActionAreKeptNotRejected() throws {
        let plan = try Plan.parse(Fixture.data("plan-mixed-tiers.json"))
        let odd = try XCTUnwrap(plan.items.first { $0.rule == "experiment" })
        XCTAssertEqual(odd.tier, .other("experimental"))
        XCTAssertEqual(odd.action, .other("quarantine"))
        XCTAssertEqual(try XCTUnwrap(plan.items.first { $0.rule == "snapshots" }).tier, .manual)
        XCTAssertEqual(try XCTUnwrap(plan.items.first { $0.rule == "cursor-update" }).tier, .review)
    }

    // MARK: schema mismatch and malformed input

    func testSchemaVersionOtherThanOneIsRejectedBeforeAnythingElseIsRead() throws {
        // The v2 fixture has a different shape (items is an object), so a decoder that read the body first would
        // fail with an unrelated message.
        XCTAssertThrowsError(try Plan.parse(Fixture.data("plan-schema2.json"))) { error in
            XCTAssertEqual(error as? CmmError, .unsupportedSchema(found: 2))
        }
    }

    func testSchemaMismatchMessageTellsThePersonWhatTheAppReads() {
        let message = CmmError.unsupportedSchema(found: 2).localizedDescription
        XCTAssertTrue(message.contains("this app reads schema 1"), message)
        XCTAssertTrue(message.contains("2"), message)
    }

    func testAPlainJSONDecoderChecksTheSchemaFirstToo() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(Plan.self, from: Fixture.data("plan-schema2.json"))) { error in
            XCTAssertEqual(error as? CmmError, .unsupportedSchema(found: 2))
        }
    }

    func testMissingSchemaVersionIsMalformed() {
        let json = #"{"host":{"volume":"/","free_bytes":1},"items":[],"skipped":[],"total_bytes":0}"#
        XCTAssertThrowsError(try Plan.parse(Data(json.utf8))) { error in
            guard case .malformedPlan(let detail)? = error as? CmmError else {
                return XCTFail("expected malformedPlan, got \(error)")
            }
            XCTAssertTrue(detail.contains("schema_version"), detail)
        }
    }

    func testTextThatIsNotJSONIsMalformed() {
        for text in ["", "cmm: something went wrong\n", "Checking what can safely go...\n{"] {
            XCTAssertThrowsError(try Plan.parse(Data(text.utf8)), text) { error in
                guard case .malformedPlan? = error as? CmmError else {
                    return XCTFail("expected malformedPlan for \(text.debugDescription), got \(error)")
                }
            }
        }
    }

    func testAJSONDocumentThatIsNotAnObjectIsMalformed() {
        XCTAssertThrowsError(try Plan.parse(Data("[1,2,3]".utf8))) { error in
            guard case .malformedPlan? = error as? CmmError else { return XCTFail("got \(error)") }
        }
    }

    func testMissingRequiredFieldNamesWhereItIs() {
        let json = #"""
        {"schema_version":1,"host":{"volume":"/","free_bytes":1},"skipped":[],"total_bytes":0,
         "items":[{"rule":"go-build","group":"Go build cache","bytes":1,"tier":"safe","action":"delete"}]}
        """#
        XCTAssertThrowsError(try Plan.parse(Data(json.utf8))) { error in
            guard case .malformedPlan(let detail)? = error as? CmmError else {
                return XCTFail("expected malformedPlan, got \(error)")
            }
            XCTAssertTrue(detail.contains("items"), detail)
            XCTAssertTrue(detail.contains("path"), detail)
        }
    }

    func testAFieldOfTheWrongTypeIsMalformed() {
        let json = #"""
        {"schema_version":1,"host":{"volume":"/","free_bytes":"lots"},"items":[],"skipped":[],"total_bytes":0}
        """#
        XCTAssertThrowsError(try Plan.parse(Data(json.utf8))) { error in
            guard case .malformedPlan(let detail)? = error as? CmmError else {
                return XCTFail("expected malformedPlan, got \(error)")
            }
            XCTAssertTrue(detail.contains("free_bytes"), detail)
        }
    }

    func testSkippedMayBeMissing() throws {
        let json = #"{"schema_version":1,"host":{"volume":"/","free_bytes":1},"items":[],"total_bytes":0}"#
        XCTAssertEqual(try Plan.parse(Data(json.utf8)).skipped, [])
    }
}
