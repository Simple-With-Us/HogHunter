import XCTest
@testable import HogHunter

/// Covers the runner that makes the regimen actually happen.
///
/// The regimen was fully built and never ran: `CleanRegimenRunner` was never
/// instantiated, so the schedule it carried was never started, and nothing in
/// the app ever asked for a run.  These tests cover the decisions that decide
/// whether a run happens at all -- is it due, is it allowed to start, and does
/// it step aside when another cleaner is already working.
///
/// None of these tests scan the real disk or delete anything: every run here
/// uses a regimen with no enabled rules, which returns before the scan.
@MainActor
final class CleanRegimenRunnerTests: XCTestCase {

    private var root: URL!
    private var lockPath: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HogHunterRunnerTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockPath = root.appendingPathComponent(".housekeeper.lock", isDirectory: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suite = "hoghunter.tests.runner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeRunner(now: Date = Date(), defaults: UserDefaults? = nil) -> CleanRegimenRunner {
        CleanRegimenRunner(
            now: { now },
            defaults: defaults ?? makeDefaults(),
            lockProvider: { HousekeeperLock(path: self.lockPath) }
        )
    }

    /// A regimen that is on but may delete nothing, so a test can run the
    /// scheduler's decisions without touching the disk.
    private func makeRegimen(enabled: Bool = true, intervalHours: Double = 4, rules: Set<String> = []) -> CleanRegimen {
        // `avoidDuringBuilds` is off so a compile running on the host cannot
        // turn these into "A build is running" skips: the order of the
        // runner's checks is the build first, the lock second.
        CleanRegimen(
            isEnabled: enabled,
            intervalHours: intervalHours,
            avoidDuringBuilds: false,
            enabledRules: rules
        )
    }

    // MARK: - Is a run due

    func testARegimenThatIsOffIsNeverDue() {
        let runner = makeRunner()
        XCTAssertFalse(runner.isDue(regimen: makeRegimen(enabled: false), lastRunAt: nil))
    }

    func testAnEnabledRegimenWithNoPreviousRunIsDue() {
        let runner = makeRunner()
        XCTAssertTrue(runner.isDue(regimen: makeRegimen(enabled: true), lastRunAt: nil))
    }

    func testAnEnabledRegimenIsNotDueUntilItsIntervalHasPassed() {
        let now = Date()
        let runner = makeRunner(now: now)
        let regimen = makeRegimen(enabled: true, intervalHours: 4)

        XCTAssertFalse(runner.isDue(regimen: regimen, lastRunAt: now.addingTimeInterval(-3 * 3600)))
        XCTAssertTrue(runner.isDue(regimen: regimen, lastRunAt: now.addingTimeInterval(-5 * 3600)))
    }

    // MARK: - Running

    func testAnOutOfRangeRegimenIsClampedRatherThanRejected() {
        // A regimen edited by hand, or written by a future build, must never
        // wedge the scheduler.  The stored values are clamped into a runnable
        // shape rather than refused, so a bad value costs a wrong number and
        // not a regimen that never runs again.
        var regimen = makeRegimen(enabled: true)
        regimen.intervalHours = 0
        regimen.targetsPerChunk = 0
        regimen.pressuredTargetsPerChunk = -5
        regimen.chunkPauseSeconds = -1

        let clamped = regimen.sanitized()
        XCTAssertTrue(clamped.isValid)
        XCTAssertEqual(clamped.intervalHours, 24)
        XCTAssertEqual(clamped.targetsPerChunk, 1)
        XCTAssertEqual(clamped.pressuredTargetsPerChunk, 1)
        XCTAssertEqual(clamped.chunkPauseSeconds, 0)
    }

    func testAnEnabledRegimenWithAnUnreachableIntervalIsStillRunnable() async {
        // The runner sanitizes before it checks, so an interval past the
        // ceiling is pulled back to it rather than stopping the regimen.
        let runner = makeRunner()
        var regimen = makeRegimen(enabled: true, intervalHours: 24 * 365)
        regimen = regimen.sanitized()
        XCTAssertEqual(regimen.intervalHours, 24 * 14)
        await runner.runNow(regimen: regimen)?.value
        XCTAssertFalse(runner.isRunning)
    }

