import Combine
import CoreGraphics
import Foundation
import os

/// Runs `CleanRegimen` unattended, on a timer, in bounded chunks.
///
/// Why this is a chunked runner and not a gate
/// ------------------------------------------
/// The first version of the reclaim engine dropped to a "cheap only" tier when
/// `load1 > 40`.  This machine runs load 15-30 continuously from real fleet
/// work, so that guard was true almost always and the engine effectively never
/// cleaned.  Jay's correction, 2026-10-02:
///
/// > swap high should mean that you do the same stuff you otherwise would but
/// > just divide the tasks into maybe 2-4 separate smaller tasks
///
/// So the schedule here is unconditional once enabled: pressure changes chunk
/// size and pause, and nothing else.  The scope of a run is `regimen.enabledRules`
/// either way.
///
/// Two invariants worth stating because they are easy to break later:
///
/// - A chunk size of zero is never produced.  That would be the original bug
///   wearing a new hat.
/// - `CleanerExclusions` and `DiskCleaner.isSafeToDelete` are applied on every
///   run exactly as they are for a manual clean.  An unattended run gets no
///   extra authority.
@MainActor
final class CleanRegimenRunner: ObservableObject {

    /// The one runner the app uses.
    ///
    /// The storage panel and the settings window both need to reach it and
    /// neither owns it, so this is the same `static let shared` shape the rest
    /// of the app uses (`MountedDriveStore`, `AutoUpdate`,
    /// `DetachedWindowManager`).  It is deliberately not an `@EnvironmentObject`:
    /// the UI smoke test builds `StorageView` with no environment object at
    /// all, so a view that expected one would crash there.
    static let shared = CleanRegimenRunner()

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: RegimenRun?
    /// Bounded in-memory history of finished runs, newest first, so a wait
    /// or a partial run can be explained after `lastSummary` moves on.
    /// In-memory only: nothing here widens what is persisted or reported.
    @Published private(set) var recentRuns: [RegimenRun] = []
    nonisolated static let recentRunsCap = 10
    /// How many finished runs the persisted trail keeps.  The same 20 the
    /// Maintain list uses (`CompanionMaintain.maxRecentRuns`), so the two
    /// trails answer "recent" the same way.
    nonisolated static let persistedRunsCap = 20
    @Published private(set) var nextRunDate: Date?
    @Published private(set) var lastError: String?

    /// A short human summary of the most recent run, for the panel.
    @Published private(set) var lastSummary: String?

    /// Why a run that is due has not started, when the regimen's own
    /// conditions (the Mac being idle, the panel being open) are what holds it.
    /// Nil whenever nothing is holding it.
    @Published private(set) var waitingReason: String?

    // MARK: - Dependencies

    /// The scheduler's pending check, held so it can be cancelled from any
    /// thread.  `HogStore.deinit` is not main-actor isolated, so the cancel
    /// path has to be.
    nonisolated let loopBox = CleanRegimenTaskBox()
    /// True while the scheduler's loop is running.
    nonisolated var isScheduling: Bool { loopBox.isSet }
    /// The run in flight, held for the same reason.
    nonisolated let runBox = CleanRegimenTaskBox()
    private let defaultsKey = "hoghunter.cleaner.regimen.lastRunAt"
    /// Every tick decision and skip lands here:  a silent skip is an
    /// unexplainable one, and the 2026-11-15 investigation of a regimen that
    /// never ran cost an afternoon because nothing said why.
    private static let log = Logger(subsystem: "com.simplewithus.hoghunter",
                                    category: "Regimen")

    /// When a clock-less regimen first became due.  A blob enabled without a
    /// stored last-run time is due the moment it is first seen;  this marker
    /// is what hours of overdue measure against, and it clears whenever the
    /// interval's clock starts for real.
    private let dueSinceKey = "hoghunter.cleaner.regimen.dueSince"
    /// When a safety gate last failed, kept apart from the completed-run
    /// clock: a run that tripped the gate did not happen, and the two states
    /// have to be told apart.
    private let gateFailureKey = "hoghunter.cleaner.regimen.lastGateFailureAt"
    /// When a partial-discovery run last ran, kept apart from the
    /// completed-run clock: a partial run did not see the whole disk, so it
    /// does not start the interval's clock.  Kept apart from the gate
    /// failure too, because a partial run did clean what it found.
    private let partialRunKey = "hoghunter.cleaner.regimen.lastPartialRunAt"
    /// The persisted run trail: a JSON array of the newest finished runs.
    /// Additive beside the clock keys above, in the app-group suite, so an
    /// older build that never heard of it keeps working untouched.
    private let persistedRunsKey = "hoghunter.cleaner.regimen.recentRuns"

    /// How long a failed safety gate backs off before the runner tries
    /// again.
    ///
    /// The gate trips after the disk scan, so a failure that persists (a
    /// throttled or non-APFS volume) would otherwise repeat a full scan and
    /// another snapshot attempt every fifteen minutes.  An hour is long
    /// enough that a transient failure clears without a long wait, and short
    /// enough that the cleaner is not left idle for a whole interval after
    /// the blocker is gone.
    static let gateBackoff: TimeInterval = 60 * 60

    /// How long a partial-discovery run backs off before the runner pays
    /// for the full-disk scan again.
    ///
    /// A partial run cleans what it found, but the scan did not see the
    /// whole disk, so the interval's clock must not start: the unseen part
    /// still needs a run.  Retrying at every check pays a whole-disk walk
    /// four times an hour for an answer that does not change -- a category
    /// whose walk keeps failing fails the same way minutes later -- and
    /// holds the housekeeper lock against the Python ticks while it does.
    /// Same shape and length as the safety gate's backoff, which exists
    /// for the same reason.
    static let partialRetryBackoff: TimeInterval = gateBackoff

    /// What the run record says while a partial-discovery run is still in
    /// flight:  only what scan time already knows, nothing about a clean
    /// that has not finished -- or even started -- yet.
    private static let partialDiscoveryReason = "Discovery was incomplete; the full scan tries again later."

    /// How long a due run may sit held by the regimen's own conditions
    /// before it starts anyway, in the pressured chunk shape.
    ///
    /// The idle gate exists so an unattended reclaim does not land on a Mac
    /// someone is using.  On this host the gate never opens:  fleet build
    /// work keeps the machine busy around the clock, so a daily regimen that
    /// waits for a quiet half hour never runs at all.  That is the same
    /// failure the 2026-10-02 owner ruling removed for load -- a guard whose
    /// threshold equals the normal state is an outage, not a guard -- so a
    /// run owed long enough stops waiting and cleans in smaller chunks with
    /// longer pauses, the same shape high swap or load already gets.  A run
    /// is measured overdue from when its interval said it was due, not from
    /// when it was last seen waiting.  An explicit `requireUserPresent`
    /// stays binding:  the owner who asked for the panel to be open asked
    /// for exactly that.
    nonisolated static let overdueOverrideHours: TimeInterval = 6

    /// How often the scheduler wakes to *consider* a run.  The interval
    /// between runs is the regimen's; this just checks the clock, and
    /// 15 minutes is fine-grained enough for a daily cadence without
    /// re-scheduling on every tick.
    private let checkInterval: TimeInterval = 15 * 60

