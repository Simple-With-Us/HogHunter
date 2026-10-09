import XCTest

@testable import HogHunter

// Recent Runs lists cleaning runs only, sums the five minute checks up in one
// line, and marks a partial run.  Board f13bbbe7, issue 115.
//
// Nothing here runs the real script: the one store built reads files in a
// temporary folder and takes a launcher that fails the test if it is called.

private typealias F = CompanionVacuumRunFixtures

/// A calendar with a fixed zone, so "today" and "5:40pm" mean the same on every machine.
private let chicago: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    return calendar
}()

/// A moment in `chicago`.
private func moment(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10) -> Date {
    chicago.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func epoch(_ date: Date) -> Double { date.timeIntervalSince1970 }

// MARK: - The run record

final class RoboticVacuumRunOutcomeTests: XCTestCase {
    private func decode(_ json: String) throws -> RoboticVacuumRun {
        try JSONDecoder().decode(RoboticVacuumRun.self, from: Data(json.utf8))
    }

    func testARunKeepsTheOutcomeTheEngineRecorded() throws {
        let run = try decode("""
        {"run_id": "r1", "trigger": "full", "started_at": 100, "ended_at": 200, "bytes_freed": 5,
         "exit_code": 0, "outcome": "partial", "steps": []}
        """)
        XCTAssertEqual(run.outcome, "partial")
        XCTAssertEqual(run.exitCode, 0, "a partial run exits 0, which is why the exit code cannot show it")
        XCTAssertEqual(run.resolvedOutcome, "partial")
    }

    /// Every row the engine wrote before the field existed has no `outcome`.  Such a row must still
    /// decode: the store reads each row with `try?`, so a row that failed to decode would vanish.
    func testARowFromBeforeTheFieldStillDecodesAndIsJudgedByItsExitCode() throws {
        let clean = try decode(#"{"run_id": "r1", "trigger": "janitor", "started_at": 1, "ended_at": 2, "bytes_freed": 0, "exit_code": 0, "steps": []}"#)
        let failed = try decode(#"{"run_id": "r2", "trigger": "janitor", "started_at": 1, "ended_at": 2, "bytes_freed": 0, "exit_code": 1, "steps": []}"#)
        XCTAssertNil(clean.outcome)
        XCTAssertEqual(clean.resolvedOutcome, "ok")
        XCTAssertEqual(failed.resolvedOutcome, "failed")
    }

    func testTheOutcomeAndTheExitCodeResolveTogether() {
        let cases: [(exit: Int, outcome: String?, expected: CompanionVacuumRunResult)] = [
            (0, "ok", .ok),
            (0, nil, .ok),
            (0, "partial", .partial),
            (0, "failed", .failed),
            (1, "failed", .failed),
            (1, nil, .failed),
            (1, "ok", .failed),
            (1, "partial", .failed),
            (0, "some-future-word", .ok),
            (0, "", .ok),
            (0, "Partial", .ok),
        ]
        for item in cases {
            XCTAssertEqual(
                CompanionVacuumRunResult.resolve(exitCode: item.exit, outcome: item.outcome), item.expected,
                "exit \(item.exit), outcome \(item.outcome ?? "nil")"
            )
        }
        XCTAssertEqual(F.run("p", "full", ended: 1, outcome: "partial").resolvedOutcome, "partial")
        XCTAssertEqual(F.run("x", "full", ended: 1, exit: 3, outcome: "partial").resolvedOutcome, "failed", "a non-zero exit is always failed")
    }

    func testOnlyPartialAndFailedCarryAMark() {
        XCTAssertNil(CompanionVacuumRunResult.ok.markLabel)
        XCTAssertEqual(CompanionVacuumRunResult.partial.markLabel, "Partial")
        XCTAssertEqual(CompanionVacuumRunResult.failed.markLabel, "Failed")
        XCTAssertNotEqual(CompanionVacuumRunResult.partial.markLabel, CompanionVacuumRunResult.failed.markLabel)
    }

    // MARK: Which runs are cleaning runs

    func testAQuietWatchTickIsACheckAndNotACleaningRun() {
        let quiet = F.run("w", "watch", ended: 10, steps: [F.step("resource_sample", reason: "within limits")])
        XCTAssertTrue(quiet.isCheck)
        XCTAssertTrue(quiet.isCheckOnly)
        XCTAssertFalse(quiet.isCleaningRun)
        XCTAssertEqual(quiet.displayTrigger, "watch")
        let bare = F.run("w0", "watch", ended: 10)
        XCTAssertTrue(bare.isCheck && !bare.isCleaningRun, "a tick that recorded no step is still a quiet check")
    }

    /// The engine records a pressure clean inside the watch tick that asked for it, under trigger
    /// "watch".  On the author's Mac, 7 of the 20 ticks in one day did.  They cleaned, or tried to, so
    /// they belong in the list, and they say "pressure" because that is what their steps ran as.
    func testAWatchTickThatWentOnToCleanIsACleaningRunListedAsPressure() {
        let escalated = F.run("w", "watch", ended: 10, exit: 1, steps: [
            F.step("resource_sample"), F.step("hoghunter_reclaim", "failed", reason: "timed out"), F.step("grok_sessions"),
        ])
        XCTAssertTrue(escalated.isCleaningRun)
        XCTAssertTrue(escalated.escalatedToCleaning)
        XCTAssertTrue(escalated.isCheck, "it took its look too")
        XCTAssertEqual(escalated.displayTrigger, "pressure")
    }

    func testATickThatFoundTheLockHeldIsNeitherACheckNorACleaningRun() {
        let skipped = F.run("w", "watch", ended: 10, steps: [F.step("housekeeper_lock", "skipped", reason: "lock held")])
        XCTAssertFalse(skipped.isCheck)
        XCTAssertFalse(skipped.isCleaningRun)
    }

    func testEveryOtherKindOfRunIsACleaningRun() {
        for trigger in ["janitor", "full", "manual", "pressure"] {
            let run = F.run("r", trigger, ended: 10, steps: [F.step("resource_sample")])
            XCTAssertTrue(run.isCleaningRun, trigger)
            XCTAssertFalse(run.isCheck, trigger)
            XCTAssertEqual(run.displayTrigger, trigger)
        }
    }
}

// MARK: - The list

final class RoboticVacuumCleaningRunsListTests: XCTestCase {
    func testAnEscalatedTickIsInTheListAsPressureWithItsOutcome() {
        let history = [
            F.run("w2", "watch", ended: 300),
            F.run("w1", "watch", ended: 200, steps: [F.step("resource_sample"), F.step("hoghunter_reclaim", "ran")], outcome: "ok"),
            F.run("j1", "janitor", ended: 100),
        ]
        let runs = CompanionVacuum.recentRuns(from: history)
        XCTAssertEqual(runs.map(\.runId), ["w1", "j1"])
        XCTAssertEqual(runs.map(\.trigger), ["pressure", "janitor"])
    }

    func testThePartialRunTravelsWithItsOutcomeAndMarksOnBothScreens() {
        let history = [
            F.run("p1", "full", ended: 300, freed: 4_096, outcome: "partial"),
            F.run("f1", "janitor", ended: 200, exit: 1, outcome: "failed"),
            F.run("o1", "janitor", ended: 100, outcome: "ok"),
            F.run("old", "janitor", ended: 50),
            F.run("oldbad", "janitor", ended: 40, exit: 1),
        ]
        let runs = CompanionVacuum.recentRuns(from: history)
        XCTAssertEqual(runs.map(\.outcome), ["partial", "failed", "ok", "ok", "failed"], "the old rows are resolved by the Mac from their exit codes")
        XCTAssertEqual(runs.map(\.result), [.partial, .failed, .ok, .ok, .failed])
        XCTAssertEqual(runs.map { $0.result.markLabel }, ["Partial", "Failed", nil, nil, "Failed"])
        XCTAssertEqual(runs[0].exitCode, 0, "the exit code alone says clean: the outcome is what shows the mark")
    }

    func testTheHeadlineLastRunCountsAnEscalatedTickAsACleaningRun() throws {
        let escalated = F.run("w1", "watch", ended: 300, steps: [F.step("resource_sample"), F.step("hoghunter_reclaim", "failed", reason: "timed out")])
        let janitor = F.run("j1", "janitor", ended: 100, freed: 9)
        let built = try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: escalated), history: [escalated, janitor], isRunning: false, includeSteps: true
        ))
        XCTAssertEqual(built.lastRunTrigger, "pressure")
        XCTAssertEqual(built.steps?.map(\.stepId), ["resource_sample", "hoghunter_reclaim"], "the escalated tick's own steps, in the Mac's order")
        XCTAssertEqual(built.steps?.map(\.statusLabel), ["Done", "Failed"])
    }

    // MARK: The phone filters for an older Mac too

    func testThePhoneLeavesWatchTicksOutOfAnOlderMacsList() {
        var status = CompanionVacuumStatus(health: "healthy", displayHealth: "On schedule", launchdLoaded: true, isRunning: false)
        XCTAssertNil(status.cleaningRuns, "no list at all is unknown, not empty")
        status.recentRuns = [
            CompanionVacuumRun(runId: "w", trigger: "watch", endedAt: nil, bytesFreed: 0, exitCode: 0, durationSeconds: 0),
            CompanionVacuumRun(runId: "j", trigger: "janitor", endedAt: nil, bytesFreed: 0, exitCode: 0, durationSeconds: 0),
        ]
        XCTAssertEqual(status.cleaningRuns?.map(\.runId), ["j"])
        status.recentRuns = [CompanionVacuumRun(runId: "w", trigger: "watch", endedAt: nil, bytesFreed: 0, exitCode: 0, durationSeconds: 0)]
        XCTAssertEqual(status.cleaningRuns, [], "a list of only checks is an empty list, which reads No cleaning runs recorded yet")
    }
}

