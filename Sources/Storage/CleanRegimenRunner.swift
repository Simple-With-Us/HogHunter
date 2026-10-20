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

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: RegimenRun?
    @Published private(set) var nextRunDate: Date?
    @Published private(set) var lastError: String?

    /// A short human summary of the most recent run, for the panel.
    @Published private(set) var lastSummary: String?

    // MARK: - Dependencies

    private let cleaner: DiskCleaner
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private let defaultsKey = "hoghunter.cleaner.regimen.lastRunAt"

    /// How often the scheduler wakes to *consider* a run.  The interval
    /// between runs is the regimen's; this just checks the clock, and
    /// 15 minutes is fine-grained enough for a daily cadence without
    /// re-scheduling on every tick.
    private let checkInterval: TimeInterval = 15 * 60

    /// Clock seam so tests do not have to wait a day.
    private let now: () -> Date
    private let lastRunDefaults: UserDefaults

    init(
        cleaner: DiskCleaner = DiskCleaner(),
        now: @escaping () -> Date = { Date() },
        defaults: UserDefaults = .standard
    ) {
        self.cleaner = cleaner
        self.now = now
        self.lastRunDefaults = defaults
    }

    // MARK: - Lifecycle

    /// Start the scheduler.  Called from `HogStore.start()` alongside the
    /// bandwidth monitor, so the regimen keeps its cadence whether or not
    /// anyone has the panel open.
    func start() {
        stop()
        let t = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Consider a run promptly on launch so a first-time enable does not
        // wait a full interval to show any effect.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    deinit {
        timer?.invalidate()
        task?.cancel()
    }

    // MARK: - Scheduling

    /// Is a run due?  Pure enough to test without a timer.
    func isDue(regimen: CleanRegimen, lastRunAt: Date?) -> Bool {
        guard regimen.isEnabled else { return false }
        guard let lastRunAt else { return true }
        return now().timeIntervalSince(lastRunAt) >= regimen.effectiveIntervalHours * 3600
    }

    private func tick() {
        let regimen = CleanRegimen.load().sanitized()
        let lastRunAt = lastRunDefaults.object(forKey: defaultsKey) as? Date
        guard isDue(regimen: regimen, lastRunAt: lastRunAt) else {
            updateNextRun(regimen: regimen, lastRunAt: lastRunAt)
            return
        }
        runNow(regimen: regimen)
    }

    private func updateNextRun(regimen: CleanRegimen, lastRunAt: Date?) {
        guard regimen.isEnabled else { nextRunDate = nil; return }
        let base = lastRunAt ?? now()
        nextRunDate = base.addingTimeInterval(regimen.effectiveIntervalHours * 3600)
    }

    // MARK: - Running

    /// Run the regimen now.  Also the manual entry point, so "Run Now" in
    /// settings and the schedule share one code path.
    func runNow(regimen: CleanRegimen? = nil) {
        guard !isRunning else { return }
        let plan = (regimen ?? CleanRegimen.load()).sanitized()
        guard plan.isValid else {
            lastError = "The regimen settings are out of range, so nothing ran."
            return
        }
        isRunning = true
        lastError = nil
        task = Task { [weak self] in
            await self?.perform(plan)
        }
    }

    private func perform(_ regimen: CleanRegimen) async {
        let started = now()
        var result = RegimenRun(startedAt: started)
        var lastRunAt = started
        defer {
            isRunning = false
            lastRunDefaults.set(lastRunAt, forKey: defaultsKey)
            updateNextRun(regimen: regimen, lastRunAt: lastRunAt)
        }

        // A build in flight is the one case where waiting beats working: bulk
        // I/O during `xcodebuild` is exactly what made the old --pressure
        // path time out and leave orphans behind.
        if regimen.avoidDuringBuilds, Self.buildInFlight() {
            result.skippedReason = "A build is running, so the regimen waited."
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

        var index = 0
        while index < pending.count {
            if Task.isCancelled { break }
            let end = min(index + chunk, pending.count)
            let batch = Array(pending[index..<end])
            let cleaned = await cleaner.clean(
                items: batch,
                tier: .standard,
                createSnapshot: regimen.createSnapshotBeforeClean,
                exclusions: exclusions
            )
            result.itemsRemoved += cleaned.itemsRemoved
            result.bytesReclaimed += cleaned.bytesReclaimed
            result.errors.append(contentsOf: cleaned.errors)
            index = end

            if index < pending.count && pause > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        result.cancelled = Task.isCancelled
        finish(result, regimen: regimen)
    }

    private func finish(_ result: RegimenRun, regimen: CleanRegimen) {
        lastRun = result
        if result.itemsRemoved > 0 {
            lastSummary = "Reclaimed \(HogFormat.memory(result.bytesReclaimed)) from \(result.itemsRemoved) items."
        } else if let reason = result.skippedReason {
            lastSummary = reason
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
    private static let canonicalRuleNames = [
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