    /// Clock seam so tests do not have to wait a day.
    private let now: () -> Date
    private let lastRunDefaults: UserDefaults

    /// Where the persisted run trail lives: the app-group suite `CleanRegimen`
    /// already uses, so the trail sits beside the schedule it ran under.
    /// Tests inject their own suite; without one, persistence stays off under
    /// XCTest so a test run never writes the owner's suite.
    private let historyDefaults: UserDefaults
    private let persistHistory: Bool

    /// The cleanup log an unattended run appends to when it removed
    /// something.  Injected so a test can hand it an in-memory store; without
    /// one, the app's log is used, and nothing under XCTest.
    private let cleanupHistory: CleanupHistoryStore?

    /// Where the runner's lock comes from.
    ///
    /// The lock is the same one the Python reclaim engine takes, so the two
    /// never delete at the same time.  It is a closure rather than a value
    /// because the default path is the real one in
    /// `~/.claude-disk-janitor/.housekeeper.lock`, and a test has to be able
    /// to point it at a temporary directory instead.
    private let lockProvider: () -> HousekeeperLock

    /// Seconds since the person last touched the keyboard or the mouse.
    ///
    /// A closure so a test can say "the Mac has been idle for an hour" without
    /// waiting an hour.
    private let idleSeconds: () -> TimeInterval

    /// The scan a run works from.
    ///
    /// A closure, like every other seam here, because the default path walks
    /// the whole disk and a test must never do that: a test that reaches the
    /// cleaning loop needs a scan it chose, not the real one.
    private let scanProvider: (CleanerExclusions) async -> CleanScanReport
    private let exclusionsProvider: () -> CleanerExclusions

    /// How a chunk of items is cleaned.
    ///
    /// A closure so a test can hand the runner a chunk whose safety snapshot
    /// failed, which is the one error that ends a run, without asking the real
    /// cleaner to delete anything.
    private let cleanProvider: ([CleanItem], CleanerExclusions, Bool) async -> CleanResult

    /// True while the panel is open.  `HogStore` supplies it, because the
    /// runner is process-wide and does not own the panel.
    var presenceProvider: () -> Bool = { false }

    /// How many stores have asked for the schedule to keep running.  The
    /// runner is shared, so one store going away must not stop it for another.
    nonisolated private let holders = CleanRegimenHolderCount()

    init(
        cleaner: DiskCleaner = DiskCleaner(),
        now: @escaping () -> Date = { Date() },
        defaults: UserDefaults = .standard,
        lockProvider: @escaping () -> HousekeeperLock = { HousekeeperLock() },
        idleSeconds: @escaping () -> TimeInterval = { CleanRegimenRunner.systemIdleSeconds() },
        scanProvider: ((CleanerExclusions) async -> CleanScanReport)? = nil,
        exclusionsProvider: @escaping () -> CleanerExclusions = { CleanerExclusions.load() },
        cleanProvider: (([CleanItem], CleanerExclusions, Bool) async -> CleanResult)? = nil,
        historyDefaults: UserDefaults? = nil,
        cleanupHistory: CleanupHistoryStore? = nil
    ) {
        self.now = now
        self.lastRunDefaults = defaults
        if let historyDefaults {
            self.historyDefaults = historyDefaults
            self.persistHistory = true
        } else {
            self.historyDefaults = UserDefaults(suiteName: "group.com.simplewithus.hoghunter") ?? .standard
            self.persistHistory = !Self.isRunningUnderTest
        }
        self.cleanupHistory = cleanupHistory ?? (Self.isRunningUnderTest ? nil : CleanupHistoryStore(inMemory: false))
        self.lockProvider = lockProvider
        self.idleSeconds = idleSeconds
        self.exclusionsProvider = exclusionsProvider
        self.scanProvider = scanProvider ?? { exclusions in
            await cleaner.scan(tier: .standard, exclusions: exclusions, depth: .deeper)
        }
        self.cleanProvider = cleanProvider ?? { items, exclusions, createSnapshot in
            await cleaner.clean(items: items, tier: .standard, createSnapshot: createSnapshot, exclusions: exclusions)
        }
    }

    // MARK: - Lifecycle