// MARK: - The watch summary

final class RoboticVacuumWatchSummaryTests: XCTestCase {
    private func check(_ id: String, at date: Date, took: Double = 5) -> RoboticVacuumRun {
        RoboticVacuumRun(
            runId: id, trigger: "watch", startedAt: epoch(date) - took, endedAt: epoch(date), bytesFreed: 0, exitCode: 0,
            steps: [F.step("resource_sample")]
        )
    }

    private func history(checks: [Date], with others: [RoboticVacuumRun] = []) -> [RoboticVacuumRun] {
        let all = checks.enumerated().map { check("w\($0.offset)", at: $0.element) } + others
        return all.sorted { $0.endedAt > $1.endedAt }
    }

    func testTheNewestCheckAndTodaysCountComeFromTheHistory() throws {
        // A history that starts yesterday evening, so it reaches back past midnight.
        let now = moment(9, 17, 45)
        let checks = [moment(8, 23, 55), moment(9, 0, 5), moment(9, 8, 0), moment(9, 17, 40)]
        let watch = try XCTUnwrap(CompanionVacuum.watch(from: history(checks: checks), now: now, calendar: chicago))
        XCTAssertEqual(watch.lastCheckAt, moment(9, 17, 40))
        XCTAssertEqual(watch.checksToday, 3, "the 11:55pm check was yesterday's")
        XCTAssertNil(watch.countedSince, "the history reaches back before midnight, so the count is for the whole day")
    }

