import CoreGraphics
import Foundation

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
    /// When a safety gate last failed, kept apart from the completed-run
    /// clock: a run that tripped the gate did not happen, and the two states
    /// have to be told apart.
    private let gateFailureKey = "hoghunter.cleaner.regimen.lastGateFailureAt"

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

    /// How often the scheduler wakes to *consider* a run.  The interval
    /// between runs is the regimen's; this just checks the clock, and
    /// 15 minutes is fine-grained enough for a daily cadence without
    /// re-scheduling on every tick.
    private let checkInterval: TimeInterval = 15 * 60

    /// Clock seam so tests do not have to wait a day.
    private let now: () -> Date
    private let lastRunDefaults: UserDefaults

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
        cleanProvider: (([CleanItem], CleanerExclusions, Bool) async -> CleanResult)? = nil
    ) {
        self.now = now
        self.lastRunDefaults = defaults
        self.lockProvider = lockProvider
        self.idleSeconds = idleSeconds
        self.scanProvider = scanProvider ?? { exclusions in
            await cleaner.scan(tier: .standard, exclusions: exclusions)
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
        guard let lastRunAt else { return true }
        return now().timeIntervalSince(lastRunAt) >= regimen.effectiveIntervalHours * 3600
    }

    /// When a failed safety gate was last hit, if it was.
    private var gateFailureAt: Date? {
        lastRunDefaults.object(forKey: gateFailureKey) as? Date
    }

    /// When the runner may try the gate again.
    private var gateRetryDate: Date? {
        gateFailureAt.map { $0.addingTimeInterval(Self.gateBackoff) }
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
            } else {
                waitingReason = nil
                updateNextRun(regimen: regimen, lastRunAt: lastRunAt)
            }
            return nil
        }
        // A scheduled run honors the regimen's own conditions.  "Run Now" is
        // a person asking, so it does not go through this gate.
        if let reason = Self.scheduleBlocker(
            regimen: regimen,
            idleSeconds: idleSeconds(),
            panelOpen: presenceProvider()
        ) {
            waitingReason = reason
            nextRunDate = now().addingTimeInterval(checkInterval)
            return nil
        }
        return runNow(regimen: regimen)
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
    @discardableResult
    func runNow(regimen: CleanRegimen? = nil) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let plan = (regimen ?? CleanRegimen.load()).sanitized()
        guard plan.isValid else {
            lastError = "The regimen settings are out of range, so nothing ran."
            return nil
        }
        isRunning = true
        lastError = nil
        // A run that starts is no longer waiting, whether the schedule or Run
        // Now started it.
        waitingReason = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(plan)
        }
        runBox.set(task)
        return task
    }

    private func perform(_ regimen: CleanRegimen) async {
        let started = now()
        var result = RegimenRun(startedAt: started)
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
        defer {
            isRunning = false
            // A cancelled run is not a completed one: the app is quitting or
            // the schedule was stopped, so the interval's clock must not
            // restart.  The next launch finds the run still due.
            if recordsRun && !Task.isCancelled {
                lastRunDefaults.set(started, forKey: defaultsKey)
                // The gate works again, so the backoff it earned is over.
                lastRunDefaults.removeObject(forKey: gateFailureKey)
                updateNextRun(regimen: regimen, lastRunAt: started)
            } else {
                if gateFailed {
                    lastRunDefaults.set(started, forKey: gateFailureKey)
                }
                // A failed gate waits out the backoff, so that is the time to
                // publish.  The check interval would advertise a run in fifteen
                // minutes that `isDue` refuses to start for an hour, and the
                // waiting reason is already gone by then.
                nextRunDate = regimen.isEnabled
                    ? started.addingTimeInterval(gateFailed ? Self.gateBackoff : checkInterval)
                    : nil
            }
        }

        // A build in flight is the one case where waiting beats working: bulk
        // I/O during `xcodebuild` is exactly what made the old --pressure
        // path time out and leave orphans behind.
        if regimen.avoidDuringBuilds, Self.buildInFlight() {
            result.skippedReason = "A build is running, so the regimen waited."
            recordsRun = false
            finish(result, regimen: regimen)
            return
        }

        // The regimen and the Python reclaim ticks must never run at the same
        // time.  They delete the same kinds of things, and two reclaimers
        // racing over one file is how a half-deleted cache directory happens.
        // This is the same lock `scripts/vacuum/lock.py` takes, so the Swift
        // runner and the Python engine exclude each other.
        let lock = lockProvider()
        guard lock.acquire() == .acquired else {
            result.skippedReason = "Another cleanup is already running, so the regimen waited."
            recordsRun = false
            finish(result, regimen: regimen)
            return
        }
        defer { lock.release() }

        // Nothing to select means nothing to scan.  The scan walks the whole
        // disk, so a regimen with no enabled rules must not pay for it: the
        // answer is the same either way, and the walk is the expensive part.
        guard !regimen.enabledRules.isEmpty else {
            result.skippedReason = "No cleaning rules are enabled."
            finish(result, regimen: regimen)
            return
        }

        let exclusions = CleanerExclusions.load()
        let scan = await scanProvider(exclusions)
        // `CleanScanReport` groups by category rather than exposing a flat
        // item list, so flatten the selected items from each report.
        let scanned = scan.categories.flatMap { $0.items.filter(\.isSelected) }
        let decision = Self.pendingItems(from: scanned, rules: regimen.enabledRules)
        guard decision.skipReason == nil else {
            result.skippedReason = decision.skipReason
            finish(result, regimen: regimen)
            return
        }
        let pending = decision.items

        // Pressure decides the burst size, never the burst count.
        let pressure = CleanPressure.current()
        let chunk = pressure.chunkSize(regimen: regimen)
        let pause = pressure.pauseSeconds(regimen: regimen)
        result.pressureLabel = pressure.label
        result.chunkSize = chunk

        // One rollback point per run, not one per chunk.  Every `clean` call
        // with a snapshot asks for a whole-volume local snapshot, so a run of
        // dozens of chunks would pin dozens of them and keep the space it just
        // deleted from coming back.  The first chunk takes it.
        var snapshotTaken = false
        var index = 0
        while index < pending.count {
            if Task.isCancelled { break }
            let end = min(index + chunk, pending.count)
            let batch = Array(pending[index..<end])
            let takeSnapshot = regimen.createSnapshotBeforeClean && !snapshotTaken
            let cleaned = await cleanProvider(batch, exclusions, takeSnapshot)
            result.itemsRemoved += cleaned.itemsRemoved
            result.bytesReclaimed += cleaned.bytesReclaimed
            result.errors.append(contentsOf: cleaned.errors)
            index = end

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

            if index < pending.count && pause > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        result.cancelled = Task.isCancelled
        finish(result, regimen: regimen)
    }

    /// Record a finished run for the panel.  Internal so a test can hand it a
    /// result without scanning the disk.
    func finish(_ result: RegimenRun, regimen: CleanRegimen) {
        lastRun = result
        // A finished run is not waiting any more, whatever the panel showed
        // before it started.
        waitingReason = nil
        // A cancelled item is not a failure: it was not refused, the run was
        // stopped.  A failure that happened BEFORE the stop still is one, and
        // the stop must not hide it.
        let failures = result.errors.filter { $0 != DiskCleaner.cancelledMessage }
        if !result.errors.isEmpty {
            // The raw message can carry an absolute path -- a safety check
            // that failed names the path it refused to delete -- so it goes to
            // `lastError`, which no view shows.  The panel gets a count.
            lastError = failures.first ?? result.errors.first
        }
        let reclaimed: String? = result.itemsRemoved > 0
            ? "Reclaimed \(HogFormat.memory(result.bytesReclaimed)) from \(result.itemsRemoved) items."
            : nil
        if result.cancelled {
            // The run was stopped, not refused.  The panel keeps both facts:
            // what it reclaimed and what it could not remove.
            var parts = [reclaimed, "The cleanup was stopped before it finished."]
                .compactMap { $0 }
            if !failures.isEmpty {
                parts.append(Self.failureCountText(failures.count))
            }
            lastSummary = parts.joined(separator: " ")
        } else if let reason = result.skippedReason {
            // A run that removed something and then skipped still removed it:
            // the snapshot gate fails AFTER the engine thinned local
            // snapshots, so the reclaim is real.  Showing only the reason
            // would claim the regimen did nothing while it was deleting.
            lastSummary = [reclaimed, reason].compactMap { $0 }.joined(separator: " ")
        } else if let reclaimed {
            // Some items were reclaimed and some were not.  The panel says
            // both, so a partial run does not read as a clean one.
            lastSummary = result.errors.isEmpty
                ? reclaimed
                : "\(reclaimed) \(Self.failureCountText(result.errors.count))"
        } else if !result.errors.isEmpty {
            lastSummary = Self.failureCountText(result.errors.count)
        } else {
            lastSummary = "No reclaimable items."
        }
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
    nonisolated static func ruleNames(for item: CleanItem) -> Set<String> {
        switch item.category {
        case .userCaches: return ["dev-caches", "app-caches"]
        case .logsAndDiagnostics: return ["logs"]
        case .developer: return ["xcode-artifacts"]
        case .trash: return ["temp-scratch"]
        case .tempFiles:
            // Own rule: Trash's temp-scratch toggle must not include or
            // exclude /tmp items, which stay unselected by default.
            return ["tmp-files"]
        case .apfsSnapshots:
            // Own rule: an unattended regimen must not thin snapshots just
            // because the user opted into log cleanup.
            return ["snapshots"]
        case .aiArtifacts: return ["agent-state", "xcode-artifacts"]
        case .orphanedData, .localAIModels, .largeAndOldFiles:
            return ["xcode-artifacts"]
        case .staleBackups:
            // No engine rule owns tool-made backups: a regimen must never take
            // them unattended, and "ask-first" is not schedulable, so items in
            // this category stay a Standard one-click choice only.
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
        "agent-state", "app-caches", "tmp-files", "temp-scratch", "snapshots",
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

/// One regimen run, for the UI and for `lastSummary`.
struct RegimenRun: Equatable, Sendable {
    var startedAt: Date
    var finishedAt: Date?
    var bytesReclaimed: UInt64 = 0
    var itemsRemoved: Int = 0
    var errors: [String] = []
    var skippedReason: String?
    var pressureLabel: String?
    var chunkSize: Int?
    var cancelled: Bool = false

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
