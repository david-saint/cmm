import XCTest
@testable import CmmKit

/// The list under the chart (spec R4 and the boards `C-History` and `C-History-States`): weeks in the person's own calendar,
/// a row per cleaning, what a row says and what it leaves out, its items, and Docker's figure kept apart.
final class HistoryRunRowsTests: XCTestCase {
    private let rome = TestCalendars.rome
    private let british = Locale(identifier: "en_GB")
    private let home = "/Users/test"
    /// Thursday 15 October 2026, 11:00 in Rome.
    private var now: Date { rome.local(2026, 10, 15, 11, 0) }

    private func report(_ runs: [String], unreadable: Int = 0) throws -> HistoryReport {
        var json = HistoryJSON()
        json.runs = runs
        json.unreadable = unreadable
        return try json.report()
    }

    private func rows(
        _ runs: [String], now: Date? = nil, calendar: Calendar? = nil, locale: Locale? = nil, unreadable: Int = 0
    ) throws -> RunRows {
        RunRows(
            report: try report(runs, unreadable: unreadable), now: now ?? self.now, calendar: calendar ?? rome,
            locale: locale ?? british, home: home
        )
    }

    private func onlyRow(_ run: String, now: Date? = nil) throws -> RunRows.Row {
        let weeks = try rows([run], now: now).weeks
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].rows.count, 1)
        return weeks[0].rows[0]
    }

    private func item(_ rule: String, _ group: String, freed: Int64, status: String = "deleted", path: String? = nil) -> String {
        HistoryJSON.item(rule: rule, group: group, path: path ?? "/Users/test/\(rule)/\(freed)", status: status, bytes: freed, freed: status == "deleted" ? freed : 0)
    }

    // MARK: the golden run

    func testTheGoldenRunIsOneRowWithEverythingTheBoardShows() throws {
        let golden = try HistoryReport.parse(Fixture.data("history-v1.json"))
        let rows = RunRows(report: golden, now: TestTime.utc("2026-10-15T09:00:00Z"), calendar: rome, locale: british, home: home)

        XCTAssertEqual(rows.weeks.count, 1)
        let week = rows.weeks[0]
        XCTAssertEqual(week.title, "This week")
        XCTAssertEqual(week.freedBytes, 4_642_000_000)
        XCTAssertEqual(week.totalText, "4.6 GB")

        let row = try XCTUnwrap(week.rows.first)
        XCTAssertEqual(row.id, "1791979242")
        XCTAssertEqual(row.dateText, "Wed 14 Oct")
        XCTAssertEqual(row.timeText, "14:00", "12:00:42 UTC is 14:00 in Rome")
        XCTAssertEqual(row.freedBytes, 4_642_000_000)
        XCTAssertEqual(row.freedText, "4.6 GB freed", "Docker's 6.2 GB is not in it")
        XCTAssertEqual(row.groupsText, "Docker, Go build cache", "the deleted items' groups, largest first")
        XCTAssertEqual(row.failedText, "1 failed")
        XCTAssertNil(row.stoppedText)
        XCTAssertEqual(row.insideText, "6.2 GB inside Docker's disk image, not counted")
        XCTAssertEqual(row.footnote, "Freed is what the disk got back: 19.8 \u{2192} 24.4 GB free.")
        XCTAssertTrue(row.hasDetails)
        XCTAssertNil(row.omittedText)
        XCTAssertNil(rows.footnote)

        XCTAssertEqual(row.items.map(\.title), ["docker: unused images", "~/Library/Caches/go-build", "~/.cache/uv"],
                       "largest first; a command's label as it is; the home folder written ~")
        XCTAssertEqual(row.items.map(\.detail), ["deleted inside Docker's disk image", "deleted", "permission denied"])
        XCTAssertEqual(row.items.map(\.sizeText), ["6.2 GB", "3.7 GB", "2.5 GB"])
        XCTAssertEqual(row.items.map(\.status), [.deleted, .deleted, .failed])
        XCTAssertEqual(row.items.map(\.insidePlace), ["Docker's disk image", nil, nil])
        XCTAssertEqual(Set(row.items.map(\.id)).count, 3)
    }

    // MARK: the boards' four runs

    /// This week and last week and an older one, as C-History draws them (in 2026's calendar).
    func testTheBoardsWeeksAndTheirTotals() throws {
        let docker = HistoryJSON.item(rule: "docker", group: "Docker", path: "docker: unused images", bytes: gigabytes(9), freed: gigabytes(9), inside: "Docker's disk image")
        let runs = [
            // Wed 14 Oct 14:20, Docker only
            HistoryJSON.run(finished: "2026-10-14T12:20:00Z", freed: 0, inside: gigabytes(9), before: gigabytes(17), after: gigabytes(17), items: [docker]),
            // Wed 14 Oct 14:06
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4), items: [
                item("lane-deps", "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)", freed: gigabytes(3.6)),
                item("uv-cache", "uv cache", freed: gigabytes(0.6)),
                item("go-build", "Go build cache", freed: gigabytes(1.2)),
            ]),
            // Fri 9 Oct 09:41
            HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2.2), failed: 1, items: [
                item("go-build", "Go build cache", freed: gigabytes(1.2), status: "failed", path: "/Users/test/Library/Caches/go-build"),
                item("homebrew", "Homebrew", freed: gigabytes(0.7), path: "homebrew: cleanup"),
                item("npm-cache", "npm cache", freed: gigabytes(0.3), path: "/Users/test/.npm/_cacache"),
            ]),
            // Tue 29 Sep 10:02
            HistoryJSON.run(finished: "2026-09-29T08:02:00Z", freed: gigabytes(36.4), items: [
                item("simulators", "Simulators whose runtime was removed", freed: gigabytes(9)),
                item("lane-deps", "Idle lane dependencies", freed: gigabytes(8), path: "/a"),
                item("claude-versions", "Old claude CLI versions", freed: gigabytes(7)),
                item("go-build", "Go build cache", freed: gigabytes(5)),
                item("npm-cache", "npm cache", freed: gigabytes(4)),
                item("uv-cache", "uv cache", freed: gigabytes(2)),
                item("bun-cache", "bun cache", freed: gigabytes(1.4)),
            ]),
        ]
        let rows = try self.rows(runs)

        XCTAssertEqual(rows.weeks.map(\.title), ["This week", "Last week", "28 Sep \u{2013} 4 Oct"])
        XCTAssertEqual(rows.weeks.map(\.totalText), ["5.4 GB", "2.2 GB", "36.4 GB"])
        XCTAssertEqual(rows.weeks.map { $0.rows.count }, [2, 1, 1])

        // the Docker-only run: 0 GB freed, the dotted chip, no footnote
        let dockerOnly = rows.weeks[0].rows[0]
        XCTAssertEqual(dockerOnly.dateText, "Wed 14 Oct")
        XCTAssertEqual(dockerOnly.timeText, "14:20")
        XCTAssertEqual(dockerOnly.freedText, "0 GB freed")
        XCTAssertEqual(dockerOnly.insideText, "9.0 GB inside Docker's disk image, not counted")
        XCTAssertEqual(dockerOnly.groupsText, "Docker")
        XCTAssertNil(dockerOnly.footnote, "nothing came back, so there is nothing to explain")
        XCTAssertEqual(dockerOnly.items.first?.detail, "deleted inside Docker's disk image")
        XCTAssertEqual(dockerOnly.items.first?.sizeText, "9.0 GB")

        let lanes = rows.weeks[0].rows[1]
        XCTAssertEqual(lanes.freedText, "5.4 GB freed")
        XCTAssertEqual(lanes.groupsText, "Idle lane dependencies, Go build cache, uv cache", "the label's parenthesis is not part of the name")

        let failed = rows.weeks[1].rows[0]
        XCTAssertEqual(failed.dateText, "Fri 9 Oct")
        XCTAssertEqual(failed.timeText, "09:41")
        XCTAssertEqual(failed.groupsText, "Homebrew old versions, npm cache", "the failed item's group is not named: nothing of it went")
        XCTAssertEqual(failed.failedText, "1 failed")
        XCTAssertEqual(failed.items.map(\.title), ["~/Library/Caches/go-build", "homebrew: cleanup", "~/.npm/_cacache"])
        XCTAssertEqual(failed.items.map(\.detail), ["failed", "deleted", "deleted"], "no reason given, none made up")

        let older = rows.weeks[2].rows[0]
        XCTAssertEqual(older.groupsText, "Unavailable simulators, idle lane dependencies, old Claude CLI versions and 4 more")
        XCTAssertEqual(older.dateText, "Tue 29 Sep")
    }

    /// The week headers add up to the sentence above the list, as the board's 5.4 + 2.2 + 36.4 = 44.0 does.
    func testTheWeekHeadersAddUpToTheTotalsSentence() throws {
        let runs = [
            HistoryJSON.run(finished: "2026-10-14T12:20:00Z", freed: 0, inside: gigabytes(9)),
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(5.4)),
            HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2.2)),
            HistoryJSON.run(finished: "2026-09-29T08:02:00Z", freed: gigabytes(36.4)),
        ]
        let rows = try self.rows(runs)
        let weeks = HistoryLimits.sum(rows.weeks.map(\.freedBytes))
        let totals = try XCTUnwrap(HistorySentences.freedTotals(report: try report(runs), now: now))
        XCTAssertEqual(weeks, totals.bytes)
        XCTAssertEqual(
            HistorySentences.totalsSentence(report: try report(runs), now: now, calendar: rome, locale: british),
            "Freed \(SizeText.string(weeks)) in 3 cleanings since 29 Sep."
        )
        XCTAssertEqual(SizeText.string(weeks), "44.0 GB")
    }

    // MARK: groups named

    private func groups(_ items: [String]) throws -> String? {
        try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", items: items)).groupsText
    }

    func testTheGroupsAreNamedLargestFirstThreeAtMostAndThenHowManyMore() throws {
        let a = item("go-build", "Go build cache", freed: gigabytes(5))
        let b = item("uv-cache", "uv cache", freed: gigabytes(4))
        let c = item("npm-cache", "npm cache", freed: gigabytes(3))
        let d = item("bun-cache", "bun cache", freed: gigabytes(2))
        let e = item("cocoapods", "CocoaPods cache", freed: gigabytes(1))
        XCTAssertEqual(try groups([a]), "Go build cache")
        XCTAssertEqual(try groups([b, a]), "Go build cache, uv cache")
        XCTAssertEqual(try groups([c, b, a]), "Go build cache, uv cache, npm cache")
        XCTAssertEqual(try groups([d, c, b, a]), "Go build cache, uv cache, npm cache and 1 more")
        XCTAssertEqual(try groups([e, d, c, b, a]), "Go build cache, uv cache, npm cache and 2 more")
    }

    func testItemsOfOneGroupAreOneNameAndTheirSizesAddUp() throws {
        let items = [
            item("npm-cache", "npm cache", freed: gigabytes(1), path: "/Users/test/a"),
            item("npm-cache", "npm cache", freed: gigabytes(1), path: "/Users/test/b"),
            item("go-build", "Go build cache", freed: gigabytes(1.5)),
        ]
        XCTAssertEqual(try groups(items), "npm cache, Go build cache", "two of 1 GB outweigh one of 1.5 GB")
    }

    func testGroupsOfTheSameSizeAreOrderedByNameSoTheRowDoesNotJump() throws {
        let items = [
            item("uv-cache", "uv cache", freed: gigabytes(1)),
            item("go-build", "Go build cache", freed: gigabytes(1)),
            item("npm-cache", "npm cache", freed: gigabytes(1)),
        ]
        XCTAssertEqual(try groups(items), "Go build cache, npm cache, uv cache")
        XCTAssertEqual(try groups(items.reversed()), "Go build cache, npm cache, uv cache")
    }

    func testOnlyWhatWasDeletedIsNamedAndAnEmptyNameIsLeftOut() throws {
        XCTAssertNil(try groups([item("go-build", "Go build cache", freed: gigabytes(1), status: "failed")]), "nothing went")
        XCTAssertNil(try groups([]), "a run with no items listed has no groups to name")
        XCTAssertEqual(
            try groups([item("go-build", "Go build cache", freed: 5), HistoryJSON.item(rule: "", group: "", path: "/x", status: "deleted", bytes: 9, freed: 9)]),
            "Go build cache"
        )
    }

    func testANameIsTheCatalogsAndAnUnknownRuleKeepsItsOwnLabelWithoutTheParenthesis() throws {
        XCTAssertEqual(try groups([item("some-new", "Some new cache (rebuilds on demand)", freed: 5)]), "Some new cache")
        XCTAssertEqual(try groups([item("some-new", "", freed: 5)]), "Some new")
        XCTAssertEqual(
            try groups([item("lane-deps", "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)", freed: 5)]),
            "Idle lane dependencies"
        )
    }

    func testOnlyAPlainFirstWordLosesItsCapitalInTheMiddleOfTheList() throws {
        let items = [
            item("simulators", "x", freed: gigabytes(3)), item("deriveddata-stale", "x", freed: gigabytes(2)),
            item("go-build", "x", freed: gigabytes(1)),
        ]
        XCTAssertEqual(try groups(items), "Unavailable simulators, stale Xcode build output, Go build cache")
    }

    // MARK: failed, stopped, inside

    func testFailedIsTheRunsOwnCountNotTheCountOfItsItems() throws {
        let row = try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", failed: 3, items: [item("go-build", "x", freed: 5, status: "failed")]))
        XCTAssertEqual(row.failedText, "3 failed", "items_omitted may have cut the list; the count is cmm's")
        XCTAssertNil(try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", failed: 0)).failedText)
    }

    func testStoppedSaysHowFarWhenCmmSaidHowManyItMeantToDoAndOtherwiseJustStopped() throws {
        func stopped(deleted: Int, skipped: Int = 0, failed: Int = 0, planned: Int?, stopped: Bool = true) throws -> String? {
            try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", deleted: deleted, skipped: skipped, failed: failed, stopped: stopped, planned: planned)).stoppedText
        }
        XCTAssertEqual(try stopped(deleted: 2, planned: 9), "Stopped after 2 of 9", "C-History-States, 5 · A stopped run")
        XCTAssertEqual(try stopped(deleted: 1, failed: 1, planned: 9), "Stopped after 2 of 9")
        XCTAssertEqual(try stopped(deleted: 1, skipped: 1, failed: 1, planned: 9), "Stopped after 3 of 9", "what cmm dealt with, skipped ones too")
        XCTAssertEqual(try stopped(deleted: 9, planned: 9), "Stopped after 9 of 9")
        XCTAssertEqual(try stopped(deleted: 2, planned: nil), "Stopped", "the history does not know how many it meant to do")
        XCTAssertEqual(try stopped(deleted: 3, planned: 2), "Stopped", "more than it planned cannot be")
        XCTAssertEqual(try stopped(deleted: 0, planned: 9), "Stopped", "nothing reached: not 0 of 9")
        XCTAssertNil(try stopped(deleted: 2, planned: 9, stopped: false), "a run that went to its end is not stopped")
    }

    func testDockersFigureIsApartAndNamesTheItemsPlacesJoinedTheWayTheAppJoinsThem() throws {
        func inside(_ items: [String], bytes: Int64 = gigabytes(9)) throws -> String? {
            try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: 0, inside: bytes, items: items)).insideText
        }
        let docker = HistoryJSON.item(rule: "docker", group: "Docker", path: "docker: a", bytes: 1, freed: 1, inside: "Docker's disk image")
        let again = HistoryJSON.item(rule: "docker", group: "Docker", path: "docker: b", bytes: 1, freed: 1, inside: "Docker's disk image")
        let other = HistoryJSON.item(rule: "x", group: "X", path: "x: c", bytes: 1, freed: 1, inside: "Colima's disk")
        XCTAssertEqual(try inside([docker, again]), "9.0 GB inside Docker's disk image, not counted", "one place, named once")
        XCTAssertEqual(try inside([docker, other]), "9.0 GB inside Docker's disk image and Colima's disk, not counted")
        XCTAssertEqual(try inside([]), "9.0 GB inside another program's own storage, not counted", "no item names a place")
        XCTAssertNil(try inside([docker], bytes: 0), "nothing went inside: no chip")
    }

    func testTheInsideFigureIsInNoTotal() throws {
        let runs = [HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(1), inside: gigabytes(40))]
        let rows = try self.rows(runs)
        XCTAssertEqual(rows.weeks[0].freedBytes, gigabytes(1))
        XCTAssertEqual(rows.weeks[0].totalText, "1.0 GB")
        XCTAssertEqual(rows.weeks[0].rows[0].freedText, "1.0 GB freed")
        let everything = rows.weeks.flatMap { [$0.title, $0.totalText] + $0.rows.flatMap { [$0.freedText, $0.footnote ?? ""] } }
        XCTAssertFalse(everything.contains { $0.contains("41.0") || $0.contains("40.0") }, "\(everything)")
    }

    // MARK: items

    func testItemsAreLargestFirstWithTheirOwnWordsAndAMoreLineWhenTheyDidNotAllFit() throws {
        let row = try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", items: [
            HistoryJSON.item(path: "/Users/test/a", status: "deleted", bytes: gigabytes(1), freed: gigabytes(1)),
            HistoryJSON.item(path: "/Users/test2/b", status: "failed", bytes: gigabytes(3), reason: "permission denied"),
            HistoryJSON.item(path: "/opt/c", status: "quarantined", bytes: gigabytes(2), freed: 0),
            HistoryJSON.item(path: "/Users/test", status: "deleted", bytes: gigabytes(0.5), freed: gigabytes(0.5)),
        ], extra: #""items_omitted":812"#))
        XCTAssertEqual(row.items.map(\.title), ["/Users/test2/b", "/opt/c", "~/a", "~"], "the home folder only at a folder boundary")
        XCTAssertEqual(row.items.map(\.detail), ["permission denied", "quarantined", "deleted", "deleted"])
        XCTAssertEqual(row.items.map(\.status), [.failed, .other, .deleted, .deleted])
        XCTAssertEqual(row.items.map(\.sizeText), ["3.0 GB", "2.0 GB", "1.0 GB", "0.5 GB"], "a failed item shows the size it would have been")
        XCTAssertEqual(row.omittedText, "and 812 more, not listed")
        XCTAssertTrue(row.hasDetails)
    }

    func testADeletedItemShowsWhatItFreedAndIsPlacedBySizeByThat() throws {
        // an item that was deleted can have freed less than it was worth when the plan was made (it shrank, or part of it was
        // in use): the row says what the disk got back, and the list is in the order of what the rows say
        let row = try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", items: [
            HistoryJSON.item(path: "/Users/test/a", status: "deleted", bytes: gigabytes(3), freed: gigabytes(1)),
            HistoryJSON.item(path: "/Users/test/b", status: "deleted", bytes: gigabytes(1.5), freed: gigabytes(1.5)),
            HistoryJSON.item(path: "/Users/test/c", status: "failed", bytes: gigabytes(2), reason: "permission denied"),
        ]))
        XCTAssertEqual(row.items.map(\.title), ["~/c", "~/b", "~/a"])
        XCTAssertEqual(row.items.map(\.sizeText), ["2.0 GB", "1.5 GB", "1.0 GB"])
    }

    func testARunWithNoItemsAndNothingOmittedHasNothingToOpen() throws {
        let row = try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z"))
        XCTAssertFalse(row.hasDetails)
        XCTAssertNil(row.omittedText)
        let omitted = try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", extra: #""items_omitted":3"#))
        XCTAssertTrue(omitted.hasDetails, "the line still says there were more")
    }

    func testTheFootnoteDropsTheFirstUnitOnlyWhenBothAreTheSame() throws {
        func note(before: Int64, after: Int64) throws -> String? {
            try onlyRow(HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: 1, before: before, after: after)).footnote
        }
        XCTAssertEqual(try note(before: 17_000_000_000, after: 19_200_000_000), "Freed is what the disk got back: 17.0 \u{2192} 19.2 GB free.")
        XCTAssertEqual(try note(before: 50_000_000, after: 1_200_000_000), "Freed is what the disk got back: 50 MB \u{2192} 1.2 GB free.")
        XCTAssertEqual(try note(before: 1_200_000_000_000, after: 900_000_000_000), "Freed is what the disk got back: 1.2 TB \u{2192} 900.0 GB free.")
    }

    // MARK: when

    func testTheYearIsWrittenOnlyForARunMoreThanAYearOld() throws {
        let yearAgo = rome.local(2025, 10, 15, 11, 0)
        let exactly = try onlyRow(HistoryJSON.run(finished: TestTime.iso(yearAgo), freed: 1))
        XCTAssertEqual(exactly.dateText, "Wed 15 Oct", "exactly a year ago has no year")
        let older = try onlyRow(HistoryJSON.run(finished: TestTime.iso(yearAgo.addingTimeInterval(-1)), freed: 1))
        XCTAssertEqual(older.dateText, "Wed, 15 Oct 2025", "a second older does (the locale puts a comma into the longer form)")
        XCTAssertEqual(older.timeText, "10:59")
    }

    func testTheTimeIsInThePersonsOwnZone() throws {
        let row = try onlyRow(HistoryJSON.run(finished: "2026-10-14T22:30:00Z"))
        XCTAssertEqual(row.dateText, "Thu 15 Oct", "half past midnight in Rome")
        XCTAssertEqual(row.timeText, "00:30")
        let utc = RunRows(report: try report([HistoryJSON.run(finished: "2026-10-14T22:30:00Z")]), now: now, calendar: TestCalendars.utc, locale: british, home: home)
        XCTAssertEqual(utc.weeks[0].rows[0].dateText, "Wed 14 Oct")
        XCTAssertEqual(utc.weeks[0].rows[0].timeText, "22:30")
    }

    func testTheTimeFollowsThePersonsClockStyle() throws {
        let american = RunRows(report: try report([HistoryJSON.run(finished: "2026-10-14T22:30:00Z")]), now: now, calendar: rome, locale: Locale(identifier: "en_US"), home: home)
        let row = american.weeks[0].rows[0]
        XCTAssertTrue(row.timeText.contains("12:30") && row.timeText.contains("AM"), "half past midnight in Rome: \(row.timeText)")
        XCTAssertTrue(row.dateText.hasPrefix("Thu"), row.dateText)
    }

    // MARK: weeks

    func testWeeksFollowTheCalendarsFirstDay() throws {
        // Saturday 10 Oct 23:30, Sunday 11 Oct 00:30 and Monday 12 Oct 00:30, in Rome
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 10, 12, 0, 30)), freed: gigabytes(3)),
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 10, 11, 0, 30)), freed: gigabytes(2)),
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 10, 10, 23, 30)), freed: gigabytes(1)),
        ]
        let mondayFirst = try rows(runs)
        XCTAssertEqual(mondayFirst.weeks.map(\.title), ["This week", "Last week"])
        XCTAssertEqual(mondayFirst.weeks.map { $0.rows.count }, [1, 2], "Saturday and Sunday are one week when the week starts on Monday")

        let sundayFirst = try rows(runs, calendar: TestCalendars.make("Europe/Rome", firstWeekday: 1))
        XCTAssertEqual(sundayFirst.weeks.map { $0.rows.count }, [2, 1], "and Sunday and Monday are one when it starts on Sunday")
    }

    func testAWeekThatRunsAcrossNewYearIsOneWeek() throws {
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 1, 1, 12, 0)), freed: gigabytes(1)),
            HistoryJSON.run(finished: TestTime.iso(rome.local(2025, 12, 31, 12, 0)), freed: gigabytes(2)),
        ]
        let rows = try self.rows(runs, now: rome.local(2026, 1, 5, 9, 0))
        XCTAssertEqual(rows.weeks.count, 1, "29 Dec to 4 Jan")
        XCTAssertEqual(rows.weeks[0].title, "Last week")
        XCTAssertEqual(rows.weeks[0].rows.count, 2)
        XCTAssertEqual(rows.weeks[0].totalText, "3.0 GB")

        let usStyle = TestCalendars.make("Europe/Rome", firstWeekday: 1)
        var weekOne = usStyle
        weekOne.minimumDaysInFirstWeek = 1
        let us = try self.rows(runs, now: rome.local(2026, 1, 5, 9, 0), calendar: weekOne)
        XCTAssertEqual(us.weeks.count, 1, "28 Dec to 3 Jan")
    }

    func testAWeekWithAClockChangeInItIsStillOneWeekAndItsRunsStayInIt() throws {
        // Rome puts the clocks forward on Sunday 29 March 2026 at 02:00
        let runs = [
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 3, 30, 0, 30)), freed: gigabytes(3)),
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 3, 29, 3, 30)), freed: gigabytes(2)),
            HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 3, 28, 23, 0)), freed: gigabytes(1)),
        ]
        let rows = try self.rows(runs, now: rome.local(2026, 4, 2, 9, 0))
        XCTAssertEqual(rows.weeks.map(\.title), ["This week", "Last week"])
        XCTAssertEqual(rows.weeks.map { $0.rows.count }, [1, 2])
        XCTAssertEqual(rows.weeks[1].start, rome.local(2026, 3, 23, 0, 0), "local midnight on Monday, whatever the offset")
    }

    func testAnOlderWeekIsWrittenAsItsFirstAndLastDayAndWithTheYearWhenItIsOld() throws {
        let recent = try rows([HistoryJSON.run(finished: TestTime.iso(rome.local(2026, 9, 1, 12, 0)))])
        XCTAssertEqual(recent.weeks[0].title, "31 Aug \u{2013} 6 Sep")
        let old = try rows([HistoryJSON.run(finished: TestTime.iso(rome.local(2025, 10, 15, 10, 0)))])
        XCTAssertEqual(old.weeks[0].title, "13 Oct 2025 \u{2013} 19 Oct 2025")
    }

    func testRunsAreNewestFirstWhateverOrderTheyCameIn() throws {
        let runs = [
            HistoryJSON.run(finished: "2026-10-09T07:41:00Z", freed: gigabytes(2)),
            HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: gigabytes(3)),
            HistoryJSON.run(finished: "2026-10-14T12:20:00Z", freed: gigabytes(1)),
        ]
        let rows = try self.rows(runs)
        XCTAssertEqual(rows.weeks.flatMap(\.rows).map(\.timeText), ["14:20", "14:06", "09:41"])
        XCTAssertEqual(rows.weeks.map(\.id).count, Set(rows.weeks.map(\.id)).count)
        XCTAssertEqual(rows.weeks.flatMap(\.rows).map(\.id), try report(runs).asOf(now).runs.map(\.id), "the ids the chart's markers use")
    }

    // MARK: the footnote, empty, and what is not believed

    func testTheFootnoteCountsLinesOfTheHistoryThatCouldNotBeRead() throws {
        XCTAssertNil(try rows([HistoryJSON.run(finished: "2026-10-14T12:06:00Z")]).footnote)
        XCTAssertEqual(try rows([], unreadable: 1).footnote, "1 line of the history could not be read.")
        // two from cmm, one that this app could not use, and one dated after now
        let runs = [HistoryJSON.run(finished: "2026-10-14T12:06:00Z", freed: -1), HistoryJSON.run(finished: "2026-10-16T12:06:00Z")]
        XCTAssertEqual(try rows(runs, unreadable: 2).footnote, "4 lines of the history could not be read.")
    }

    func testNothingFromTheFutureIsListed() throws {
        let rows = try self.rows([
            HistoryJSON.run(finished: TestTime.iso(now.addingTimeInterval(1)), freed: gigabytes(9)),
            HistoryJSON.run(finished: TestTime.iso(now), freed: gigabytes(1)),
        ])
        XCTAssertEqual(rows.weeks.flatMap(\.rows).count, 1, "exactly now is in, a second ahead is not")
        XCTAssertEqual(rows.weeks[0].totalText, "1.0 GB")
    }

    func testNoRunsIsAnEmptyListWithNoFootnote() throws {
        let rows = try self.rows([])
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(rows.weeks, [])
        XCTAssertNil(rows.footnote)
    }

    // MARK: a lot of them

    func testTenThousandRunsMakeATenThousandRowListWithoutAnOverflow() throws {
        // one a second, so they all land in one week: ten thousand runs of a petabyte are more than an Int64 can hold
        let start = rome.local(2026, 10, 12, 0, 0)
        let runs = (0..<10_000).map { index in
            HistoryJSON.run(
                finished: TestTime.iso(start.addingTimeInterval(Double(index))), freed: HistoryLimits.maxBytes,
                before: 0, after: 0, items: [HistoryJSON.item(bytes: HistoryLimits.maxBytes)]
            )
        }
        let rows = try self.rows(runs)
        XCTAssertEqual(rows.weeks.count, 1)
        let all = rows.weeks.flatMap(\.rows)
        XCTAssertEqual(all.count, 10_000)
        XCTAssertEqual(Set(all.map(\.id)).count, 10_000)
        XCTAssertEqual(rows.weeks[0].freedBytes, Int64.max, "the week stops at the largest number")
        XCTAssertFalse(rows.weeks[0].totalText.contains("-"), rows.weeks[0].totalText)
    }

    func testManyWeeksOfManyRunsAreGroupedWithoutAFuss() throws {
        let start = rome.local(2025, 1, 1, 0, 0)
        let runs = (0..<10_000).map { index in
            HistoryJSON.run(finished: TestTime.iso(start.addingTimeInterval(Double(index) * 3_000)), freed: 1_000)
        }
        let rows = try self.rows(runs)
        XCTAssertEqual(rows.weeks.flatMap(\.rows).count, 10_000)
        XCTAssertEqual(Set(rows.weeks.map(\.id)).count, rows.weeks.count)
        XCTAssertTrue(rows.weeks.allSatisfy { !$0.rows.isEmpty })
    }
}