    func testTheRunnerWaitsWhenAnotherCleanupHoldsTheLock() async {
        // The Python reclaim ticks and the in-app regimen delete the same
        // kinds of things, so they must not run at the same time.  The lock is
        // the same one the Python engine takes.
        let peer = HousekeeperLock(path: lockPath)
        XCTAssertEqual(peer.acquire(), .acquired)

        let runner = makeRunner()
        await runner.runNow(regimen: makeRegimen())?.value

        XCTAssertEqual(runner.lastRun?.skippedReason,
                       "Another cleanup is already running, so the regimen waited.")
        // The peer's lock is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        peer.release()
    }

    func testWaitingForTheLockDoesNotStartTheIntervalClock() async {
        // A run that stepped aside did not happen.  Recording it would push a
        // 24-hour regimen a whole day out for a collision that lasts minutes,
        // so the stored clock stays where it was and the next check retries.
        let key = "hoghunter.cleaner.regimen.lastRunAt"
        let now = Date()
        let defaults = makeDefaults()
        let lastRun = now.addingTimeInterval(-5 * 3600)
        defaults.set(lastRun, forKey: key)
        let regimen = makeRegimen(enabled: true, intervalHours: 4)

        let peer = HousekeeperLock(path: lockPath)
        XCTAssertEqual(peer.acquire(), .acquired)
        defer { peer.release() }

        let runner = makeRunner(now: now, defaults: defaults)
        await runner.runNow(regimen: regimen)?.value

        XCTAssertEqual(runner.lastRun?.skippedReason,
                       "Another cleanup is already running, so the regimen waited.")
        XCTAssertEqual(defaults.object(forKey: key) as? Date, lastRun,
                       "the interval's clock did not restart")
        XCTAssertTrue(runner.isDue(regimen: regimen, lastRunAt: defaults.object(forKey: key) as? Date),
                      "the run is still due, so the next check retries")
        // The panel says when the retry is, not a whole interval from now.
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(15 * 60).timeIntervalSince1970,
                       accuracy: 1)
    }

    func testARunThatFinishedStartsTheIntervalClock() async {
        // The counterpart: a run that decided (here, "no rules enabled") is a
        // run, and the next one is a full interval out.
        let key = "hoghunter.cleaner.regimen.lastRunAt"
        let now = Date()
        let defaults = makeDefaults()
        let regimen = makeRegimen(enabled: true, intervalHours: 4)

        let runner = makeRunner(now: now, defaults: defaults)
        await runner.runNow(regimen: regimen)?.value

        XCTAssertEqual(runner.lastRun?.skippedReason, "No cleaning rules are enabled.")
        XCTAssertEqual((defaults.object(forKey: key) as? Date)?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(4 * 3600).timeIntervalSince1970,
                       accuracy: 1)
    }

    func testACancelledRunDoesNotStartTheIntervalClock() async {
        // The app is quitting or the schedule was stopped: the run did not
        // finish, so the next launch finds it still due.
        let key = "hoghunter.cleaner.regimen.lastRunAt"
        let defaults = makeDefaults()
        let runner = makeRunner(defaults: defaults)

        let task = runner.runNow(regimen: makeRegimen(enabled: true, intervalHours: 4))
        task?.cancel()
        await task?.value

        XCTAssertNil(defaults.object(forKey: key), "a cancelled run is not a completed one")
        XCTAssertFalse(runner.isRunning)
    }

    func testTheRunnerTakesTheHousekeeperLockAndGivesItBack() async {
        // A stale lock from a process that died.  If the runner takes it, it
        // removes it on the way out; if it does not, the directory survives.
        try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-(HousekeeperLock.defaultStaleMinutes + 5) * 60)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lockPath.path)

        let runner = makeRunner()
        await runner.runNow(regimen: makeRegimen())?.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path),
                       "the runner took the lock and released it")
    }

    func testARegimenWithNoRulesReclaimsNothingAndSaysSo() async {
        let runner = makeRunner()
        await runner.runNow(regimen: makeRegimen(enabled: true, rules: []))?.value

        XCTAssertEqual(runner.lastRun?.skippedReason, "No cleaning rules are enabled.")
        XCTAssertEqual(runner.lastRun?.itemsRemoved, 0)
        XCTAssertEqual(runner.lastRun?.bytesReclaimed, 0)
        XCTAssertFalse(runner.isRunning)
    }

    func testTwoRunsDoNotOverlap() async {
        let runner = makeRunner()
        let first = runner.runNow(regimen: makeRegimen())
        XCTAssertNotNil(first)

        // A second run while the first is in flight is refused rather than
        // queued, so two regimens cannot reclaim over each other.
        XCTAssertNil(runner.runNow(regimen: makeRegimen()))
        await first?.value
    }

    // MARK: - Scheduling

    func testTurningTheRegimenOnSchedulesItOneIntervalOut() {
        // The owner flips the switch; the first run is one interval out, not
        // a clean the instant the switch flips.
        let now = Date()
        let runner = makeRunner(now: now)
        runner.scheduleFromNow(regimen: makeRegimen(enabled: true, intervalHours: 4))

        let expected = now.addingTimeInterval(4 * 3600).timeIntervalSince1970
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0, expected, accuracy: 1)

        // And a run that was just scheduled is not due yet.
        XCTAssertFalse(runner.isDue(regimen: makeRegimen(enabled: true, intervalHours: 4), lastRunAt: now))
    }

    func testARegimenThatIsOffHasNoNextRun() {
        let runner = makeRunner()
        runner.scheduleFromNow(regimen: makeRegimen(enabled: false))
        XCTAssertNil(runner.nextRunDate)

        runner.refreshSchedule(regimen: makeRegimen(enabled: false))
        XCTAssertNil(runner.nextRunDate)
    }

    func testRefreshingTheScheduleKeepsTheStoredClock() {
        let now = Date()
        let runner = makeRunner(now: now)
        runner.scheduleFromNow(regimen: makeRegimen(enabled: true, intervalHours: 12))
        let first = runner.nextRunDate

        // The clock does not move when the schedule is merely re-read.
        runner.refreshSchedule(regimen: makeRegimen(enabled: true, intervalHours: 12))
        XCTAssertEqual(runner.nextRunDate, first)
    }

    // MARK: - The regimen's own conditions

    func testAScheduledRunWaitsUntilTheMacHasBeenIdleLongEnough() {
        var regimen = makeRegimen(enabled: true)
        regimen.requireIdleMinutes = 30

        XCTAssertEqual(
            CleanRegimenRunner.scheduleBlocker(regimen: regimen, idleSeconds: 5 * 60, panelOpen: false),
            "Waiting for the Mac to be idle."
        )
        XCTAssertNil(
            CleanRegimenRunner.scheduleBlocker(regimen: regimen, idleSeconds: 31 * 60, panelOpen: false)
        )
    }

    func testTheSchedulerHoldsADueRunThatIsNotIdleEnough() {
        // `scheduleBlocker` is only half of the gate: the other half is that
        // `tick()` asks it.  Take that call out and every other test here
        // stays green while files are deleted on a Mac someone is using.
        let key = "hoghunter.cleaner.regimen.lastRunAt"
        let now = Date()
        let defaults = makeDefaults()
        var regimen = makeRegimen(enabled: true, intervalHours: 4)
        regimen.requireIdleMinutes = 30
        let runner = CleanRegimenRunner(
            now: { now },
            defaults: defaults,
            lockProvider: { HousekeeperLock(path: self.lockPath) },
            idleSeconds: { 60 }
        )

        let task = runner.tick(regimen: regimen)

        XCTAssertNil(task, "no run was started")
        XCTAssertNil(runner.lastRun)
        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(defaults.object(forKey: key), "a held run records nothing")
        XCTAssertEqual(runner.waitingReason, "Waiting for the Mac to be idle.")
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(15 * 60).timeIntervalSince1970,
                       accuracy: 1)
    }

    func testTheSchedulerStartsADueRunOnceTheMacIsIdleAndClearsTheHold() async {
        let now = Date()
        var regimen = makeRegimen(enabled: true, intervalHours: 4)
        regimen.requireIdleMinutes = 30
        var idle: TimeInterval = 60
        let runner = CleanRegimenRunner(
            now: { now },
            defaults: makeDefaults(),
            lockProvider: { HousekeeperLock(path: self.lockPath) },
            idleSeconds: { idle }
        )

        runner.tick(regimen: regimen)
        XCTAssertEqual(runner.waitingReason, "Waiting for the Mac to be idle.")

        idle = 31 * 60
        await runner.tick(regimen: regimen)?.value

        XCTAssertNil(runner.waitingReason, "a run that starts is no longer waiting")
        XCTAssertEqual(runner.lastRun?.skippedReason, "No cleaning rules are enabled.")
    }

    func testRunNowAndANewScheduleClearAHold() async {
        var regimen = makeRegimen(enabled: true, intervalHours: 4)
        regimen.requireIdleMinutes = 30
        let runner = CleanRegimenRunner(
            now: { Date() },
            defaults: makeDefaults(),
            lockProvider: { HousekeeperLock(path: self.lockPath) },
            idleSeconds: { 0 }
        )

        runner.tick(regimen: regimen)
        XCTAssertNotNil(runner.waitingReason)
        await runner.runNow(regimen: regimen)?.value
        XCTAssertNil(runner.waitingReason)

        // A fresh runner, because the run above started the interval's clock
        // and a clock that is running has nothing due to hold.
        let other = CleanRegimenRunner(
            now: { Date() },
            defaults: makeDefaults(),
            lockProvider: { HousekeeperLock(path: self.lockPath) },
            idleSeconds: { 0 }
        )
        other.tick(regimen: regimen)
        XCTAssertNotNil(other.waitingReason)
        other.scheduleFromNow(regimen: regimen)
        XCTAssertNil(other.waitingReason)
    }

    func testAFailedRunThatRemovedNothingSaysWhatWentWrong() {
        // The summary used to fall back to "No reclaimable items." for a run
        // that stopped on an error, which reads as a clean no-op.
        let runner = makeRunner()
        var result = RegimenRun(startedAt: Date())
        result.errors = ["APFS snapshot failed.  Nothing was deleted."]
        runner.finish(result, regimen: makeRegimen())
        XCTAssertEqual(runner.lastSummary, "APFS snapshot failed.  Nothing was deleted.")
    }

    func testAnIdleRequirementOfZeroNeverWaits() {
        var regimen = makeRegimen(enabled: true)
        regimen.requireIdleMinutes = 0
        XCTAssertNil(CleanRegimenRunner.scheduleBlocker(regimen: regimen, idleSeconds: 0, panelOpen: false))
    }

    func testRequireUserPresentWaitsForTheOpenPanel() {
        var regimen = makeRegimen(enabled: true)
        regimen.requireIdleMinutes = 0
        regimen.requireUserPresent = true

        XCTAssertEqual(
            CleanRegimenRunner.scheduleBlocker(regimen: regimen, idleSeconds: 3600, panelOpen: false),
            "Waiting for the panel to be open."
        )
        XCTAssertNil(CleanRegimenRunner.scheduleBlocker(regimen: regimen, idleSeconds: 3600, panelOpen: true))
    }

    func testRunNowIgnoresTheIdleRequirement() async {
        // "Run Now" is a person asking, so the regimen's conditions gate the
        // schedule and not the button.
        var regimen = makeRegimen(enabled: true)
        regimen.requireIdleMinutes = 30
        let runner = CleanRegimenRunner(
            now: { Date() },
            defaults: makeDefaults(),
            lockProvider: { HousekeeperLock(path: self.lockPath) },
            idleSeconds: { 0 }
        )
        await runner.runNow(regimen: regimen)?.value
        XCTAssertEqual(runner.lastRun?.skippedReason, "No cleaning rules are enabled.")
    }

    // MARK: - Lifecycle

    func testStopCanBeCalledFromAnotherThread() {
        // `HogStore.deinit` is not main-actor isolated and still has to stop
        // the runner, so the cancel path has to be callable from any thread.
        let runner = makeRunner()
        runner.start()

        let done = expectation(description: "stop ran off the main thread")
        DispatchQueue.global().async {
            runner.stop()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testOneHoldersReleaseDoesNotStopTheRunnerForAnother() {
        // The runner is shared, so a store going away must not cancel the
        // schedule another store still depends on.
        let runner = makeRunner()
        runner.acquire()
        runner.acquire()
        XCTAssertTrue(runner.isScheduling)

        runner.release()
        XCTAssertTrue(runner.isScheduling, "one holder is still using it")

        runner.release()
        XCTAssertFalse(runner.isScheduling, "the last holder stops it")
    }

    func testTheAppHasOneSharedRunner() {
        // The storage panel and the settings window both need the runner and
        // neither owns it.
        XCTAssertTrue(CleanRegimenRunner.shared === CleanRegimenRunner.shared)
    }
}