    func testOtherRunsAndATickThatFoundTheLockHeldAreNotChecks() throws {
        let now = moment(9, 17, 45)
        let others = [
            F.run("j", "janitor", ended: epoch(moment(9, 17, 0))),
            F.run("f", "full", ended: epoch(moment(9, 16, 0))),
            F.run("lock", "watch", ended: epoch(moment(9, 17, 30)), steps: [F.step("housekeeper_lock", "skipped")]),
        ]
        let checks = [moment(8, 12, 0), moment(9, 17, 40)]
        let watch = try XCTUnwrap(CompanionVacuum.watch(from: history(checks: checks, with: others), now: now, calendar: chicago))
        XCTAssertEqual(watch.checksToday, 1, "a janitor run, a full run and a tick that found the lock held are not checks")
        XCTAssertEqual(watch.lastCheckAt, moment(9, 17, 40))
    }

    /// The engine keeps a bounded history.  Late on a long day it may start after midnight, and a count
    /// from it is low.  "Today" would then be false, so the summary says where the history starts.
    func testAHistoryThatStartsAfterMidnightSaysSinceInsteadOfToday() throws {
        let now = moment(9, 21, 0)
        let checks = [moment(9, 7, 30), moment(9, 8, 0), moment(9, 20, 55)]
        let watch = try XCTUnwrap(CompanionVacuum.watch(from: history(checks: checks), now: now, calendar: chicago))
        XCTAssertEqual(watch.checksToday, 3)
        XCTAssertEqual(watch.countedSince, moment(9, 7, 30).addingTimeInterval(-5), "the oldest row started five seconds before it ended")
        XCTAssertEqual(watch.summary(now: now, calendar: chicago), "Last check 8:55pm \u{00B7} 3 checks since 7:29am")
    }