    /// Start the scheduler.  Called from `HogStore.start()` alongside the
    /// bandwidth monitor, so the regimen keeps its cadence whether or not
    /// anyone has the panel open.
    func start() {
        stop()
        // A task rather than a run-loop timer, so the cancel path is a
        // `Task.cancel()`, which is safe from any thread.  `HogStore.deinit`
        // is not main-actor isolated and cannot touch a run-loop timer.
        loopBox.set(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.checkInterval))
                guard !Task.isCancelled else { return }
                Self.log.info("scheduler woke to check")
                self.tick()
            }
        })
        // Consider a run promptly on launch so a first-time enable does not
        // wait a full interval to show any effect.
        tick()
    }

    /// A store asks for the schedule to keep running.  The first holder starts
    /// it.  `release()` is the matching call, and the last one stops it.
    func acquire() {
        if holders.increment() == 1 { start() }
    }

    /// A store no longer needs the schedule.  Only the last holder stops it, so
    /// tearing one store down cannot cancel the schedule or an in-flight clean
    /// another store still depends on.
    ///
    /// `nonisolated` because `HogStore.deinit` calls it, and a deinit is not
    /// main-actor isolated.
    nonisolated func release() {
        if holders.decrement() == 0 { stop() }
    }

    /// Stop the scheduler and any run in flight.
    ///
    /// `nonisolated` because `HogStore.deinit` calls it, and a deinit is not
    /// main-actor isolated.
    nonisolated func stop() {
        loopBox.cancel()
        runBox.cancel()
    }

    deinit {
        loopBox.cancel()
        runBox.cancel()
    }

    // MARK: - Scheduling

    /// Is a run due?  Pure enough to test without a timer.
    func isDue(regimen: CleanRegimen, lastRunAt: Date?) -> Bool {
        guard regimen.isEnabled else { return false }
        // A failed safety gate holds the run back for a while.  The gate trips
        // after the disk scan, so a failure that persists -- a throttled or
        // non-APFS volume -- would otherwise pay a full scan every check.
        if let gateFailure = gateFailureAt, now().timeIntervalSince(gateFailure) < Self.gateBackoff {
            return false
        }
        // A partial run backs off like a failed gate: it cleaned what it
        // found, but it did not see the whole disk, so it stays due --
        // just not again at the very next check.
        if let partial = partialRunAt, now().timeIntervalSince(partial) < Self.partialRetryBackoff {
            return false
        }
        guard let lastRunAt else { return true }
        return now().timeIntervalSince(lastRunAt) >= regimen.effectiveIntervalHours * 3600
    }

    /// When a failed safety gate was last hit, if it was.
    private var gateFailureAt: Date? {
        lastRunDefaults.object(forKey: gateFailureKey) as? Date
    }

    /// When the runner may try the gate again.
    var gateRetryDate: Date? {
        gateFailureAt.map { $0.addingTimeInterval(Self.gateBackoff) }
    }

    /// When a partial-discovery run last ran, if one did.
    private var partialRunAt: Date? {
        lastRunDefaults.object(forKey: partialRunKey) as? Date
    }

    /// When the runner may pay for the full scan again after a partial one.
    var partialRetryDate: Date? {
        partialRunAt.map { $0.addingTimeInterval(Self.partialRetryBackoff) }
    }

    /// The one status line the panel shows: running, gate retry time,
    /// waiting reason, last summary with next run, or next run alone.
    var statusLine: String {
        Self.regimenStatusLine(
            isRunning: isRunning,
            lastSummary: lastSummary,
            waitingReason: waitingReason,
            nextRunDate: nextRunDate,
            gateRetryDate: gateRetryDate,
            now: now()
        )
    }

    nonisolated static func regimenStatusLine(
        isRunning: Bool,
        lastSummary: String?,
        waitingReason: String?,
        nextRunDate: Date?,
        gateRetryDate: Date?,
        now: Date,
        formatDateTime: (Date) -> String = { date in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    ) -> String {
        if isRunning { return "Running now." }
        if let retry = gateRetryDate, retry > now {
            return "The last run could not take a safety snapshot, so it will try again at \(formatDateTime(retry))."
        }
        if let waitingReason { return waitingReason }
        if let lastSummary, let nextRunDate {
            return "\(lastSummary)\u{00A0} Next run \(formatDateTime(nextRunDate))."
        }
        if let nextRunDate { return "Next run \(formatDateTime(nextRunDate))." }
        if let lastSummary { return lastSummary }
        return "Scheduled."
    }

    /// One look at the clock: start a scheduled run if one is due and nothing
    /// holds it.  The regimen is a parameter so a test can hand it one; the
    /// scheduler's loop passes none and gets the saved one.  The task is
    /// returned so a test can wait for the run it started.
    @discardableResult
    func tick(regimen plan: CleanRegimen? = nil) -> Task<Void, Never>? {
        let regimen = (plan ?? CleanRegimen.load()).sanitized()
        let lastRunAt = lastRunDefaults.object(forKey: defaultsKey) as? Date
        guard isDue(regimen: regimen, lastRunAt: lastRunAt) else {
            Self.log.info("tick: not due (enabled=\(regimen.isEnabled, privacy: .public), lastRun=\(lastRunAt.map(\.description) ?? "never", privacy: .public), gateRetry=\(self.gateRetryDate.map(\.description) ?? "none", privacy: .public))")
            // A gate that failed recently is holding the run, and the owner
            // can act on that, so the panel says so rather than going quiet.
            if regimen.isEnabled, let retry = gateRetryDate, retry > now() {
                waitingReason = "The last run could not take a safety snapshot, so it will try again later."
                // The interval is a lower bound only when there IS a previous
                // run: a regimen with no previous run is due now, so the gate
                // backoff is the only thing holding it.  When there is one, a
                // run has to wait for both the backoff and the interval, and
                // the interval next-run is already in the past for every run
                // that was due -- which is every gate failure -- so taking
                // the later of the two is what keeps the panel off a time
                // that has gone by.
                let intervalNext = lastRunAt.map {
                    $0.addingTimeInterval(regimen.effectiveIntervalHours * 3600)
                }
                nextRunDate = intervalNext.map { max(retry, $0) } ?? retry
            } else if regimen.isEnabled, let retry = partialRetryDate, retry > now() {
                // A partial run cleaned what it found;  the wait now is the
                // scan backoff, and the panel says so rather than going
                // quiet or advertising a check-time retry that will not run.
                waitingReason = "The last scan was incomplete; the full scan tries again later."
                nextRunDate = retry
            } else {
                waitingReason = nil
                updateNextRun(regimen: regimen, lastRunAt: lastRunAt)
            }
            return nil
        }
        // A scheduled run honors the regimen's own conditions.  "Run Now" is
        // a person asking, so it does not go through this gate.
        Self.log.info("tick: due (lastRun=\(lastRunAt.map(\.description) ?? "never", privacy: .public))")
        if let reason = Self.scheduleBlocker(
            regimen: regimen,
            idleSeconds: idleSeconds(),
            panelOpen: presenceProvider()
        ) {
            // A run the interval has been owed long enough stops waiting on
            // the idle gate and starts in the busy shape instead; see
            // `overdueOverrideHours`.  Anything else keeps the hold, and the
            // panel says when the override would arrive so a wait never
            // reads as forever.
            let dueAt: Date
            if let lastRunAt {
                dueAt = Self.dueDate(lastRunAt: lastRunAt, regimen: regimen, now: now())
            } else if let marked = lastRunDefaults.object(forKey: dueSinceKey) as? Date {
                dueAt = marked
            } else {
                // A regimen with no stored clock (a hand-enabled blob) was
                // due when it was first seen;  mark that moment so the
                // override can measure hours against it instead of finding
                // zero forever.
                dueAt = now()
                lastRunDefaults.set(dueAt, forKey: dueSinceKey)
            }
            guard !Self.overdueOverrideApplies(regimen: regimen, dueAt: dueAt, now: now(), blocker: reason) else {
                // runNow returns nil when a run is already in flight:  say so
                // and set the retry moment, or the log claims a start that
                // never happened while the panel keeps a stale next-run time.
                let task = runNow(regimen: regimen, scheduled: true, busyOverride: true)
                if task != nil {
                    Self.log.info("tick: due and overdue — the override starts it now")
                } else {
                    Self.log.info("tick: overdue override deferred — a run is already in progress")
                    waitingReason = "A run is already in progress; this check will try again shortly."
                    nextRunDate = now().addingTimeInterval(checkInterval)
                }
                return task
            }
            Self.log.info("tick: due, held (\(reason, privacy: .public))")
            waitingReason = Self.blockerText(reason: reason, regimen: regimen, dueAt: dueAt, now: now())
            nextRunDate = now().addingTimeInterval(checkInterval)
            return nil
        }
        return runNow(regimen: regimen, scheduled: true)
    }

    /// Why a due, scheduled run must not start yet, or nil when it may.
    ///
    /// `requireIdleMinutes` and `requireUserPresent` are the regimen's own
    /// conditions.  They were written down and never read, which was harmless
    /// while the runner never ran and is not harmless now: a reclaim on a Mac
    /// someone is using is the case the design set out to avoid.
    nonisolated static func scheduleBlocker(regimen: CleanRegimen,
                                            idleSeconds: TimeInterval,
                                            panelOpen: Bool) -> String? {
        if regimen.requireUserPresent && !panelOpen {
            return "Waiting for the panel to be open."
        }
        if regimen.requireIdleMinutes > 0 && idleSeconds < regimen.requireIdleMinutes * 60 {
            return "Waiting for the Mac to be idle."
        }
        return nil
    }

    /// When the interval's run became due:  the last completed or scheduled
    /// run plus one interval, or now when there is no previous run, which is
    /// the same answer `isDue` gives a first-time schedule.
    nonisolated static func dueDate(lastRunAt: Date?, regimen: CleanRegimen, now: Date) -> Date {
        lastRunAt.map { $0.addingTimeInterval(regimen.effectiveIntervalHours * 3600) } ?? now
    }

    /// True when a due run has been held long enough to start anyway.
    ///
    /// `requireUserPresent` is excluded on purpose.  The idle hold is a
    /// courtesy guess about a person who may never leave;  a panel hold is
    /// the owner's own instruction about when unattended work may happen,
    /// and no amount of being overdue outranks an instruction.
    nonisolated static func overdueOverrideApplies(regimen: CleanRegimen,
                                                   dueAt: Date,
                                                   now: Date,
                                                   blocker: String) -> Bool {
        if regimen.requireUserPresent { return false }
        // `timeIntervalSince` is seconds and the constant is hours:  compare
        // like with like, or six hours collapses to six seconds and every
        // barely-due run starts at once.
        return now.timeIntervalSince(dueAt) >= overdueOverrideHours * 3600
    }

    /// The hold text, plus -- once the run is overdue at all -- how far it
    /// still is from the override, so the panel never shows a wait with no
    /// end.  A run that is not overdue, or one the override is about to
    /// start, keeps the plain reason.
    nonisolated static func blockerText(reason: String, regimen: CleanRegimen, dueAt: Date, now: Date) -> String {
        guard !regimen.requireUserPresent else { return reason }
        // A run that became due seconds ago is not meaningfully overdue:
        // clock drift between "scheduled" and "checked" would otherwise pin
        // a permanent-looking countdown on a first-time hold.
        let overdueSeconds = now.timeIntervalSince(dueAt)
        guard overdueSeconds > 60, overdueSeconds < Self.overdueOverrideHours * 3600 else { return reason }
        let hours = Int(Self.overdueOverrideHours.rounded())
        // A sub-half-hour remainder rounds to zero hours, which reads as a
        // wait with no end -- the one thing this text exists to rule out.
        // Minutes take over under an hour, floored at one.
        let remainingSeconds = max(0, Self.overdueOverrideHours * 3600 - overdueSeconds)
        let countdown: String
        if remainingSeconds < 3600 {
            let minutes = max(1, Int((remainingSeconds / 60).rounded(.up)))
            let unit = minutes == 1 ? "minute" : "minutes"
            countdown = "\(minutes) \(unit)"
        } else {
            let short = max(1, Int((remainingSeconds / 3600).rounded()))
            let unit = short == 1 ? "hour" : "hours"
            countdown = "\(short) \(unit)"
        }
        return "\(reason)\u{00A0} A run overdue by \(hours) hours starts anyway; this one starts in about \(countdown)."
    }

    /// Whether the owner-configured Trash valve is open for this run.
    ///
    /// The valve is the one sanctioned way a scheduled run may touch the
    /// Trash:  it is off unless the owner set a line in Settings, and it
    /// opens only on measured free space at or below that line.  Every other
    /// path keeps `neverEmptyTrash` intact.
    nonisolated static func trashValveOpen(regimen: CleanRegimen, pressure: CleanPressure) -> Bool {
        // An unmeasured disk is a closed valve:  `diskFreeGB` reads 0 when
        // the query fails, and 0 would otherwise look like the fullest disk
        // there is.  A permanent delete never runs on a number we do not
        // have.
        guard pressure.diskFreeKnown, let line = regimen.emptyTrashBelowGB else { return false }
        return pressure.diskFreeGB <= line
    }

    /// Why a chunk's errors mean the run must stop, or nil when the run may
    /// go on.
    ///
    /// A failed safety snapshot is the one error that ends an unattended run:
    /// without a rollback point a delete has nothing to undo.  The reason is
    /// returned rather than acted on here so a test can ask the question
    /// without a disk in front of it.
    nonisolated static func snapshotGateReason(errors: [String]) -> String? {
        guard let failure = errors.first(where: { $0.hasPrefix(DiskCleaner.snapshotFailedPrefix) }) else {
            return nil
        }
        // The engine thins APFS local snapshots BEFORE it takes the safety
        // snapshot, so a snapshot failure can arrive after it has already
        // deleted something.  Saying the regimen "did not run" would then be
        // false, and the panel would contradict the reclaim count it shows
        // beside it.
        if failure.contains("already thinned") {
            return "The cleanup snapshot could not be created, so the rest of the regimen did not run."
        }
        return "The cleanup snapshot could not be created, so the regimen did not run."
    }

    /// True inside an XCTest run.  Without an injected suite or history store,
    /// a test run neither persists the run trail nor appends the cleanup log,
    /// so the owner's suite and log stay clean.  Mirrors `MaintainStore`.
    nonisolated static var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Seconds since the last keyboard, mouse or trackpad event in this login
    /// session.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        // `~0` is the "any event type" value for this call.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    @discardableResult
    private func updateNextRun(regimen: CleanRegimen, lastRunAt: Date?) -> Date? {
        guard regimen.isEnabled else { nextRunDate = nil; return nil }
        let base = lastRunAt ?? now()
        let next = base.addingTimeInterval(regimen.effectiveIntervalHours * 3600)
        nextRunDate = next
        return next
    }

    /// Start the regimen's clock from now.
    ///
    /// Turning the regimen on schedules the first run one interval out rather
    /// than firing one the moment the owner flips the switch.  An unattended
    /// delete should start at a time the owner chose, and "Run Now" is right
    /// there for the other case.
    func scheduleFromNow(regimen: CleanRegimen? = nil) {
        let plan = (regimen ?? CleanRegimen.load()).sanitized()
        // A new schedule ends whatever hold the old one was under.
        waitingReason = nil
        guard plan.isEnabled else {
            nextRunDate = nil
            return
        }
        let started = now()
        lastRunDefaults.set(started, forKey: defaultsKey)
        lastRunDefaults.removeObject(forKey: dueSinceKey)
        lastRunDefaults.removeObject(forKey: partialRunKey)
        updateNextRun(regimen: plan, lastRunAt: started)
    }

    /// Re-read the saved regimen and update what the panel shows.
    ///
    /// Called when the owner changes the regimen, so "Next run" answers at
    /// once instead of at the next fifteen-minute check.
    func refreshSchedule(regimen: CleanRegimen? = nil) {
        let plan = (regimen ?? CleanRegimen.load()).sanitized()
        // The next check sets the hold again if one still applies.
        waitingReason = nil
        guard plan.isEnabled else {
            nextRunDate = nil
            return
        }
        let lastRunAt = lastRunDefaults.object(forKey: defaultsKey) as? Date
        updateNextRun(regimen: plan, lastRunAt: lastRunAt)
    }

    // MARK: - Running

    /// Run the regimen now.  Also the manual entry point, so "Run Now" in
    /// settings and the schedule share one code path.
    ///
    /// The task is returned so a caller can wait for it.  The UI does not
    /// need to, but a test does, and returning the handle costs nothing.
    /// `scheduled` marks a run the interval started (as opposed to a person
    /// pressing Run Now), and is the only path the Trash valve rides:  a
    /// button press never carries the valve's permanence.
    ///
    /// `busyOverride` is the overdue path:  the Mac is in use -- that is why
    /// the run was waiting -- so the run takes the pressured burst shape
    /// whatever the gauges read between bursts of the work keeping it busy.
    @discardableResult
    func runNow(regimen: CleanRegimen? = nil, scheduled: Bool = false,
                busyOverride: Bool = false) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let plan = (regimen ?? CleanRegimen.load()).sanitized()
        guard plan.isValid else {
            lastError = "The regimen settings are out of range, so nothing ran."
            return nil
        }
        isRunning = true
        lastError = nil
        let runId = UUID()
        Self.log.info("run started (id=\(runId.uuidString, privacy: .public), scheduled=\(scheduled, privacy: .public), busy=\(busyOverride, privacy: .public))")
        // A run that starts is no longer waiting, whether the schedule or Run
        // Now started it.
        waitingReason = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(plan, scheduled: scheduled, busyOverride: busyOverride, runId: runId)
        }
        runBox.set(task)
        return task
    }

    private func perform(_ regimen: CleanRegimen, scheduled: Bool = false,
                         busyOverride: Bool = false, runId: UUID) async {
        let started = now()
        var result = RegimenRun(startedAt: started)
        result.runId = runId
        result.trigger = busyOverride ? .overdue : (scheduled ? .scheduled : .manual)
        // A run that stepped aside (a build in flight, or another cleanup
        // holding the lock) did not happen, so it must not start the
        // interval's clock.  Recording it would push a 24-hour regimen a whole
        // day out for a collision that lasts minutes.  The scheduler's next
        // check retries instead.
        var recordsRun = true
        // A safety gate that failed is its own state: the run did not
        // happen, and the next attempt waits a little rather than repeating
        // the scan every check.
        var gateFailed = false
        // A run whose scan was incomplete cleaned only what it saw:  it does
        // not start the interval's clock, but the retry waits out the
        // partial backoff instead of re-walking the disk at the next check.
        var discoveryPartial = false
        defer {
            isRunning = false
            // A cancelled run is not a completed one: the app is quitting or
            // the schedule was stopped, so the interval's clock must not
            // restart.  The next launch finds the run still due.
            if recordsRun && !Task.isCancelled {
                lastRunDefaults.set(started, forKey: defaultsKey)
                lastRunDefaults.removeObject(forKey: dueSinceKey)
                // A completed run clears every hold it could have been
                // under:  the gate's backoff and the partial scan's alike.
                lastRunDefaults.removeObject(forKey: gateFailureKey)
                lastRunDefaults.removeObject(forKey: partialRunKey)
                updateNextRun(regimen: regimen, lastRunAt: started)
            } else {
                if gateFailed {
                    lastRunDefaults.set(started, forKey: gateFailureKey)
                }
                if discoveryPartial {
                    lastRunDefaults.set(started, forKey: partialRunKey)
                }
                // A failed gate or a partial scan waits out its backoff, so
                // that is the time to publish.  The check interval would
                // advertise a run in fifteen minutes that `isDue` refuses
                // to start for an hour, and the waiting reason is already
                // gone by then.
                let retryAfter = gateFailed ? Self.gateBackoff
                    : discoveryPartial ? Self.partialRetryBackoff : checkInterval
                nextRunDate = regimen.isEnabled
                    ? started.addingTimeInterval(retryAfter)
                    : nil
            }
        }

        // A build in flight is the one case where waiting beats working: bulk
        // I/O during `xcodebuild` is exactly what made the old --pressure
        // path time out and leave orphans behind.
        if regimen.avoidDuringBuilds, Self.buildInFlight() {
            result.skippedReason = "A build is running, so the regimen waited."
            Self.log.notice("run skipped: build in flight")
            recordsRun = false
            finish(result, regimen: regimen)
            return
        }

        // The regimen and the Python reclaim ticks must never run at the same
        // time.  They delete the same kinds of things, and two reclaimers
        // racing over one file is how a half-deleted cache directory happens.
        // This is the same lock `scripts/vacuum/lock.py` takes, so the Swift
        // runner and the Python engine exclude each other.
        //
        // `acquire()` runs `/bin/ps` to read the owner's start token, and
        // this runner is on the main actor, so the take happens on a detached
        // task: a slow `ps` or a contended guard must not stall the UI.
        // `release()` spawns no process, so the deferred give-back stays here.
        let lock = lockProvider()
        let outcome = await Task.detached(priority: .utility) { lock.acquire() }.value
        Self.log.info("housekeeper lock: \(outcome == .acquired ? "acquired" : "held by peer", privacy: .public)")
        guard outcome == .acquired else {
            result.skippedReason = "Another cleanup is already running, so the regimen waited."
            Self.log.notice("run skipped: housekeeper lock held")
            recordsRun = false
            finish(result, regimen: regimen)
            return
        }
        defer { lock.release() }

        // Nothing to select means nothing to scan.  The scan walks the whole
        // disk, so a regimen with no enabled rules must not pay for it: the
        // answer is the same either way, and the walk is the expensive part.
        // The Trash valve reads live free space before the scan:  the scan
        // categories depend on it, and a valve decision made after the walk
        // would already have paid for a scan that could not include the
        // Trash.
        // Off the main actor: `current()` reads purgeable capacity, the
        // CacheDelete accounting that hung the panel on a full disk
        // (HOGHUNTER-5).  Same detached shape as the lock take above.
        let pressure = await Task.detached(priority: .utility) { CleanPressure.current() }.value
        let exclusions = exclusionsProvider()
        // The valve rides scheduled runs only, and stays shut when the owner
        // excluded the Trash category:  an explicit exclusion outranks the
        // valve, and walking the Trash only to delete nothing would lie
        // twice.
        let trashValveOpen = scheduled
            && !exclusions.isCategoryExcluded(.trash)
            && Self.trashValveOpen(regimen: regimen, pressure: pressure)
        // Nothing to select means nothing to scan.  The scan walks the whole
        // disk, so a regimen with no enabled rules must not pay for it: the
        // answer is the same either way, and the walk is the expensive part.
        // The valve is its own reason to scan:  an owner who configured only
        // the valve still asked for work.
        guard !regimen.enabledRules.isEmpty || trashValveOpen else {
            result.skippedReason = "No cleaning rules are enabled."
            Self.log.notice("run skipped: no enabled rules")
            recordsRun = false
            finish(result, regimen: regimen)
            return
        }

        // Disabled rules must not consume the bounded scan before enabled
        // ones run.  With the valve open the Trash is scanned too:  it is
        // the one category no rule may select, so the valve lifts its
        // exclusion itself.
        let enabledCategories = Self.scanCategories(for: regimen.enabledRules)
        var scanExclusions = exclusions
        scanExclusions.excludedCategories.formUnion(CleanCategory.allCases
            .filter { !enabledCategories.contains($0) }.map(\.rawValue))
        if trashValveOpen {
            scanExclusions.excludedCategories.remove(CleanCategory.trash.rawValue)
        }
        let scan = await scanProvider(scanExclusions)
        Self.log.info("scan finished: partial=\(scan.isPartial, privacy: .public) selected=\(scan.categories.flatMap { $0.items.filter(\.isSelected) }.count, privacy: .public)")
        if scan.isPartial {
            Self.log.notice("run continues with partial discovery (cleaning the found subset)")
            recordsRun = false
            discoveryPartial = true
            result.skippedReason = Self.partialDiscoveryReason
        }
        // `CleanScanReport` groups by category rather than exposing a flat
        // item list, so flatten the selected items from each report.
        let scanned = scan.categories.flatMap { $0.items.filter(\.isSelected) }
        // The valve's items ride beside the rule-selected ones and are never
        // filtered by rules:  `CleanCategory.trash` answers to no rule by
        // design, so `pendingItems` would drop everything the valve exists
        // to clean.
        let valveItems = trashValveOpen
            ? scanned.filter { $0.category == .trash }
            : []
        let decision = Self.pendingItems(from: scanned, rules: regimen.enabledRules)
        // Snapshot rows ride beside the rule-selected ones when the owner
        // enabled the snapshots rule.  Thinning is one volume-wide `tmutil`
        // call, so a snapshot row's pre-check state never was a per-item
        // verdict -- it is the manual panel's don't-pre-check default, and
        // passing any one row thins every local snapshot regardless.  The
        // rule is the opt-in, so the rows are lifted past the pre-check
        // filter the way the valve's are.  A stored exclusion of the
        // category still wins: unlike the valve, this lift never removes
        // the exclusion from the scan, so an excluded category's rows
        // never reach this run at all.
        let decidedIDs = Set(decision.items.map(\.id))
        let snapshotItems = regimen.enabledRules.contains("snapshots")
            ? scan.categories.flatMap { $0.items }.filter {
                $0.category == .apfsSnapshots && !decidedIDs.contains($0.id)
            }
            : []
        guard decision.skipReason == nil || !valveItems.isEmpty || !snapshotItems.isEmpty else {
            if discoveryPartial {
                // No clean ran, so the record must not claim one.
                result.skippedReason = "Discovery was incomplete (no items cleaned); the full scan tries again later."
            } else {
                result.skippedReason = result.skippedReason ?? decision.skipReason
            }
            recordsRun = false
            finish(result, regimen: regimen)
            return
        }
        let filePending = decision.items + valveItems

        // Pressure decides the burst size, never the burst count.  An
        // overdue run takes the pressured shape without asking the gauges:
        // the person the idle gate protects is there, whatever the idle
        // percentage reads between bursts of the work keeping the Mac busy.
        let chunk = busyOverride
            ? max(1, regimen.effectivePressuredTargetsPerChunk)
            : pressure.chunkSize(regimen: regimen)
        let pause = busyOverride
            ? regimen.effectivePressuredChunkPauseSeconds
            : pressure.pauseSeconds(regimen: regimen)
        result.pressureLabel = busyOverride ? "Busy (Overdue)" : pressure.label
        result.chunkSize = chunk

        // One rollback point per run, not one per chunk.  Every `clean` call
        // with a snapshot asks for a whole-volume local snapshot, so a run of
        // dozens of chunks would pin dozens of them and keep the space it just
        // deleted from coming back.  The first chunk takes it.
        var snapshotTaken = false
        // Snapshot rows clean in one final batch of their own, after every
        // file item.  Thinning is irreversible and purges local snapshots --
        // including this run's rollback point -- and inside `DiskCleaner.clean`
        // a thin runs before that call's own deletions, so a snapshot row
        // sharing a chunked batch with file items would purge the rollback
        // point and then delete those files unprotected.  Apart, the order is
        // safe: file batches run under the rollback point, and the thin the
        // owner enabled consumes it only once nothing is left to protect.
        // (Seer finding on PR #375.)
        var batches: [[CleanItem]] = []
        var index = 0
        while index < filePending.count {
            let end = min(index + chunk, filePending.count)
            batches.append(Array(filePending[index..<end]))
            index = end
        }
        if !snapshotItems.isEmpty { batches.append(snapshotItems) }
        var batchIndex = 0
        while batchIndex < batches.count {
            if Task.isCancelled { break }
            let batch = batches[batchIndex]
            let takeSnapshot = regimen.createSnapshotBeforeClean && !snapshotTaken
            let cleaned = await cleanProvider(batch, exclusions, takeSnapshot)
            result.itemsRemoved += cleaned.itemsRemoved
            result.bytesReclaimed += cleaned.bytesReclaimed
            result.errors.append(contentsOf: cleaned.errors)
            if let name = cleaned.snapshotName {
                result.snapshotName = name
            }
            batchIndex += 1

            if takeSnapshot {
                if cleaned.snapshotName != nil {
                    snapshotTaken = true
                } else if let reason = Self.snapshotGateReason(errors: cleaned.errors) {
                    // No rollback point, so no unattended delete.  `clean`
                    // deleted nothing in this chunk; the rest of the run
                    // does not go on without one.
                    //
                    // A missing snapshot is a failed safety gate, so the run
                    // did not happen: it must not start the interval's clock,
                    // or the next cleanup waits a whole interval over a
                    // rollback point that could not be taken.
                    recordsRun = false
                    result.skippedReason = reason
                    gateFailed = true
                    break
                }
            }

            if batchIndex < batches.count && pause > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        result.cancelled = Task.isCancelled
        if discoveryPartial, result.skippedReason == Self.partialDiscoveryReason {
            // The record says what the scan knows plus what the clean
            // actually did -- counters and errors, never a blanket claim.
            let itemWord = result.itemsRemoved == 1 ? "item" : "items"
            let errorWord = result.errors.count == 1 ? "error" : "errors"
            let outcome = result.cancelled
                ? "the run was cancelled"
                : "cleaned \(result.itemsRemoved) \(itemWord) with \(result.errors.count) \(errorWord)"
            result.skippedReason = "Discovery was incomplete (\(outcome)); the full scan tries again later."
        }
        Self.log.info("run finished (id=\(result.runId.uuidString, privacy: .public)): reclaimed=\(result.bytesReclaimed, privacy: .public) items=\(result.itemsRemoved, privacy: .public) errors=\(result.errors.count, privacy: .public) cancelled=\(result.cancelled, privacy: .public) skip=\(result.skippedReason ?? "none", privacy: .public)")
        finish(result, regimen: regimen)
    }

    /// Record a finished run for the panel.  Internal so a test can hand it a
    /// result without scanning the disk.
    func finish(_ result: RegimenRun, regimen: CleanRegimen) {
        var finished = result
        if finished.finishedAt == nil {
            finished.finishedAt = now()
        }
        lastRun = finished
        recentRuns = Self.cappedHistory(finished, into: recentRuns)
        persistRecentRun(finished)
        appendHistoryRecord(for: finished)
        // A finished run is not waiting any more, whatever the panel showed
        // before it started.
        waitingReason = nil
        // A cancelled item is not a failure: it was not refused, the run was
        // stopped.  A failure that happened BEFORE the stop still is one, and
        // the stop must not hide it.
        let failures = finished.errors.filter { $0 != DiskCleaner.cancelledMessage }
        if !finished.errors.isEmpty {
            // The raw message can carry an absolute path -- a safety check
            // that failed names the path it refused to delete -- so it goes to
            // `lastError`, which no view shows.  The panel gets a count.
            lastError = failures.first ?? finished.errors.first
        }
        let reclaimed: String? = finished.itemsRemoved > 0
            ? "Moved or removed \(HogFormat.memory(finished.bytesReclaimed)) from \(finished.itemsRemoved) items (estimated)."
            : nil
        if finished.cancelled {
            // The run was stopped, not refused.  The panel keeps both facts:
            // what it reclaimed and what it could not remove.
            var parts = [reclaimed, "The cleanup was stopped before it finished."]
                .compactMap { $0 }
            if !failures.isEmpty {
                parts.append(Self.failureCountText(failures.count))
            }
            lastSummary = parts.joined(separator: "\u{00A0} ")
        } else if let reason = finished.skippedReason {
            // A run that removed something and then skipped still removed it:
            // the snapshot gate fails AFTER the engine thinned local
            // snapshots, so the reclaim is real.  Showing only the reason
            // would claim the regimen did nothing while it was deleting.
            lastSummary = [reclaimed, reason].compactMap { $0 }.joined(separator: "\u{00A0} ")
        } else if let reclaimed {
            // Some items were reclaimed and some were not.  The panel says
            // both, so a partial run does not read as a clean one.
            lastSummary = finished.errors.isEmpty
                ? reclaimed
                : "\(reclaimed)\u{00A0} \(Self.failureCountText(finished.errors.count))"
        } else if !finished.errors.isEmpty {
            lastSummary = Self.failureCountText(finished.errors.count)
        } else {
            lastSummary = "No reclaimable items."
        }
    }

    /// Newest-first history with the oldest runs dropped past the cap.
    nonisolated static func cappedHistory(_ run: RegimenRun, into history: [RegimenRun]) -> [RegimenRun] {
        Array(([run] + history).prefix(recentRunsCap))
    }

    /// The persisted run trail, newest first.  Decode-tolerant: a missing key
    /// reads as no trail, and one bad record drops itself rather than the
    /// other nineteen.  Nothing shows this in the UI yet; it is the trail the
    /// panel's history will list.
    func persistedRecentRuns() -> [RegimenRun] {
        guard let data = historyDefaults.data(forKey: persistedRunsKey) else { return [] }
        return Self.decodePersistedRuns(data)
    }

    /// One record per element, so a single corrupt record cannot take the
    /// rest with it.  Mirrors `MaintainStore.loadHistory`.
    nonisolated static func decodePersistedRuns(_ data: Data) -> [RegimenRun] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { dict in
            guard let element = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(RegimenRun.self, from: element)
        }
    }

    private func persistRecentRun(_ run: RegimenRun) {
        guard persistHistory else { return }
        let trail = Array(([run] + persistedRecentRuns()).prefix(Self.persistedRunsCap))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(trail) else { return }
        historyDefaults.set(data, forKey: persistedRunsKey)
    }

    /// Who the cleanup log credits for an unattended run.  `nil` is a manual
    /// Mac clean and `"iPhone"` is the phone's; the regimen is neither, so it
    /// names itself.  Nothing filters on this value besides the phone's
    /// `"iPhone"` chip, which an unattended run must never wear.
    nonisolated static let automaticCleanupSource = "Automatic Cleanup"

    /// The cleanup log's row for an unattended run, or nothing when the run
    /// removed nothing.  Same gate as `CleanupHistoryRecord.record(from:)`,
    /// which a regimen run cannot use directly: it takes one `CleanResult`
    /// and a run spans many chunks, so the run's own totals are the record.
    /// The record carries no category or title detail -- the run never kept
    /// it -- only what it knows: bytes, count, time, snapshot, and source.
    private func appendHistoryRecord(for run: RegimenRun) {
        guard run.itemsRemoved > 0, let history = cleanupHistory else { return }
        history.append(CleanupHistoryRecord(
            bytesReclaimed: run.bytesReclaimed,
            itemsRemoved: run.itemsRemoved,
            tier: .standard,
            categoryIds: [],
            itemTitles: [],
            snapshotName: run.snapshotName,
            source: Self.automaticCleanupSource,
            cleanedAt: run.finishedAt ?? run.startedAt
        ))
    }

    /// How a count of failures reads in the panel.
    nonisolated static func failureCountText(_ count: Int) -> String {
        count == 1 ? "1 item could not be removed." : "\(count) items could not be removed."
    }

    // MARK: - Rule mapping

    /// Items the regimen may delete.  An empty rule set, or a set that matches
    /// nothing, skips the run.  It must not fall back to every scanned item.
    nonisolated static func pendingItems(from scanned: [CleanItem], rules: Set<String>) -> (items: [CleanItem], skipReason: String?) {
        if rules.isEmpty {
            return ([], "No cleaning rules are enabled.")
        }
        let pending = scanned.filter { !ruleNames(for: $0).isDisjoint(with: rules) }
        if pending.isEmpty {
            let reason = scanned.isEmpty
                ? "Nothing reclaimable was found."
                : "Nothing matched the enabled rules."
            return ([], reason)
        }
        return (pending, nil)
    }

    /// Map a scanned item back to the engine's rule vocabulary so the
    /// regimen's `enabledRules` is meaningful.
    ///
    /// A category can answer to more than one name.  `userCaches` is the tree
    /// the `app-caches` rule sweeps, but regimens persisted before that rule
    /// existed carry `dev-caches`, and both must keep selecting it.
    nonisolated static func scanCategories(for rules: Set<String>) -> Set<CleanCategory> {
        Set(CleanCategory.allCases.filter { !ruleNames(for: $0).isDisjoint(with: rules) })
    }

    nonisolated static func ruleNames(for item: CleanItem) -> Set<String> {
        ruleNames(for: item.category)
    }

    nonisolated private static func ruleNames(for category: CleanCategory) -> Set<String> {
        switch category {
        case .userCaches: return ["dev-caches", "app-caches"]
        case .logsAndDiagnostics: return ["logs"]
        case .developer: return ["xcode-artifacts"]
        case .trash:
            // No rule, so no regimen can reach it.  `DiskCleaner.clean` removes
            // a Trash item permanently, and this category used to answer to
            // temp-scratch, a default rule: an unattended run emptied ~/.Trash
            // against the policy's neverEmptyTrash.  A person can still select
            // Trash in the Disk Cleaner.
            return []
        case .tempFiles:
            // Own rule: /tmp items stay unselected by default, and turning on
            // another rule must not include them.
            return ["tmp-files"]
        case .apfsSnapshots:
            // Own rule: an unattended regimen must not thin snapshots just
            // because the user opted into log cleanup.
            return ["snapshots"]
        case .aiArtifacts: return ["agent-state", "xcode-artifacts"]
        case .orphanedData, .localAIModels, .largeAndOldFiles:
            // No unattended rule owns these.  Their scan verdicts are
            // identity and existence heuristics over user data -- an
            // uninstalled app's support folder (pre-selected, and on a
            // name mismatch a live app's data), downloaded model weights
            // with no staleness gate, a large file in Documents -- not
            // proofs of regenerability, so they stay on the manual Extreme
            // surface and answer to ask-first, like tool-made backups and
            // stale temp repos below.  They used to answer to
            // xcode-artifacts, which implied a reach the Extreme tier
            // blocked on every run.
            return ["ask-first"]
        case .staleBackups:
            // No engine rule owns tool-made backups: a regimen must never take
            // them unattended, and "ask-first" is not schedulable, so items in
            // this category stay a Standard one-click choice only.
            return ["ask-first"]
        case .staleTempRepos:
            // Extreme, per-item review only. No unattended rule owns repos.
            return ["ask-first"]
        }
    }

    /// The canonical rule name for an item.  A category may answer to more than
    /// one name in `ruleNames(for:)`; this is the one it is named by, with
    /// legacy aliases dropped so the answer stays stable.
    nonisolated static func ruleName(for item: CleanItem) -> String {
        let names = ruleNames(for: item)
        for canonical in canonicalRuleNames where names.contains(canonical) {
            return canonical
        }
        return ""
    }

    /// Checked in order by `ruleName(for:)`, so a category with an alias names
    /// itself by the specific rule and keeps the older name as the alias.
    ///
    /// `nonisolated` because `ruleName(for:)` is, and a main-actor-isolated
    /// constant read from a nonisolated context is an error in Swift 6.
    nonisolated private static let canonicalRuleNames = [
        "agent-state", "app-caches", "tmp-files", "snapshots",
        "logs", "xcode-artifacts", "ask-first",
    ]

    /// True when a real build is in flight.  A lone `xcodebuild` hours old
    /// with zero compiler children is stalled, not building, so the compiler
    /// children are what count.
    static func buildInFlight() -> Bool {
        for name in ["clang", "swift-frontend", "swiftc"] where countProcesses(named: name) > 0 {
            return true
        }
        return false
    }

    /// Count live processes with an exact name.
    ///
    /// Deliberately counts names, not command lines.  This machine's
    /// processes carry live credentials in their arguments, so a bare `ps` or
    /// `pgrep -l` would write secrets into logs.  `proc_name` supplies the
    /// short name only, which is all this check needs.
    static func countProcesses(named name: String) -> Int {
        let stride = MemoryLayout<pid_t>.stride
        var byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return 0 }
        let capacity = Int(byteCount) / stride
        var pids = [pid_t](repeating: 0, count: capacity)
        byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * stride))
        guard byteCount > 0 else { return 0 }

        let count = Int(byteCount) / stride
        var found = 0
        for pid in pids.prefix(count) {
            guard let procName = procName(of: pid), procName == name else { continue }
            found += 1
        }
        return found
    }

    /// The short process name, or nil.  Reads `p_comm` only.
    private static func procName(of pid: pid_t) -> String? {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdshortinfo>.size) else { return nil }
        return withUnsafeBytes(of: &info.pbsi_comm) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

