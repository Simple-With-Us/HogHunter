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

    private let cleaner: DiskCleaner
    /// The scheduler's pending check, held so it can be cancelled from any
    /// thread.  `HogStore.deinit` is not main-actor isolated, so the cancel
    /// path has to be.
    nonisolated let loopBox = CleanRegimenTaskBox()
    /// True while the scheduler's loop is running.
    nonisolated var isScheduling: Bool { loopBox.isSet }
    /// The run in flight, held for the same reason.
    nonisolated let runBox = CleanRegimenTaskBox()
    private let defaultsKey = "hoghunter.cleaner.regimen.lastRunAt"

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
        idleSeconds: @escaping () -> TimeInterval = { CleanRegimenRunner.systemIdleSeconds() }
    ) {
        self.cleaner = cleaner
        self.now = now
        self.lastRunDefaults = defaults
        self.lockProvider = lockProvider
        self.idleSeconds = idleSeconds
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
        guard let lastRunAt else { return true }
        return now().timeIntervalSince(lastRunAt) >= regimen.effectiveIntervalHours * 3600
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
            waitingReason = nil
            updateNextRun(regimen: regimen, lastRunAt: lastRunAt)
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

    /// Seconds since the last keyboard, mouse or trackpad event in this login
    /// session.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        // `~0` is the "any event type" value for this call.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    private func updateNextRun(regimen: CleanRegimen, lastRunAt: Date?) {
        guard regimen.isEnabled else { nextRunDate = nil; return }
        let base = lastRunAt ?? now()
        nextRunDate = base.addingTimeInterval(regimen.effectiveIntervalHours * 3600)
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
        defer {
            isRunning = false
            // A cancelled run is not a completed one: the app is quitting or
            // the schedule was stopped, so the interval's clock must not
            // restart.  The next launch finds the run still due.
            if recordsRun && !Task.isCancelled {
                lastRunDefaults.set(started, forKey: defaultsKey)
                updateNextRun(regimen: regimen, lastRunAt: started)
            } else {
                nextRunDate = regimen.isEnabled
                    ? started.addingTimeInterval(checkInterval)
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
        let scan = await cleaner.scan(tier: .standard, exclusions: exclusions)
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
            let cleaned = await cleaner.clean(
                items: batch,
                tier: .standard,
                createSnapshot: takeSnapshot,
                exclusions: exclusions
            )
            result.itemsRemoved += cleaned.itemsRemoved
            result.bytesReclaimed += cleaned.bytesReclaimed
            result.errors.append(contentsOf: cleaned.errors)
            index = end

            if takeSnapshot {
                if cleaned.snapshotName != nil {
                    snapshotTaken = true
                } else if cleaned.errors.contains(where: { $0.hasPrefix(DiskCleaner.snapshotFailedPrefix) }) {
                    // No rollback point, so no unattended delete.  `clean`
                    // deleted nothing in this chunk; the rest of the run
                    // does not go on without one.
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
        if result.itemsRemoved > 0 {
            lastSummary = "Reclaimed \(HogFormat.memory(result.bytesReclaimed)) from \(result.itemsRemoved) items."
        } else if let reason = result.skippedReason {
            lastSummary = reason
        } else if let failure = result.errors.first {
            // Nothing was removed and something went wrong, a failed safety
            // snapshot included.  "No reclaimable items" would read as a
            // clean no-op when the run actually stopped.
            lastSummary = failure
        } else {
            lastSummary = "No reclaimable items."
        }
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