    func testNoCheckOnRecordMeansNoSummary() {
        XCTAssertNil(CompanionVacuum.watch(from: [], now: moment(9, 12, 0), calendar: chicago))
        XCTAssertNil(CompanionVacuum.watch(from: [F.run("j", "janitor", ended: epoch(moment(9, 1, 0)))], now: moment(9, 12, 0), calendar: chicago))
    }

    func testAnEscalatedTickCountsAsACheckToo() throws {
        let escalated = F.run("w", "watch", ended: epoch(moment(9, 11, 0)), steps: [F.step("resource_sample"), F.step("hoghunter_reclaim", "failed")])
        let older = check("w0", at: moment(8, 11, 0))
        let watch = try XCTUnwrap(CompanionVacuum.watch(from: [escalated, older], now: moment(9, 12, 0), calendar: chicago))
        XCTAssertEqual(watch.checksToday, 1, "it ran the disk and memory check before it cleaned")
    }

    func testTheAnswerDoesNotDependOnTheOrderOfTheHistory() throws {
        // The store hands history over newest first, but a caller that does not must not change the answer.
        let now = moment(9, 12, 0)
        let ordered = history(checks: [moment(8, 12, 0), moment(9, 1, 0), moment(9, 11, 55)])
        let shuffled = [ordered[1], ordered[2], ordered[0]]
        XCTAssertEqual(
            CompanionVacuum.watch(from: ordered, now: now, calendar: chicago),
            CompanionVacuum.watch(from: shuffled, now: now, calendar: chicago)
        )
    }

    // MARK: The line

    func testTheLineReadsLikeTheOwnersClock() {
        let now = moment(9, 18, 0)
        let line = CompanionVacuumWatch(lastCheckAt: moment(9, 17, 40), checksToday: 23).summary(now: now, calendar: chicago)
        XCTAssertEqual(line, "Last check 5:40pm \u{00B7} 23 checks today")
        XCTAssertFalse(line.contains("CDT") || line.contains("CST") || line.contains("PM") || line.contains("17:"), "12-hour, lower-case, no zone")
    }

    func testMorningAndNoonAndMidnightUseAmAndPm() {
        let now = moment(9, 18, 0)
        func line(_ at: Date) -> String { CompanionVacuumWatch(lastCheckAt: at, checksToday: 2).summary(now: now, calendar: chicago) }
        XCTAssertTrue(line(moment(9, 0, 5)).hasPrefix("Last check 12:05am "))
        XCTAssertTrue(line(moment(9, 9, 0)).hasPrefix("Last check 9:00am "))
        XCTAssertTrue(line(moment(9, 12, 0)).hasPrefix("Last check 12:00pm "))
        XCTAssertTrue(line(moment(9, 23, 59)).hasPrefix("Last check 11:59pm "))
    }