/// What started a regimen run.  `scheduled` is the interval, `manual` is a
/// person pressing Run Now, and `overdue` is the override that starts a due
/// run despite the idle gate (`overdueOverrideHours`).
enum RegimenTrigger: String, Codable, Sendable {
    case scheduled
    case manual
    case overdue

    /// An unknown trigger decodes as manual rather than failing the record:
    /// a persisted run written by a newer build must stay readable here.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RegimenTrigger(rawValue: raw) ?? .manual
    }
}

/// One regimen run, for the UI and for `lastSummary`.
struct RegimenRun: Equatable, Sendable, Codable {
    var runId: UUID = UUID()
    var trigger: RegimenTrigger = .manual
    var startedAt: Date
    var finishedAt: Date?
    var bytesReclaimed: UInt64 = 0
    var itemsRemoved: Int = 0
    var errors: [String] = []
    var skippedReason: String?
    var pressureLabel: String?
    var chunkSize: Int?
    var cancelled: Bool = false
    /// The APFS rollback point this run took, when it took one.  Copied from
    /// the chunk that took it, so the run and its history row name it.
    var snapshotName: String?

    /// Explicit memberwise-style defaults initializer.  Declaring
    /// `init(from:)` below suppresses Swift's synthesized memberwise init,
    /// so this is spelled out the way `CleanRegimen` does.
    init(
        runId: UUID = UUID(),
        trigger: RegimenTrigger = .manual,
        startedAt: Date,
        finishedAt: Date? = nil,
        bytesReclaimed: UInt64 = 0,
        itemsRemoved: Int = 0,
        errors: [String] = [],
        skippedReason: String? = nil,
        pressureLabel: String? = nil,
        chunkSize: Int? = nil,
        cancelled: Bool = false,
        snapshotName: String? = nil
    ) {
        self.runId = runId
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.bytesReclaimed = bytesReclaimed
        self.itemsRemoved = itemsRemoved
        self.errors = errors
        self.skippedReason = skippedReason
        self.pressureLabel = pressureLabel
        self.chunkSize = chunkSize
        self.cancelled = cancelled
        self.snapshotName = snapshotName
    }

