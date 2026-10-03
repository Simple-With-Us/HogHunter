import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement

/// Everything the panel binds to.
///
/// The store lives on the main actor, but nothing expensive happens there: a
/// serial utility queue owns the sampler and the history database, and results
/// hop back to the main actor to be turned into rows.  A tick that fires while
/// the previous one is still running is skipped rather than queued, so a busy
/// machine cannot make Hog Hunter the hog.
@MainActor
final class HogStore: ObservableObject {
    // MARK: - Published state

    @Published private(set) var pulse = MachinePulse.empty
    @Published private(set) var rows: [HogRow] = []
    @Published private(set) var recentCpuPercents: [Double] = []
    @Published private(set) var hasBaseline = false
    @Published private(set) var isStale = false
    @Published private(set) var launchesAtLogin = false
    /// Failures the user should act on: a sample that would not run, a quit
    /// that went wrong.  Shown in red.
    @Published var lastError: String?
    /// A neutral summary of what a quit actually did, which is often not an
    /// error at all ("Quit 1, skipped Safari is a system process.").
    @Published var lastNotice: String?
    /// The history database's own last failure, kept apart so a history tick
    /// cannot wipe a quit or sample message, and so a recovered database
    /// clears its own stale string.
    @Published private(set) var historyError: String?
    /// Only `toggleLoginItem` writes this, so Settings can show it beside the
    /// toggle it actually belongs to.
    @Published private(set) var loginItemError: String?

    // MARK: - Storage / Network lookups

    /// Snapshot of every currently-running bundle id the resolver knows
    /// about.  Used by the Storage pane to mark rows as "running now"
    /// without re-querying NSWorkspace.
    func runningBundleIdsSnapshot() -> Set<String> {
        Set(resolver.runningBundleIds())
    }

    /// Best-effort bundle-id + display-name lookup for the Network pane's
    /// per-pid attribution.  Falls back to a pid-only label when the pid
    /// is not in the resolver table.
    func lookup(pid: pid_t) -> (bundleId: String?, name: String) {
        resolver.lookup(pid)
    }

    /// Set by the panel.  Metadata resolution beyond the menu bar's top hog and
    /// all history aggregation are gated on this.
    @Published var panelVisible = false {
        didSet {
            guard panelVisible, panelVisible != oldValue else { return }
            refreshHistory()
        }
    }

    // MARK: - Persisted choices

    @Published var window: TimeWindow = .now { didSet { persist(); scheduleChoiceChanged() } }
    @Published var grouping: HogGrouping = .apps { didSet { persist(); scheduleChoiceChanged() } }
    @Published var sort: HogSort = .cpu { didSet { persist(); scheduleChoiceChanged() } }
    @Published var cpuScale: CpuScale = .perCore { didSet { persist() } }
    @Published var menuBarLabelMode: MenuBarLabelMode = .machinePercent { didSet { persist() } }
    @Published var refreshInterval: TimeInterval = 3 {
        didSet {
            persist()
            restartTimer()
            writeThroughInfisical(key: InfisicalKey.refreshInterval, value: String(refreshInterval))
        }
    }
    @Published var alertsEnabled = false {
        didSet {
            persist()
            alertsSwitched()
            // A row that was in cooldown when alerts were turned off should
            // not fire the moment alerts come back on, and a row that was
            // already most of the way through a sustained window should not
            // finish it without a fresh threshold-crossing tick.  Reset the
            // policy so re-enabling starts from a clean slate.
            if !alertsEnabled { alerts.resetPolicy() }
        }
    }
    /// Per-core, so 300 means three cores fully busy.
    @Published var alertThresholdPercent: Double = 300 {
        didSet {
            persist()
            writeThroughInfisical(key: InfisicalKey.alertThresholdPercent, value: String(alertThresholdPercent))
        }
    }
    @Published var alertSustainedMinutes: Int = 5 {
        didSet {
            persist()
            writeThroughInfisical(key: InfisicalKey.alertSustainedMinutes, value: String(alertSustainedMinutes))
        }
    }
    @Published var alertWebhookURL: String = "" {
        didSet {
            persist()
            alerts.webhookURL = alertWebhookURL
            writeThroughInfisical(key: InfisicalKey.alertWebhookURL, value: alertWebhookURL)
        }
    }
    /// System, not light: the fleet-wide owner ruling (FLEET-UI-COPY.md, 2026-09-19)
    /// is that first paint follows the OS.  A stored Light or Dark still wins --
    /// only the no-preference fallback changes.
    @Published var appearance: AppearanceChoice = .system { didSet { persist() } }
    /// Off until the owner turns it on.  The iPhone can read the list.  It cannot quit.
    @Published var shareWithIPhone = false {
        didSet {
            persist()
            if !loadingSettings { syncCompanion() }
        }
    }
    /// Off until the owner turns it on in Mac Settings.
    @Published var allowRemoteQuit = false {
        didSet {
            persist()
            companionServer.allowRemoteQuit = allowRemoteQuit
        }
    }
    @Published private(set) var companionCode = ""
    @Published private(set) var companionStatus = "Off"

    /// Sustained-hog notifications.  Settings observes it directly for the
    /// authorization answer.
    let alerts = Alerts()

    /// Free space on the boot volume, for the panel's third card.  Nil until
    /// the first read succeeds and whenever the volume cannot be read, which
    /// the card shows as unavailable rather than as an empty disk.
    @Published private(set) var diskSpace: DiskSpace?

    /// Interface byte counters and their 24-hour peaks, for the Network tab.
    /// Owned here rather than by the tab so the sampling -- and therefore the
    /// peak -- keeps running whether or not anyone is looking.
    let bandwidth: BandwidthStore

    /// UserDefaults keys, shared with any `@AppStorage` view that edits them.
    enum Key {
        static let window = "window"
        static let grouping = "grouping"
        static let sort = "sort"
        static let cpuScale = "cpuScale"
        static let menuBarLabelMode = "menuBarLabelMode"
        static let refreshInterval = "refreshInterval"
        static let alertsEnabled = "alertsEnabled"
        static let alertThresholdPercent = "alertThresholdPercent"
        static let alertSustainedMinutes = "alertSustainedMinutes"
        static let alertWebhookURL = "alertWebhookURL"
        static let appearance = "appearance"
        static let shareWithIPhone = "shareWithIPhone"
        static let allowRemoteQuit = "allowRemoteQuit"
        static let companionCode = "companionCode"
        static let companionPeerID = "companionPeerID"
    }