    func testTheLineIsThePhonesWhateverItsOwnClockSetting() {
        // Fixed locale and symbols: a phone set to a 24-hour clock or another language reads the same.
        let line = CompanionVacuumWatch(lastCheckAt: moment(9, 17, 40), checksToday: 1).summary(now: moment(9, 18, 0), calendar: {
            var calendar = chicago
            calendar.locale = Locale(identifier: "de_DE")
            return calendar
        }())
        XCTAssertEqual(line, "Last check 5:40pm \u{00B7} 1 check today")
    }

    func testACheckFromAnEarlierDaySaysWhichDayAndTodayCountsNone() {
        let now = moment(9, 8, 0)
        XCTAssertEqual(
            CompanionVacuumWatch(lastCheckAt: moment(8, 23, 55), checksToday: 0).summary(now: now, calendar: chicago),
            "Last check yesterday 11:55pm \u{00B7} 0 checks today"
        )
        XCTAssertEqual(
            CompanionVacuumWatch(lastCheckAt: moment(6, 14, 5), checksToday: 0).summary(now: now, calendar: chicago),
            "Last check Oct 6 2:05pm \u{00B7} 0 checks today"
        )
    }

    func testTheCountIsSingularForOne() {
        let now = moment(9, 18, 0)
        XCTAssertEqual(
            CompanionVacuumWatch(lastCheckAt: moment(9, 17, 40), checksToday: 1, countedSince: moment(9, 17, 40)).summary(now: now, calendar: chicago),
            "Last check 5:40pm \u{00B7} 1 check since 5:40pm"
        )
    }

    func testWithoutALastCheckTheLineSaysSo() {
        XCTAssertEqual(
            CompanionVacuumWatch().summary(now: moment(9, 18, 0), calendar: chicago),
            "No checks recorded yet \u{00B7} 0 checks today"
        )
    }

    // MARK: The wire