    /// Decode tolerantly: a record missing its start never was a run and is
    /// dropped, but a record from an older or newer build keeps its fields.
    /// `encode` and `CodingKeys` stay synthesized.
    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self)
        guard let startedAt = try raw.decodeIfPresent(Date.self, forKey: .startedAt) else {
            throw DecodingError.keyNotFound(
                CodingKeys.startedAt,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "a regimen run without a start")
            )
        }
        self.startedAt = startedAt
        self.runId = try raw.decodeIfPresent(UUID.self, forKey: .runId) ?? UUID()
        self.trigger = try raw.decodeIfPresent(RegimenTrigger.self, forKey: .trigger) ?? .manual
        self.finishedAt = try raw.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.bytesReclaimed = try raw.decodeIfPresent(UInt64.self, forKey: .bytesReclaimed) ?? 0
        self.itemsRemoved = try raw.decodeIfPresent(Int.self, forKey: .itemsRemoved) ?? 0
        self.errors = try raw.decodeIfPresent([String].self, forKey: .errors) ?? []
        self.skippedReason = try raw.decodeIfPresent(String.self, forKey: .skippedReason)
        self.pressureLabel = try raw.decodeIfPresent(String.self, forKey: .pressureLabel)
        self.chunkSize = try raw.decodeIfPresent(Int.self, forKey: .chunkSize)
        self.cancelled = try raw.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        self.snapshotName = try raw.decodeIfPresent(String.self, forKey: .snapshotName)
    }

    var succeeded: Bool {
        errors.isEmpty && !cancelled && skippedReason == nil
    }
}

/// Counts the stores that depend on the shared runner.
///
/// Locked rather than main-actor isolated because `HogStore.deinit`, which
/// releases, is not main-actor isolated.
final class CleanRegimenHolderCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the count after adding one.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    /// Returns the count after taking one away, never below zero.
    func decrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count = max(0, count - 1)
        return count
    }
}

/// Holds a task so it can be cancelled from any thread.
///
/// The runner is `@MainActor`, but `HogStore.deinit` is not main-actor
/// isolated and still has to stop it.  `Task.cancel()` is safe from any
/// thread, so the handle lives in a small locked box that a `nonisolated`
/// member can reach.  Without this the deinit could not call `stop()` at
/// all, and the runner would outlive the store that owns it.
final class CleanRegimenTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    /// True while a task is held.
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }
}