    private let companionServer = CompanionServer()
    private var companionPeerID = ""

    // MARK: - Machinery

    private let queue = DispatchQueue(label: "hoghunter.sampling", qos: .utility)
    private let sampler = Sampler()
    private let history: HistoryStore
    private let resolver = MetadataResolver()
    private let defaults: UserDefaults

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isSampling = false
    private var started = false
    private var tickIndex = 0
    private var loadingSettings = false
    /// True while Infisical values are being applied over the local settings,
    /// so the apply does not write the same values back to Infisical.
    private var applyingInfisical = false
    private var lastTickAt = Date.distantPast

    private var samples: [ProcessKey: ProcessSample] = [:]
    private var liveRows: [HogRow] = []
    private var historyRows: [HogRow] = []
    private var coverage = HistoryStore.Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil)
    /// The full, untruncated snapshot from the last tick -- not display-sorted
    /// or cut to 25 -- so `menuBarTopHog` can find the true busiest row even
    /// when it would not have made the panel's own list.
    private var lastProcesses: [ProcessSample] = []
    private var lastGroups: [Grouping.Group] = []

    /// History is written every fifth tick, so one history tick covers five
    /// refresh intervals.
    private static let recordEvery = 5
    /// Free space is a stat call, not a sample: once a minute is far more often
    /// than a human watches a disk fill up.
    private static let diskRefreshEvery = 20
    private static let rowLimit = 25

    init(historyURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let history = HistoryStore(url: historyURL ?? HistoryStore.defaultURL)
        self.history = history
        self.bandwidth = BandwidthStore(history: history)
        loadSettings()
        setupCompanionHandlers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(infisicalDidRefresh),
            name: .infisicalSettingsDidRefresh,
            object: nil
        )
        start()
    }

    deinit {
        timer?.invalidate()
        pressureSource?.cancel()
        companionServer.stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshLoginItem()
        // Opening, migrating and first-pruning the database is up to half a
        // second of work on an upgrade, so it happens on the sampling queue.
        // The queue is serial, so this lands before the first tick's snapshot.
        let history = self.history
        queue.async { history.openIfNeeded() }
        bandwidth.start()
        // Settle the notification decision now rather than at the moment the
        // first alert fires, which would post before the prompt was answered.
        if alertsEnabled { alerts.requestAuthorization() }
        tick()
        restartTimer()
        watchMemoryPressure()
        syncCompanion()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        started = false
    }

    private func restartTimer() {
        guard started else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStaleness()
                self?.tick()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Pressure transitions ask for a fresh reading, but a full pass over the
    /// process table is the most expensive thing Hog Hunter does and pressure
    /// flapping is exactly when the machine can least afford it.  A pressure
    /// tick replaces the next scheduled one rather than adding to it, so the
    /// rate is capped at one pass per refresh interval however hard it flaps.
    private func watchMemoryPressure() {
        pressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard Date().timeIntervalSince(self.lastTickAt) >= self.refreshInterval else { return }
                // `tick()` no-ops when a sample is already in flight, in which
                // case the timer that would otherwise fire on schedule must be
                // left alone -- restarting it here would delay that pending
                // tick for no reason.
                if self.tick() {
                    self.restartTimer()
                }
            }
        }
        source.resume()
        pressureSource = source
    }

    // MARK: - Sampling

    /// Starts a sample, or returns `false` without doing anything when one is
    /// already in flight.
    @discardableResult
    func tick() -> Bool {
        guard !isSampling else { return false }
        lastTickAt = Date()
        isSampling = true
        let sampler = self.sampler
        queue.async {
            let snapshot = sampler.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
        return true
    }

    private func apply(_ snapshot: Snapshot) {
        isSampling = false
        tickIndex += 1
        pulse = snapshot.pulse
        hasBaseline = snapshot.hasBaseline
        isStale = false

        recentCpuPercents.append(snapshot.pulse.cpuPercent)
        if recentCpuPercents.count > 30 {
            recentCpuPercents.removeFirst()
        }

        samples = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.key, $0) })
        // The running-app table is the most expensive thing Hog Hunter does on
        // the main actor (NSWorkspace.shared.runningApplications enumerates
        // ~250 apps and reading four properties off each costs ~40 ms), so it
        // is rebuilt on a slower cadence than the sampler: every fifth tick,
        // which matches the history-record cadence (default ~15 s with a 3 s
        // refresh).  Every twentieth tick is a force refresh, which re-reads
        // an app even when it has already settled, so an app promoted from
        // accessory to regular (or back) after launch picks up the change.
        let resolverTick = tickIndex % 5 == 0
        let forceRefresh = tickIndex % 20 == 0
        if resolverTick {
            resolver.refreshRunningApps(force: forceRefresh)
        }
        let groups = Grouping.groups(
            snapshot.processes,
            isRegularApp: { [resolver] pid in resolver.isRegularApp(pid) },
            bundleId: { [resolver] pid in resolver.bundleId(pid) }
        )

        var groupKeyByProcess: [ProcessKey: String] = [:]
        for group in groups {
            for member in group.members { groupKeyByProcess[member.key] = group.key }
        }

        lastProcesses = snapshot.processes
        lastGroups = groups
        liveRows = buildLiveRows(snapshot.processes, groups: groups)
        if window == .now { rows = liveRows }

        if alertsEnabled {
            alerts.evaluate(
                candidates: alertCandidates(snapshot.processes, groups: groups),
                threshold: alertThresholdPercent,
                sustained: TimeInterval(alertSustainedMinutes) * 60,
                now: snapshot.pulse.sampledAt
            )
        }

        if tickIndex % Self.recordEvery == 0 {
            record(snapshot.processes, groupKeys: groupKeyByProcess, coreCount: snapshot.pulse.coreCount)
        }
        if tickIndex % Self.diskRefreshEvery == 0 || diskSpace == nil {
            diskSpace = DiskSpace.current()
        }
        if tickIndex % 60 == 0 {
            resolver.prune(live: Set(samples.keys))
        }
        if window != .now { refreshHistory() }
        publishCompanion()
    }

    private func record(_ processes: [ProcessSample], groupKeys: [ProcessKey: String], coreCount: Int) {
        var bundles: [ProcessKey: String] = [:]
        for process in processes {
            if let bundle = resolver.bundleId(process.key.pid) { bundles[process.key] = bundle }
        }
        let history = self.history
        queue.async {
            history.record(
                samples: processes,
                groupKey: { groupKeys[$0.key] ?? "proc:\($0.key.pid)-\($0.key.startTime)" },
                bundleId: { bundles[$0.key] },
                coreCount: coreCount
            )
            history.prune()
        }
    }

    // MARK: - Row identity

    /// Row ids are shared with `AlertPolicy`, so both live in one place.  The
    /// two grouping modes keep separate namespaces on purpose: an app's summed
    /// CPU and one member process's CPU are different measurements and must not
    /// share a sustained clock.
    private static func processRowId(_ key: ProcessKey) -> String {
        "p-\(key.pid)-\(key.startTime)"
    }

    private static func groupRowId(_ key: String) -> String {
        "a-\(key)"
    }

    /// The member whose metadata stands for the whole group: its owner when
    /// there is one, otherwise its largest process.  Static and `nonisolated`:
    /// it only reads the group handed to it, never store state, and is called
    /// from the `nonisolated` `alertCandidates(processes:groups:...)` below.
    private nonisolated static func anchorKey(_ group: Grouping.Group) -> ProcessKey {
        if let owner = group.ownerPid,
           let sample = group.members.first(where: { $0.key.pid == owner }) {
            return sample.key
        }
        return group.members.max(by: { $0.footprintBytes < $1.footprintBytes })?.key ?? group.members[0].key
    }

    // MARK: - Alerts

    /// One hog worth alerting on, selected but not yet named: `candidate.name`
    /// is a fallback (the raw process or group name) and `resolveKey` is the
    /// key the caller should resolve display metadata for, if it wants a
    /// nicer name than the fallback.
    struct AlertCandidateSelection {
        var candidate: Alerts.Candidate
        var resolveKey: ProcessKey
    }

    /// Everything at or above the alert threshold, whatever the panel is
    /// showing.  Alerting must not depend on the display list: with Sort set to
    /// Memory, a process burning six cores can sit far outside the 25 largest
    /// memory consumers and would never be considered at all.  Filtering by the
    /// threshold first keeps this cheap -- the set is bounded by total CPU
    /// divided by the threshold, so it is normally empty.
    ///
    /// Pure: no store state and no metadata resolution, so it is exercised
    /// directly by `AlertCandidatesTests` without a `HogStore` in sight, and
    /// `nonisolated` so those tests can call it without hopping to the main
    /// actor.  The instance-level `alertCandidates(_:groups:)` below is a
    /// thin wrapper that resolves display names afterwards.
    nonisolated static func alertCandidates(
        processes: [ProcessSample],
        groups: [Grouping.Group],
        grouping: HogGrouping,
        threshold: Double,
        processRowId: (ProcessKey) -> String,
        groupRowId: (String) -> String
    ) -> [AlertCandidateSelection] {
        if grouping == .processes {
            return processes
                .filter { $0.cpuPercent >= threshold }
                .map { process in
                    AlertCandidateSelection(
                        candidate: Alerts.Candidate(
                            id: processRowId(process.key),
                            name: process.name,
                            cpuPercent: process.cpuPercent
                        ),
                        resolveKey: process.key
                    )
                }
        }
        return groups
            .filter { $0.cpuPercent >= threshold }
            .map { group in
                let anchor = anchorKey(group)
                return AlertCandidateSelection(
                    candidate: Alerts.Candidate(
                        id: groupRowId(group.key),
                        name: group.name,
                        cpuPercent: group.cpuPercent
                    ),
                    resolveKey: anchor
                )
            }
    }

    /// Resolves the pure selection above into candidates with real display
    /// names, touching the resolver only for the keys actually selected.
    private func alertCandidates(
        _ processes: [ProcessSample],
        groups: [Grouping.Group]
    ) -> [Alerts.Candidate] {
        let selections = Self.alertCandidates(
            processes: processes,
            groups: groups,
            grouping: grouping,
            threshold: alertThresholdPercent,
            processRowId: { Self.processRowId($0) },
            groupRowId: { Self.groupRowId($0) }
        )
        guard !selections.isEmpty else { return [] }
        let metadata = resolver.resolve(selections.map(\.resolveKey), samples: samples)
        return selections.map { selection in
            var candidate = selection.candidate
            if let name = metadata[selection.resolveKey]?.displayName {
                candidate.name = name
            }
            return candidate
        }
    }

    // MARK: - Live rows

    private func buildLiveRows(_ processes: [ProcessSample], groups: [Grouping.Group]) -> [HogRow] {
        if grouping == .processes {
            // Sorted before truncation, so the top 25 really are the top 25.
            let ranked = processes.sorted(by: processOrder).prefix(Self.rowLimit)
            let metadata = resolver.resolve(ranked.map(\.key), samples: samples)
            return ranked.map { process in
                let reason = ProcessControl.blockReason(for: process)
                return HogRow(
                    id: Self.processRowId(process.key),
                    keys: [process.key],
                    name: metadata[process.key]?.displayName ?? process.name,
                    detail: "pid \(process.key.pid) · \(process.threadCount) threads",
                    cpuPercent: process.cpuPercent,
                    memoryBytes: process.footprintBytes,
                    peakMemoryBytes: nil,
                    presence: nil,
                    icon: metadata[process.key]?.icon,
                    path: process.path.isEmpty ? nil : process.path,
                    isApp: metadata[process.key]?.activationPolicy == .regular,
                    isGroup: false,
                    canQuit: reason == nil,
                    quitBlockReason: reason,
                    isTamed: process.isTamed,
                    isSleepBlocker: process.isSleepBlocker,
                    canTame: reason == nil
                )
            }
        }

        let ranked = groups.sorted(by: groupOrder).prefix(Self.rowLimit)
        let anchors = ranked.map(Self.anchorKey)
        let metadata = resolver.resolve(anchors, samples: samples)

        return zip(ranked, anchors).map { group, anchor in
            let blocks = group.members.map { ProcessControl.blockReason(for: $0) }
            let canQuit = blocks.contains(where: { $0 == nil })
            let isTamed = !group.members.isEmpty && group.members.allSatisfy(\.isTamed)
            let isSleepBlocker = group.members.contains(where: \.isSleepBlocker)
            return HogRow(
                id: Self.groupRowId(group.key),
                keys: group.members.map(\.key),
                name: metadata[anchor]?.displayName ?? group.name,
                detail: groupDetail(group),
                cpuPercent: group.cpuPercent,
                memoryBytes: group.memoryBytes,
                peakMemoryBytes: nil,
                presence: nil,
                icon: metadata[anchor]?.icon,
                path: group.path,
                isApp: group.isApp,
                isGroup: group.members.count > 1,
                canQuit: canQuit,
                quitBlockReason: canQuit ? nil : blocks.compactMap { $0 }.first,
                isTamed: isTamed,
                isSleepBlocker: isSleepBlocker,
                canTame: canQuit
            )
        }
    }

    private func groupDetail(_ group: Grouping.Group) -> String {
        let count = group.members.count
        let suffix = count > 1 ? " · \(count) processes" : ""
        if let bundle = group.bundleId, !bundle.isEmpty { return bundle + suffix }
        if let owner = group.ownerPid { return "pid \(owner)" + suffix }
        return "pid \(group.members[0].key.pid)" + suffix
    }

    private func processOrder(_ a: ProcessSample, _ b: ProcessSample) -> Bool {
        switch sort {
        case .cpu:
            if a.cpuPercent == b.cpuPercent { return a.footprintBytes > b.footprintBytes }
            return a.cpuPercent > b.cpuPercent
        case .memory:
            if a.footprintBytes == b.footprintBytes { return a.cpuPercent > b.cpuPercent }
            return a.footprintBytes > b.footprintBytes
        }
    }

    private func groupOrder(_ a: Grouping.Group, _ b: Grouping.Group) -> Bool {
        switch sort {
        case .cpu:
            if a.cpuPercent == b.cpuPercent { return a.memoryBytes > b.memoryBytes }
            return a.cpuPercent > b.cpuPercent
        case .memory:
            if a.memoryBytes == b.memoryBytes { return a.cpuPercent > b.cpuPercent }
            return a.memoryBytes > b.memoryBytes
        }
    }

    // MARK: - History rows

    /// A `@Published` `didSet` runs while SwiftUI is applying the picker's own
    /// binding, and reassigning `rows` there draws "Publishing changes from
    /// within view updates is not allowed".  The rebuild is hopped to the next
    /// main-actor turn, which is the same run loop pass as far as the user is
    /// concerned: the picker still refreshes immediately.
    private func scheduleChoiceChanged() {
        Task { @MainActor [weak self] in
            self?.choiceChanged()
        }
    }

    private func choiceChanged() {
        if window == .now {
            // A history error from Past Hour must not linger once the user is
            // back looking at live rows.
            historyError = nil
            rows = liveRows
            publishCompanion()
        } else {
            rows = historyRows
            publishCompanion()
            refreshHistory()
        }
    }

    private func refreshHistory() {
        guard let lookback = window.lookback, panelVisible else { return }
        let history = self.history
        let groupByApp = grouping == .apps
        let sort = self.sort
        let secondsPerTick = refreshInterval * Double(Self.recordEvery)
        queue.async {
            let aggregates = history.aggregates(lookback: lookback, groupByApp: groupByApp, sort: sort)
            let coverage = history.coverage(lookback: lookback, secondsPerTick: secondsPerTick)
            let error = history.lastError
            DispatchQueue.main.async { [weak self] in
                self?.applyHistory(aggregates, coverage: coverage, error: error)
            }
        }
    }

    private func applyHistory(
        _ aggregates: [HistoryStore.Aggregate],
        coverage: HistoryStore.Coverage,
        error: String?
    ) {
        self.coverage = coverage
        historyError = error
        historyRows = aggregates.prefix(Self.rowLimit).map { item in
            HogRow(
                id: "h-\(item.key)",
                keys: [],
                name: resolver.displayName(bundleId: item.bundleId, fallback: item.name),
                detail: historyDetail(item),
                cpuPercent: item.avgCpu,
                memoryBytes: UInt64(max(0, item.avgMemoryBytes)),
                peakMemoryBytes: item.peakMemoryBytes,
                presence: item.presence,
                icon: resolver.icon(bundleId: item.bundleId, path: nil),
                path: nil,
                isApp: item.bundleId != nil,
                isGroup: false,
                canQuit: false,
                quitBlockReason: "only in history",
                isTamed: false,
                isSleepBlocker: false,
                canTame: false
            )
        }
        if window != .now { rows = historyRows }
        publishCompanion()
    }

    private func historyDetail(_ item: HistoryStore.Aggregate) -> String {
        "avg CPU · peak \(HogFormat.memory(item.peakMemoryBytes)) · seen \(HogFormat.percent(item.presence))"
    }

    // MARK: - Captions

    var cpuCaption: String {
        "\(HogFormat.percent(pulse.cpuPercent / 100)) of all \(pulse.coreCount) cores"
    }

    /// Just the two numbers: "13.3 of 16 GB".
    var memorySizeCaption: String {
        "\(gigabytes(pulse.memoryUsedBytes)) of \(gigabytes(pulse.totalMemoryBytes)) GB"
    }

    /// Free space, said the way the memory caption says memory: the number you
    /// would act on first, out of the number it sits in.
    var diskSpaceCaption: String {
        guard let diskSpace else { return "Reading…" }
        return "\(gigabytes(diskSpace.freeBytes)) of \(gigabytes(diskSpace.totalBytes)) GB free"
    }

    var memoryCaption: String {
        var parts = [memorySizeCaption]
        if pulse.swapUsedBytes > 0 {
            parts.append("\(HogFormat.memory(pulse.swapUsedBytes)) swapped")
        }
        if pulse.pressure != .unknown {
            parts.append("pressure \(pulse.pressure.label)")
        }
        return parts.joined(separator: " · ")
    }

    var swapRateCaption: String? {
        let inRate = pulse.swapInBytesPerSec
        let outRate = pulse.swapOutBytesPerSec
        guard inRate >= 1024 || outRate >= 1024 else { return nil }
        if outRate > inRate { return "swapping out \(HogFormat.rate(outRate))" }
        return "swapping in \(HogFormat.rate(inRate))"
    }

    /// Who the machine's CPU belongs to, and how much of it we cannot see.
    /// Returns nil when there is nothing interesting to say (an idle machine
    /// where every CPU percent is 0 and every process is readable), so the
    /// panel can hide the line instead of printing "0% · 0% (0 processes not
    /// readable)".
    var attributionCaption: String? {
        let visible = HogFormat.percent(pulse.visibleCpuPercent / 100)
        let rest = HogFormat.percent(pulse.invisibleCpuPercent / 100)
        let unreadable = pulse.unreadableProcessCount
        // A boring line is "0% attributed to N visible processes · 0% other …"
        // — hide the whole row unless at least one of the three numbers is
        // doing some work.
        if pulse.visibleCpuPercent <= 0,
           pulse.invisibleCpuPercent <= 0,
           unreadable == 0 { return nil }
        var pieces = ["\(visible) attributed to \(HogFormat.count(pulse.readableProcessCount)) visible processes (shown below)"]
        if pulse.invisibleCpuPercent > 0 || unreadable > 0 {
            pieces.append("\(rest) other users, root and kernel (\(HogFormat.count(unreadable)) not readable)")
        }
        return pieces.joined(separator: " · ")
    }

    var scaleLegend: String {
        switch cpuScale {
        case .perCore: return "Rows: % of one core.  Header: % of all cores."
        case .machineShare: return "Rows and header: % of all cores."
        }
    }

    var coverageNote: String {
        // Nothing is said about what "100% CPU" means on the live view.  The
        // only CPU on the page is the header meter, which is always the whole
        // machine; repeating the per-core rule there reads as a correction to
        // a number nobody is looking at.
        if window == .now { return "Live snapshot." }
        guard coverage.tickCount > 0 else {
            return "History starts when Hog Hunter is open.  Turn on Launch at Login in Settings for a full day."
        }
        let windowLabel = window == .day ? "24 h" : "hour"
        return "Sampled \(HogFormat.duration(coverage.sampledSeconds)) of the last \(windowLabel)."
    }

    /// A process or app's name and CPU, resolved just for the menu bar label.
    /// Deliberately not a `HogRow`: the menu bar only ever reads these two
    /// fields, so there is no reason to build a whole row -- with its icon,
    /// quit eligibility and the rest -- just to name the busiest one.
    private struct TopHog {
        var name: String
        var cpuPercent: Double
    }

    /// The busiest process or app, or nil when nothing is busy enough --
    /// including before the first two samples, when every row still reads 0%.
    ///
    /// Computed from the last full snapshot (`lastProcesses` / `lastGroups`),
    /// not from `liveRows`: `liveRows` is sorted by the user's chosen Sort and
    /// truncated to 25, so with Sort set to Memory a process burning six cores
    /// but holding little memory could sit outside that list and the menu bar
    /// would silently miss it.  Only the winning key's name is resolved, the
    /// same one-key call `resolve` already supports for exactly this reason.
    private var menuBarTopHog: TopHog? {
        if grouping == .processes {
            guard let top = lastProcesses.max(by: { $0.cpuPercent < $1.cpuPercent }), top.cpuPercent >= 1 else {
                return nil
            }
            let name = resolver.resolve([top.key], samples: samples)[top.key]?.displayName ?? top.name
            return TopHog(name: name, cpuPercent: top.cpuPercent)
        }
        guard let top = lastGroups.max(by: { $0.cpuPercent < $1.cpuPercent }), top.cpuPercent >= 1 else {
            return nil
        }
        let anchor = Self.anchorKey(top)
        let name = resolver.resolve([anchor], samples: samples)[anchor]?.displayName ?? top.name
        return TopHog(name: name, cpuPercent: top.cpuPercent)
    }

    private var machinePercentLabel: String {
        HogFormat.percent(pulse.cpuPercent / 100)
    }

    private var machinePercentHelp: String {
        "CPU across all \(pulse.coreCount) cores."
    }

    var menuBarLabel: String {
        switch menuBarLabelMode {
        case .machinePercent, .sparkline:
            return machinePercentLabel
        case .topHogName:
            guard let top = menuBarTopHog else { return machinePercentLabel }
            let name = Self.truncated(top.name)
            return "\(name) \(HogFormat.cpu(top.cpuPercent, scale: cpuScale, coreCount: pulse.coreCount))"
        }
    }

    var menuBarHelp: String {
        switch menuBarLabelMode {
        case .machinePercent:
            return machinePercentHelp
        case .sparkline:
            return "Live CPU activity sparkline across all \(pulse.coreCount) cores."
        case .topHogName:
            // The label silently falls back to the machine percentage when no
            // row is busy, so the help has to fall back with it or it names a
            // scale the number is not on.
            guard menuBarTopHog != nil else { return machinePercentHelp }
            switch cpuScale {
            case .perCore: return "Busiest app, as % of one core."
            case .machineShare: return "Busiest app, as % of all \(pulse.coreCount) cores."
            }
        }
    }

    /// What VoiceOver reads for the menu bar item: the live number, untruncated.
    /// `menuBarHelp` is already spoken as the hint by `.help`, so repeating it
    /// as the value would say the same sentence twice and the number never.
    var menuBarAccessibilityValue: String {
        switch menuBarLabelMode {
        case .machinePercent, .sparkline:
            return machinePercentLabel
        case .topHogName:
            guard let top = menuBarTopHog else { return machinePercentLabel }
            return "\(top.name) \(HogFormat.cpu(top.cpuPercent, scale: cpuScale, coreCount: pulse.coreCount))"
        }
    }

    /// Keeps the menu bar from growing without limit when an app has a long
    /// name.  About fourteen characters is as much as the bar can spare.
    static func truncated(_ name: String, limit: Int = 14) -> String {
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        if value == value.rounded() { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Actions

    func quit(_ row: HogRow, force: Bool) {
        lastError = nil
        lastNotice = nil
        let outcome = ProcessControl.quit(row, force: force)
        // Often not a failure at all -- "Quit 1, skipped Safari is a system
        // process." is a summary -- so it does not go in the red channel.
        // But a quit that acted on nothing (everything blocked, changed, or
        // failed -- including the history-row case where there was nothing
        // live to act on at all) is a failure, and belongs in the red channel.
        if outcome.actedOn == 0 {
            lastError = outcome.message
        } else {
            lastNotice = outcome.message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tick()
        }
    }

    func tame(_ row: HogRow) {
        lastError = nil
        lastNotice = nil
        var tamedCount = 0
        for member in row.keys {
            let res = ProcessControl.tame(pid: member.pid)
            if res.outcome.isAction { tamedCount += 1 }
        }
        if tamedCount > 0 {
            lastNotice = "Tamed \(row.name) (nice priority 20 & background QoS)."
        } else {
            lastError = "Could not tame \(row.name)."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tick()
        }
    }

    func untame(_ row: HogRow) {
        lastError = nil
        lastNotice = nil
        var untamedCount = 0
        for member in row.keys {
            let res = ProcessControl.untame(pid: member.pid)
            if res.outcome.isAction { untamedCount += 1 }
        }
        if untamedCount > 0 {
            lastNotice = "Restored priority for \(row.name)."
        } else {
            lastError = "Could not restore priority for \(row.name)."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tick()
        }
    }

    func toggleLoginItem() {
        loginItemError = nil
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshLoginItem()
        } catch {
            loginItemError = error.localizedDescription
        }
    }

    private func refreshLoginItem() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Settings

    private func loadSettings() {
        loadingSettings = true
        defer { loadingSettings = false }
        if let raw = defaults.string(forKey: Key.window), let value = TimeWindow(rawValue: raw) { window = value }
        if let raw = defaults.string(forKey: Key.grouping), let value = HogGrouping(rawValue: raw) { grouping = value }
        if let raw = defaults.string(forKey: Key.sort), let value = HogSort(rawValue: raw) { sort = value }
        if let raw = defaults.string(forKey: Key.cpuScale), let value = CpuScale(rawValue: raw) { cpuScale = value }
        if let raw = defaults.string(forKey: Key.menuBarLabelMode), let value = MenuBarLabelMode(rawValue: raw) {
            menuBarLabelMode = value
        }
        if let raw = defaults.string(forKey: Key.appearance), let value = AppearanceChoice(rawValue: raw) {
            appearance = value
        }
        let interval = defaults.double(forKey: Key.refreshInterval)
        if interval >= 1 { refreshInterval = interval }
        alertsEnabled = defaults.object(forKey: Key.alertsEnabled) as? Bool ?? false
        let threshold = defaults.double(forKey: Key.alertThresholdPercent)
        if threshold >= 100 { alertThresholdPercent = threshold }
        let sustained = defaults.integer(forKey: Key.alertSustainedMinutes)
        if sustained >= 1 { alertSustainedMinutes = sustained }
        if let webhook = defaults.string(forKey: Key.alertWebhookURL) {
            alertWebhookURL = webhook
            alerts.webhookURL = webhook
        }
        shareWithIPhone = defaults.object(forKey: Key.shareWithIPhone) as? Bool ?? false
        allowRemoteQuit = defaults.object(forKey: Key.allowRemoteQuit) as? Bool ?? false
        if let code = defaults.string(forKey: Key.companionCode), !code.isEmpty {
            companionCode = code
        } else {
            companionCode = CompanionToken.make()
            defaults.set(companionCode, forKey: Key.companionCode)
        }
        if let peer = defaults.string(forKey: Key.companionPeerID), !peer.isEmpty {
            companionPeerID = peer
        } else {
            companionPeerID = UUID().uuidString
            defaults.set(companionPeerID, forKey: Key.companionPeerID)
        }
    }

    // MARK: - Infisical SOT

    /// Applies Infisical values over the local settings for the migrated
    /// knobs.  Infisical is the source of truth: a present value wins over
    /// UserDefaults.  Runs at launch (no-op until the first refresh lands)
    /// and after every successful background refresh.  See INFISICAL.md.
    private func applyInfisicalOverrides() {
        let cache = InfisicalStore.shared
        applyingInfisical = true
        defer { applyingInfisical = false }
        if let interval = cache.double(for: InfisicalKey.refreshInterval), interval >= 1 {
            refreshInterval = interval
        }
        if let threshold = cache.double(for: InfisicalKey.alertThresholdPercent), threshold >= 100 {
            alertThresholdPercent = threshold
        }
        if let sustained = cache.int(for: InfisicalKey.alertSustainedMinutes), sustained >= 1 {
            alertSustainedMinutes = sustained
        }
        // An empty webhook in Infisical means "not filled by admin yet" -- it
        // must never wipe a locally configured URL.
        if let webhook = cache.string(for: InfisicalKey.alertWebhookURL),
           !webhook.isEmpty, webhook != alertWebhookURL {
            alertWebhookURL = webhook
        }
    }

    @objc private func infisicalDidRefresh() {
        Task { @MainActor [weak self] in
            self?.applyInfisicalOverrides()
        }
    }

    /// Write-through for a migrated knob the admin just changed.  The PATCH
    /// to Infisical happens first inside `InfisicalSettings.set`; the local
    /// cache updates only after it succeeds.  A failed write keeps the local
    /// value (the app stays usable offline) and surfaces on
    /// `InfisicalSettings.lastError` for the Advanced tab -- never silent --
    /// and the next successful refresh re-asserts the Infisical value.
    private func writeThroughInfisical(key: String, value: String) {
        guard !loadingSettings, !applyingInfisical else { return }
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            try? await InfisicalSettings.shared.set(value, forKey: key)
        }
    }

    private func persist() {
        guard !loadingSettings else { return }
        defaults.set(window.rawValue, forKey: Key.window)
        defaults.set(grouping.rawValue, forKey: Key.grouping)
        defaults.set(sort.rawValue, forKey: Key.sort)
        defaults.set(cpuScale.rawValue, forKey: Key.cpuScale)
        defaults.set(menuBarLabelMode.rawValue, forKey: Key.menuBarLabelMode)
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
        defaults.set(alertsEnabled, forKey: Key.alertsEnabled)
        defaults.set(alertThresholdPercent, forKey: Key.alertThresholdPercent)
        defaults.set(alertSustainedMinutes, forKey: Key.alertSustainedMinutes)
        defaults.set(alertWebhookURL, forKey: Key.alertWebhookURL)
        defaults.set(appearance.rawValue, forKey: Key.appearance)
        defaults.set(shareWithIPhone, forKey: Key.shareWithIPhone)
        defaults.set(allowRemoteQuit, forKey: Key.allowRemoteQuit)
    }

    /// Asks for notification permission the moment alerts are switched on, and
    /// never before.  The Settings path goes through `defaultsChanged`.
    private func alertsSwitched() {
        guard !loadingSettings, alertsEnabled else { return }
        alerts.requestAuthorization()
    }

    /// Picks up changes a Settings view made through `@AppStorage` on the same
    /// keys.  Values are only assigned when they actually differ, so this
    /// cannot loop against `persist()`.
    @objc private func defaultsChanged() {
        Task { @MainActor [weak self] in
            guard let self, !self.loadingSettings else { return }
            self.loadingSettings = true
            defer { self.loadingSettings = false }
            if let raw = self.defaults.string(forKey: Key.window),
               let value = TimeWindow(rawValue: raw), value != self.window {
                self.window = value
            }
            if let raw = self.defaults.string(forKey: Key.grouping),
               let value = HogGrouping(rawValue: raw), value != self.grouping {
                self.grouping = value
            }
            if let raw = self.defaults.string(forKey: Key.sort),
               let value = HogSort(rawValue: raw), value != self.sort {
                self.sort = value
            }
            if let raw = self.defaults.string(forKey: Key.cpuScale),
               let value = CpuScale(rawValue: raw), value != self.cpuScale {
                self.cpuScale = value
            }
            if let raw = self.defaults.string(forKey: Key.menuBarLabelMode),
               let value = MenuBarLabelMode(rawValue: raw), value != self.menuBarLabelMode {
                self.menuBarLabelMode = value
            }
            if let raw = self.defaults.string(forKey: Key.appearance),
               let value = AppearanceChoice(rawValue: raw), value != self.appearance {
                self.appearance = value
            }
            let interval = self.defaults.double(forKey: Key.refreshInterval)
            if interval >= 1, interval != self.refreshInterval {
                self.refreshInterval = interval
            }
            let enabled = self.defaults.object(forKey: Key.alertsEnabled) as? Bool ?? false
            if enabled != self.alertsEnabled {
                self.alertsEnabled = enabled
                if enabled { self.alerts.requestAuthorization() }
            }
            let threshold = self.defaults.double(forKey: Key.alertThresholdPercent)
            if threshold >= 100, threshold != self.alertThresholdPercent {
                self.alertThresholdPercent = threshold
            }
            let sustained = self.defaults.integer(forKey: Key.alertSustainedMinutes)
            if sustained >= 1, sustained != self.alertSustainedMinutes {
                self.alertSustainedMinutes = sustained
            }
            if let webhook = self.defaults.string(forKey: Key.alertWebhookURL), webhook != self.alertWebhookURL {
                self.alertWebhookURL = webhook
                self.alerts.webhookURL = webhook
            }
            let sharing = self.defaults.object(forKey: Key.shareWithIPhone) as? Bool ?? false
            if sharing != self.shareWithIPhone {
                self.shareWithIPhone = sharing
            }
            let remoteQuit = self.defaults.object(forKey: Key.allowRemoteQuit) as? Bool ?? false
            if remoteQuit != self.allowRemoteQuit {
                self.allowRemoteQuit = remoteQuit
            }
        }
    }

    // MARK: - Companion Handlers

    private func setupCompanionHandlers() {
        companionServer.allowRemoteQuit = allowRemoteQuit
        companionServer.onRemoteQuit = { [weak self] pid, force in
            guard let self else {
                return (500, Data("{\"error\": \"Store unavailable\"}".utf8))
            }
            return self.performRemoteQuit(pid: pid, force: force)
        }
        companionServer.onRemoteTame = { [weak self] pid, action in
            guard let self else {
                return (500, Data("{\"error\": \"Store unavailable\"}".utf8))
            }
            return self.performRemoteTame(pid: pid, action: action)
        }
        companionServer.onRemoteExclusionsUpdate = { [weak self] req in
            guard let self else {
                return (500, Data("{\"error\": \"Store unavailable\"}".utf8))
            }
            return self.performRemoteExclusionsUpdate(req)
        }
        companionServer.onRemoteViewUpdate = { [weak self] req in
            guard let self else {
                return (500, Data("{\"error\": \"Store unavailable\"}".utf8))
            }
            return self.performRemoteViewUpdate(req)
        }
    }

    private func performRemoteExclusionsUpdate(_ req: CompanionExclusionsUpdateRequest) -> (status: Int, body: Data) {
        var current = CleanerExclusions.load()
        if let catId = req.toggleCategory, let cat = CleanCategory(rawValue: catId) {
            current.toggleCategory(cat)
        }
        if let path = req.addPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.addPath(path)
        }
        if let path = req.removePath {
            current.removePath(path)
        }
        current.save()
        DispatchQueue.main.async { [weak self] in
            self?.publishCompanion()
        }
        let resp = CompanionExclusionsUpdateResponse(
            status: "ok",
            excludedCategories: Array(current.excludedCategories),
            excludedPaths: Array(current.excludedPaths).sorted(),
            message: "Exclusions updated."
        )
        let data = (try? JSONEncoder().encode(resp)) ?? Data("{}".utf8)
        return (200, data)
    }

    private func performRemoteViewUpdate(_ req: CompanionViewUpdateRequest) -> (status: Int, body: Data) {
        var targetWindow: TimeWindow?
        if let win = req.window {
            if win.caseInsensitiveCompare("now") == .orderedSame {
                targetWindow = .now
            } else if win.caseInsensitiveCompare("1h") == .orderedSame || win.caseInsensitiveCompare("1 Hour") == .orderedSame || win.caseInsensitiveCompare("Past Hour") == .orderedSame || win.caseInsensitiveCompare("Past 1 Hour") == .orderedSame {
                targetWindow = .hour
            } else if win.caseInsensitiveCompare("24h") == .orderedSame || win.caseInsensitiveCompare("24 Hours") == .orderedSame || win.caseInsensitiveCompare("Past 24 Hours") == .orderedSame || win.caseInsensitiveCompare("day") == .orderedSame {
                targetWindow = .day
            }
        }

        var targetGrouping: HogGrouping?
        if let grp = req.grouping {
            if grp.caseInsensitiveCompare("apps") == .orderedSame {
                targetGrouping = .apps
            } else if grp.caseInsensitiveCompare("processes") == .orderedSame {
                targetGrouping = .processes
            }
        }

        var targetCpuScale: CpuScale?
        if let sc = req.cpuScale {
            if sc.lowercased().contains("machine") || sc.lowercased().contains("share") {
                targetCpuScale = .machineShare
            } else if sc.lowercased().contains("core") {
                targetCpuScale = .perCore
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let targetWindow { self.window = targetWindow }
            if let targetGrouping { self.grouping = targetGrouping }
            if let targetCpuScale { self.cpuScale = targetCpuScale }
            self.publishCompanion()
        }

        let resp = CompanionViewUpdateResponse(
            status: "ok",
            window: targetWindow?.rawValue ?? req.window ?? "now",
            grouping: targetGrouping?.rawValue ?? req.grouping ?? "apps",
            cpuScale: targetCpuScale?.rawValue ?? req.cpuScale ?? "machineShare",
            message: "View updated."
        )
        let data = (try? JSONEncoder().encode(resp)) ?? Data("{}".utf8)
        return (200, data)
    }

    private func performRemoteTame(pid: pid_t, action: String) -> (status: Int, body: Data) {
        let isTame = action.lowercased() == "tame"
        let result = isTame ? ProcessControl.tame(pid: pid) : ProcessControl.untame(pid: pid)
        let isNowTamed = ProcessControl.isTamed(pid: pid)
        let response = CompanionTameResponse(
            status: result.outcome.isAction ? "ok" : "blocked",
            pid: pid,
            name: result.name,
            isTamed: isNowTamed,
            message: result.outcome.isAction ? (isTame ? "Process tamed" : "Process restored") : "Action blocked",
            error: nil
        )
        let data = (try? JSONEncoder().encode(response)) ?? Data()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tick()
        }
        return (200, data)
    }

    private func performRemoteQuit(pid: pid_t, force: Bool) -> (status: Int, body: Data) {
        let result = ProcessControl.quit(pid: pid, force: force)
        let statusStr: String
        var errorStr: String? = nil
        var messageStr: String? = nil
        switch result.outcome {
        case .asked:
            statusStr = "asked"
            messageStr = "Quit signal sent to \(result.name)."
        case .forced:
            statusStr = "forced"
            messageStr = "Force quit signal sent to \(result.name)."
        case .changed:
            statusStr = "changed"
            errorStr = "\(result.name) is no longer running or changed PID."
        case .blocked(let reason):
            statusStr = "blocked"
            errorStr = "Cannot quit \(result.name): \(reason)."
        case .failed(let reason):
            statusStr = "failed"
            errorStr = "Failed to quit \(result.name): \(reason)."
        }
        let response = CompanionQuitResponse(
            status: statusStr,
            pid: pid,
            name: result.name,
            message: messageStr,
            error: errorStr
        )
        if let data = try? CompanionJSON.encoder().encode(response) {
            let httpStatus = (result.outcome.isAction) ? 200 : 400
            return (httpStatus, data)
        }
        return (500, Data("{\"error\": \"Failed to encode response\"}".utf8))
    }

    // MARK: - iPhone companion

    func regenerateCompanionCode() {
        companionCode = CompanionToken.make()
        defaults.set(companionCode, forKey: Key.companionCode)
        companionServer.updateToken(companionCode)
    }

    private var companionDisplayName: String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return "This Mac"
    }

    var companionPort: UInt16 { companionServer.activePort }

    private func syncCompanion() {
        guard shareWithIPhone else {
            companionServer.stop()
            companionStatus = "Off"
            return
        }
        companionStatus = "Starting"
        let name = companionDisplayName
        companionServer.start(name: name, peerID: companionPeerID, token: companionCode) { [weak self] status in
            Task { @MainActor in
                self?.companionStatus = status
            }
        }
        publishCompanion()
    }

    private func publishCompanion() {
        guard shareWithIPhone else { return }
        let sampledAt = pulse.sampledAt == .distantPast ? Date() : pulse.sampledAt
        let snapshot = CompanionSnapshotBuilder.make(
            hostName: companionDisplayName,
            sampledAt: sampledAt,
            hasBaseline: hasBaseline,
            window: window,
            grouping: grouping,
            scale: cpuScale,
            pulse: pulse,
            rows: rows
        )
        companionServer.update(snapshot: snapshot)
    }

    // MARK: - Staleness

    /// Called by the panel's timer-free redraws; cheap enough to run often.
    func refreshStaleness(now: Date = Date()) {
        isStale = pulse.sampledAt != .distantPast
            && now.timeIntervalSince(pulse.sampledAt) > 3 * refreshInterval
    }
}