    func testTheSummarySurvivesTheWireAndAnEmptyOneStillDecodes() throws {
        let watch = CompanionVacuumWatch(lastCheckAt: moment(9, 17, 40), checksToday: 23, countedSince: moment(9, 7, 0))
        let decoded = try CompanionJSON.decoder().decode(CompanionVacuumWatch.self, from: CompanionJSON.encoder().encode(watch))
        XCTAssertEqual(decoded, watch)
        // A payload with nothing in it decodes to the defaults instead of throwing.
        let empty = try CompanionJSON.decoder().decode(CompanionVacuumWatch.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, CompanionVacuumWatch())
        let onlyACount = try CompanionJSON.decoder().decode(CompanionVacuumWatch.self, from: Data(#"{"checksToday": 4}"#.utf8))
        XCTAssertEqual(onlyACount.checksToday, 4)
        XCTAssertNil(onlyACount.lastCheckAt)
    }

    func testTheSummaryCarriesNoStepText() throws {
        let janitor = F.run("j", "janitor", ended: epoch(moment(9, 10, 0)), steps: [F.step("janitor_worktree_retire", "skipped", reason: "Kept lane-claude-secret-project.")])
        let status = try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: janitor),
            history: [check("w", at: moment(9, 11, 0)), janitor],
            isRunning: false, includeSteps: false, now: moment(9, 12, 0), calendar: chicago
        ))
        let wire = String(decoding: try CompanionJSON.encoder().encode(status), as: UTF8.self)
        XCTAssertTrue(wire.contains("checksToday"))
        XCTAssertFalse(wire.contains("lane-"))
        XCTAssertFalse(wire.contains("janitor_worktree_retire"))
    }

    func testAnOldPayloadWithNoOutcomeAndNoWatchDecodesWithDefaults() throws {
        let oldRun = Data(#"{"runId":"r1","trigger":"janitor","bytesFreed":5,"exitCode":1,"durationSeconds":3}"#.utf8)
        let run = try CompanionJSON.decoder().decode(CompanionVacuumRun.self, from: oldRun)
        XCTAssertNil(run.outcome)
        XCTAssertEqual(run.result, .failed, "no outcome: the exit code decides")
        XCTAssertFalse(run.succeeded)
        let oldPartial = Data(#"{"runId":"r2","trigger":"full","bytesFreed":5,"exitCode":0,"durationSeconds":3}"#.utf8)
        XCTAssertEqual(try CompanionJSON.decoder().decode(CompanionVacuumRun.self, from: oldPartial).result, .ok, "an older Mac cannot tell a partial run, so none is flagged")
        let newPartial = Data(#"{"runId":"r3","trigger":"full","bytesFreed":5,"exitCode":0,"durationSeconds":3,"outcome":"partial"}"#.utf8)
        let decoded = try CompanionJSON.decoder().decode(CompanionVacuumRun.self, from: newPartial)
        XCTAssertEqual(decoded.result, .partial)
        XCTAssertFalse(decoded.succeeded)
    }
}

// MARK: - The store reads the whole history

@MainActor
final class RoboticVacuumStoreHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-vacuum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func store(_ directory: URL) -> RoboticVacuumStore {
        RoboticVacuumStore(supportDirectory: directory, repoRoot: directory, launcher: { _ in
            XCTFail("a test must not launch the script")
            return true
        })
    }

    /// The store once read the newest 30 rows, which a day of five minute checks fills in two and a half
    /// hours.  The list and the count need the file the engine keeps, all of it.
    func testTheStoreReadsEveryRowOfAFullHistoryNewestFirstAndKeepsOldRows() throws {
        let support = try directory()
        // Oldest first, as the engine writes it.  Every sixth row is a janitor run; the first 100 predate `outcome`.
        let base = 1_760_000_000
        var rows: [String] = []
        for n in 0..<500 {
            let trigger = n % 6 == 0 ? "janitor" : "watch"
            let outcome = n < 100 ? "" : #","outcome": "\#(n == 498 ? "partial" : "ok")""#
            rows.append(#"{"run_id": "r\#(n)", "trigger": "\#(trigger)", "started_at": \#(base + n * 300), "ended_at": \#(base + n * 300 + 5), "exit_code": 0, "bytes_freed": 0\#(outcome), "steps": []}"#)
        }
        try ("[" + rows.joined(separator: ",") + "]").write(to: support.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        let store = store(support)
        XCTAssertEqual(store.history.count, 500, "no row dropped, old rows without an outcome included")
        XCTAssertEqual(store.history.first?.runId, "r499", "newest first")
        XCTAssertEqual(store.history.last?.runId, "r0")
        XCTAssertGreaterThan(RoboticVacuumStore.maxHistoryRuns, 500, "room above what the engine keeps")

        let listed = CompanionVacuum.recentRuns(from: store.history)
        XCTAssertEqual(listed.count, 20)
        XCTAssertTrue(listed.allSatisfy { $0.trigger == "janitor" })
        XCTAssertEqual(listed.first?.runId, "r498", "the newest janitor run, not one of the checks after it")
        XCTAssertEqual(listed.first?.outcome, "partial", "the outcome the engine wrote reaches the list")
        XCTAssertEqual(listed.dropFirst().first?.outcome, "ok")
        XCTAssertEqual(listed.last?.outcome, "ok", "a row from before the field reads as ok, by its exit code")
    }

    func testAStoreWithNoHistoryFileHasNoRunsAndNoSummary() throws {
        let store = store(try directory())
        XCTAssertEqual(store.history, [])
        XCTAssertNil(CompanionVacuum.watch(from: store.history, now: Date()))
        XCTAssertEqual(CompanionVacuum.recentRuns(from: store.history), [])
    }
}
