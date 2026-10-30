import AppKit
import Combine
import CoreFoundation
import Foundation

/// Reads Maintain status from the on-disk store the Python engine maintains.
///
/// One instance lives in `HogStore` and is shared by the Mac's Storage tab and
/// the iPhone route, so a run started from either is the only run: neither can
/// start a second over the other.
@MainActor
final class MaintainStore: ObservableObject {
    /// Runs `scripts/maintain.py` with these arguments and reports
    /// whether it exited cleanly.  Throws when the script could not be
    /// started.  Injected so no test ever launches the real script, whose
    /// full run retires git worktrees and trims caches on this Mac.
    typealias Launcher = @Sendable (_ scriptArguments: [String]) async throws -> Bool

    @Published private(set) var status: MaintainStatus?
    /// The engine's recent runs, newest first, every kind: the quiet five
    /// minute checks too, which the Mac's Recent Runs line sums up and the
    /// list leaves out (see `CompanionMaintain.recentRuns` and `.watch`).  The
    /// checks are most of the file, so reading only the newest few would push
    /// the cleaning runs out of the list within hours.
    @Published private(set) var history: [MaintainRun] = []
    @Published private(set) var stepToggles: [String: Bool] = [:]
    /// True when the step toggles on disk and in Infisical match what the
    /// panel shows.  A save takes a moment, and "Run Now" must not reach the
    /// script before the step it runs is really on.
    @Published private(set) var stepTogglesPersisted: Bool = true
    @Published private(set) var isRunningNow = false
    @Published var lastError: String?

    // Custom scripts & plugins
    @Published private(set) var customScripts: [MaintainScriptEntry] = []

    // Maintenance tuning knobs
    @Published var lowFreeGiB: Double = 80.0
    @Published var worktreeRetireMinDays: Int = 7
    @Published private(set) var worktreeRetireDaysPersisted = true
    @Published var pm2LogsCapMB: Int = 50
    @Published var coolifySSHHost: String = ""
    @Published var customDerivedDataPath: String = ""
    @Published var toolPaths: [String: String] = [:]

    let vpsStore: VPSStatusStore

    private var timer: Timer?
    private let statusURL: URL
    private let historyURL: URL
    private let configURL: URL
    private let launcher: Launcher
    /// The Infisical owner and its cache.  The app uses the shared pair; tests
    /// inject their own so no test reads the app's real settings or the network.
    private let infisical: InfisicalSettings
    private let infisicalStore: InfisicalStore
    /// When the files were last read, so a caller that only wants fresh
    /// enough data can skip the read.
    private(set) var lastRefreshAt = Date.distantPast

    /// `supportDirectory`, `repoRoot`, `launcher`, `infisical` and
    /// `infisicalStore` exist for tests, which point the store at a temporary
    /// folder, a stub script launcher and a stubbed Infisical.  The app uses the
    /// defaults.
    init(
        supportDirectory: URL? = nil,
        repoRoot: URL? = nil,
        fileManager: FileManager = .default,
        launcher: Launcher? = nil,
        infisical: InfisicalSettings? = nil,
        infisicalStore: InfisicalStore? = nil,
        vpsFetcher: VPSStatusStore.Fetcher? = nil
    ) {
        let support = supportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter/Maintain", isDirectory: true)
        statusURL = support.appendingPathComponent("status.json")
        historyURL = support.appendingPathComponent("history.json")
        configURL = support.appendingPathComponent("config.json")
        MaintainStore.migrateLegacySupportIfNeeded(to: support, fileManager: fileManager)
        let root = repoRoot ?? MaintainStore.locateRepoRoot()
        self.infisical = infisical ?? InfisicalSettings.shared
        self.infisicalStore = infisicalStore ?? InfisicalStore.shared
        self.launcher = launcher ?? MaintainStore.pythonLauncher(repoRoot: root, infisicalStore: self.infisicalStore)
        self.vpsStore = VPSStatusStore(fetcher: vpsFetcher)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(infisicalDidRefresh),
            name: .infisicalSettingsDidRefresh,
            object: nil
        )
        refresh()
    }

    /// Convenience initializer for tests passing a trailing closure launcher.
    convenience init(
        supportDirectory: URL? = nil,
        repoRoot: URL? = nil,
        fileManager: FileManager = .default,
        launcher: @escaping Launcher
    ) {
        self.init(
            supportDirectory: supportDirectory,
            repoRoot: repoRoot,
            fileManager: fileManager,
            launcher: launcher,
            infisical: nil,
            infisicalStore: nil,
            vpsFetcher: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func infisicalDidRefresh() {
        refresh()
    }

    /// Pre-rename builds wrote `HogHunter/RoboticVacuum/`.  The JSON shape
    /// is the same, so a one-shot move keeps recent-run history and status
    /// instead of looking like a fresh install.
    static func migrateLegacySupportIfNeeded(to support: URL, fileManager: FileManager) {
        let newStatus = support.appendingPathComponent("status.json")
        guard !fileManager.fileExists(atPath: newStatus.path) else { return }
        let legacyRoot = support.deletingLastPathComponent()
            .appendingPathComponent("RoboticVacuum", isDirectory: true)
        let legacyStatus = legacyRoot.appendingPathComponent("status.json")
        guard fileManager.fileExists(atPath: legacyStatus.path) else { return }
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        for name in ["status.json", "history.json", "config.json"] {
            let src = legacyRoot.appendingPathComponent(name)
            let dest = support.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path),
                  !fileManager.fileExists(atPath: dest.path) else { continue }
            try? fileManager.moveItem(at: src, to: dest)
        }
    }

    /// The server readings are the store's own business: it polls whenever a
    /// host is configured, so the panel and the Maintain tab never have to
    /// hand out shares, and a view that is hidden without being torn down
    /// cannot leave a counter stuck.
    func startPolling() {
        stopPolling()
        // The store may have been built hours ago (it is shared and lives with
        // the app), so a view that opens reads the files now instead of
        // showing launch-time status for the first half minute.
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        lastRefreshAt = Date()
        status = loadStatus()
        history = loadHistory()
        // The config first: loadStepToggles walks visibleCatalog, which reads
        // coolifyHost, so the host has to be current before the toggles load.
        loadMaintainConfig()
        stepToggles = loadStepToggles()
        customScripts = MaintainRegistryStore.loadScripts()
    }

    private func loadMaintainConfig() {
        let json = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let lanes = json?["lanes"] as? [String: Any]
        let fileRetireDays = Self.validRetireDays(lanes?["retire_min_days"]) ?? 7
        let infisicalRetireText = infisical.isConfigured
            ? infisicalStore.string(for: InfisicalKey.maintainJanitorRetireMinDays)
            : nil
        let retireDays = infisicalRetireText.map { Self.validRetireDays($0) ?? 7 } ?? fileRetireDays
        if worktreeRetireDaysPersisted, worktreeRetireMinDays != retireDays {
            worktreeRetireMinDays = retireDays
        }
        // Keep launchd's config-file fallback aligned with a value refreshed
        // from Infisical while the app is open.
        if worktreeRetireDaysPersisted, infisicalRetireText != nil, fileRetireDays != retireDays {
            Self.writeRetireDays(retireDays, to: configURL)
        }
        // Set even when the file or key is missing, so a host removed on disk
        // reads empty here too, as the old read-on-every-access getter did.
        // Infisical is the source of truth: a non-empty host there wins once
        // the settings are configured, and the file is the fallback.
        let fileHost = (json?["coolify_ssh_host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let infisicalHost = infisical.isConfigured
            ? (infisicalStore.string(for: InfisicalKey.maintainCoolifySshHost) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let host = infisicalHost.isEmpty ? fileHost : infisicalHost
        if coolifyHost != host {
            coolifyHost = host
            vpsStore.setHost(host)
        } else if vpsStore.configuredHost != host {
            vpsStore.setHost(host)
        }
        // The Maintenance tab's host field edits this copy and saves it
        // through setCoolifyHost, so it shows the same resolved host.
        if coolifySSHHost != host { coolifySSHHost = host }
        guard let json else { return }
        if let jan = json["janitor"] as? [String: Any], let low = jan["low_free_gib"] as? Double {
            lowFreeGiB = low
        }
        if let cap = json["pm2_logs_cap_mb"] as? Int {
            pm2LogsCapMB = cap
        }
        if let xcode = json["xcode_derived_data_path"] as? String {
            customDerivedDataPath = xcode
        }
        if let paths = json["tool_paths"] as? [String: String] {
            toolPaths = paths
        }
    }

    func saveMaintainConfig() {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var jan = json["janitor"] as? [String: Any] ?? [:]
        jan["low_free_gib"] = lowFreeGiB
        json["janitor"] = jan

        json["pm2_logs_cap_mb"] = pm2LogsCapMB
        // No coolify_ssh_host here: a host save goes through setCoolifyHost,
        // which writes Infisical first and only then the local file.
        json["xcode_derived_data_path"] = customDerivedDataPath
        json["tool_paths"] = toolPaths

        if let outData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? outData.write(to: configURL, options: .atomic)
        }
        refresh()
    }

    /// Writes the retention knob to Infisical first when configured, then
    /// mirrors it to config.json for launchd's standalone Python scheduler.
    func saveWorktreeRetireMinDays() {
        guard (1...90).contains(worktreeRetireMinDays) else {
            worktreeRetireMinDays = 7
            return
        }
        worktreeRetireDaysPersisted = false
        let value = worktreeRetireMinDays
        let infisical = self.infisical
        let previous = worktreeRetireTask
        previous?.cancel()
        worktreeRetireTask = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self else { return }
            if infisical.isConfigured {
                do {
                    try await infisical.set(
                        String(value),
                        forKey: InfisicalKey.maintainJanitorRetireMinDays,
                        expectedGeneration: infisical.connectionGeneration
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    self.lastError = Self.infisicalSaveFailure("the merged worktree retention", error: error)
                    self.worktreeRetireDaysPersisted = true
                    self.refresh()
                    return
                }
            }
            guard !Task.isCancelled else { return }
            Self.writeRetireDays(value, to: self.configURL)
            self.lastError = nil
            self.worktreeRetireDaysPersisted = true
            self.refresh()
        }
    }

    private var worktreeRetireTask: Task<Void, Never>?

    private static func validRetireDays(_ value: Any?) -> Int? {
        let parsed: Int?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
            parsed = Int(exactly: double)
        } else if let string = value as? String, let int = Int(string), string == String(int) {
            parsed = int
        } else {
            parsed = nil
        }
        guard let parsed, (1...90).contains(parsed) else { return nil }
        return parsed
    }

    private static func writeRetireDays(_ days: Int, to configURL: URL) {
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var json = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var lanes = json["lanes"] as? [String: Any] ?? [:]
        lanes["retire_min_days"] = days
        json["lanes"] = lanes
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    func setToolPath(toolId: String, path: String) {
        toolPaths[toolId] = path
        saveMaintainConfig()
    }

    func revealScriptsFolder() {
        MaintainRegistryStore.ensureDirectoriesExist()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: MaintainRegistryStore.scriptsDirectory.path)
    }

    func openRegistryFile() {
        NSWorkspace.shared.open(MaintainRegistryStore.registryURL)
    }

    /// Reads the files only when the last read is older than `maxAge`.  The
    /// iPhone route calls this each time a phone polls, so the files are read
    /// at most every `maxAge` seconds and only while a phone is looking.
    func refreshIfStale(maxAge: TimeInterval = 30, now: Date = Date()) {
        guard now.timeIntervalSince(lastRefreshAt) >= maxAge else { return }
        refresh()
    }

    /// Starts a run unless one is going.  Returns the task that ends when the
    /// run does (nil when a run was already going), so a test can wait for it.
    @discardableResult
    func runNow(_ kind: String) -> Task<Void, Never>? {
        guard !isRunningNow else { return nil }
        isRunningNow = true
        lastError = nil
        let launcher = self.launcher
        return Task { [weak self] in
            let outcome: Result<Bool, Error>
            do {
                outcome = .success(try await launcher(["--run-now", kind]))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            switch outcome {
            case .success(true):
                break
            case .success(false):
                self.lastError = "Cleaning did not finish cleanly.\u{00A0} Check Logs for details."
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isRunningNow = false
            self.refresh()
        }
    }

    /// Runs one named step and nothing else.
    ///
    /// The server scope of the panel is display-only, so the owner had no way to
    /// run the one step that acts on a remote host.  This calls the CLI's
    /// `--run-step`, which takes the same housekeeper lock the scheduled tick
    /// takes, so a step can never run over a tick.
    ///
    /// The step's own on/off toggle still governs it: the CLI refuses a step
    /// that is off, so the panel enables the step first and the owner sees the
    /// same switch the Mac's Maintenance tab has.
    @discardableResult
    func runStep(_ stepId: String) -> Task<Void, Never>? {
        guard !isRunningNow else { return nil }
        isRunningNow = true
        lastError = nil
        let launcher = self.launcher
        return Task { [weak self] in
            let outcome: Result<Bool, Error>
            do {
                outcome = .success(try await launcher(["--run-step", stepId]))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            switch outcome {
            case .success(true):
                break
            case .success(false):
                self.lastError = "That step did not finish cleanly.\u{00A0} Check Logs for details."
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isRunningNow = false
            self.refresh()
        }
    }

    func setStepEnabled(_ stepId: String, enabled: Bool) {
        stepToggles[stepId] = enabled
        // The toggle is not on the Mac's disk until the save lands, and the
        // script refuses a step that is still off, so "Run Now" waits for the
        // save rather than racing it.
        stepTogglesPersisted = false
        let launcher = self.launcher
        let infisical = self.infisical
        Task { [weak self] in
            if infisical.isConfigured {
                let gen = infisical.connectionGeneration
                do {
                    try await infisical.set(
                        enabled ? "true" : "false",
                        forKey: "\(InfisicalKey.maintainStepPrefix)\(stepId)",
                        expectedGeneration: gen
                    )
                } catch {
                    // Infisical is the source of truth, so a failed write-through is a
                    // failed save: skip the local write and reload the unchanged value.
                    // Carrying on would let the refresh read the stale Infisical value
                    // over the local one and flip the toggle back with no word.
                    guard let self else { return }
                    self.lastError = Self.infisicalSaveFailure("that step setting", error: error)
                    self.stepTogglesPersisted = true
                    self.refresh()
                    return
                }
            }
            let outcome: Result<Bool, Error>
            do {
                outcome = .success(try await launcher(["--set-step", stepId, enabled ? "on" : "off"]))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            switch outcome {
            case .success(true):
                self.lastError = nil
            case .success(false):
                self.lastError = "Could not save that step setting."
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.stepTogglesPersisted = true
            self.refresh()
        }
    }

    /// What the owner reads when Infisical refused a Maintain save.  Uses the
    /// settings owner's safe message, which never carries a response body.
    private static func infisicalSaveFailure(_ what: String, error: Error) -> String {
        "Could not save \(what) to Infisical.\u{00A0} \(InfisicalSettings.safeMessage(for: error))"
    }

    /// True inside an XCTest run.  The default launcher refuses to start the
    /// script there, so a test that forgets to inject a stub cannot clean
    /// this Mac.
    nonisolated static var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    struct LauncherRefused: LocalizedError {
        var errorDescription: String? { "The Maintain does not run from a test." }
    }

    /// The launcher the app uses: `/usr/bin/python3 scripts/maintain.py ...`.
    nonisolated static func pythonLauncher(repoRoot: URL, infisicalStore: InfisicalStore = .shared) -> Launcher {
        { arguments in
            guard !isRunningUnderTest else { throw LauncherRefused() }
            let maintain = repoRoot.appendingPathComponent("scripts/maintain.py")
            let legacy = repoRoot.appendingPathComponent("scripts/robotic-vacuum.py")
            let script = FileManager.default.fileExists(atPath: maintain.path) ? maintain : legacy
            return try await withCheckedThrowingContinuation { continuation in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = [script.path] + arguments
                var env = ProcessInfo.processInfo.environment
                let infisicalSnapshot = infisicalStore.snapshot
                if infisicalSnapshot.projectId != nil,
                   infisicalSnapshot.projectId != InfisicalStore.localProjectId,
                   let configured = infisicalSnapshot.values[InfisicalKey.maintainJanitorRetireMinDays],
                   let days = Int(configured), String(days) == configured, (1...90).contains(days) {
                    env["hoghunter.maintain.janitor.retireMinDays"] = configured
                }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let extraPaths = [
                    "/opt/homebrew/bin",
                    "/opt/homebrew/sbin",
                    "/usr/local/bin",
                    "/usr/local/sbin",
                    "\(home)/.local/bin"
                ]
                let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
                env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
                proc.environment = env

                // stderr goes to a temporary file, not a pipe: a pipe nobody
                // drains fills at 64 KB and blocks the script on its next
                // write, so it never exits and this continuation never
                // resumes.  A file never blocks the writer, and a background
                // child that inherits the descriptor cannot hold the read open.
                let errURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hoghunter-maintain-\(UUID().uuidString).stderr")
                let errHandle: FileHandle
                do {
                    guard FileManager.default.createFile(atPath: errURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: errURL.path])
                    }
                    errHandle = try FileHandle(forWritingTo: errURL)
                } catch {
                    // createFile may already have made the empty file before
                    // the open threw; removing a missing file is a no-op.
                    try? FileManager.default.removeItem(at: errURL)
                    continuation.resume(throwing: error)
                    return
                }
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errHandle
                proc.terminationHandler = { finished in
                    try? errHandle.close()
                    let errData = (try? Data(contentsOf: errURL)) ?? Data()
                    try? FileManager.default.removeItem(at: errURL)
                    if finished.terminationStatus == 0 {
                        continuation.resume(returning: true)
                    } else {
                        // The tail carries the traceback's last line; a whole
                        // 64 KB log is not an error message.
                        let raw = String(String(decoding: errData.suffix(4096), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .suffix(2000))
                        if !raw.isEmpty {
                            continuation.resume(throwing: NSError(
                                domain: "MaintainStore",
                                code: Int(finished.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: raw]
                            ))
                        } else {
                            continuation.resume(returning: false)
                        }
                    }
                }
                do {
                    try proc.run()
                } catch {
                    try? errHandle.close()
                    try? FileManager.default.removeItem(at: errURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated static let catalog: [MaintainStepCatalogEntry] = [
        MaintainStepCatalogEntry(
            id: "resource_sample",
            title: "Check Disk and Memory",
            description: "Samples CPU load, memory pressure, and free disk space against safety thresholds.",
            tooltip: "Samples host disk, memory, and CPU metrics against alert thresholds."
        ),
        MaintainStepCatalogEntry(
            id: "hoghunter_reclaim",
            title: "Hog Hunter Disk Reclaim",
            description: "Reclaims disk bloat according to Hog Hunter's automated rules.",
            tooltip: "Runs Hog Hunter's built-in disk cleanup rules."
        ),
        MaintainStepCatalogEntry(
            id: "janitor_worktree_retire",
            title: "Retire Old Merged Git Worktrees",
            description: "Safely cleans up stale git worktrees whose branches are merged into main.",
            tooltip: "Cleans up merged and idle git worktrees older than policy."
        ),
        MaintainStepCatalogEntry(
            id: "janitor_cache_reclaim",
            title: "Reclaim Caches Under Low Disk",
            description: "Prunes developer and build caches when free disk drops below threshold.",
            tooltip: "Frees build and temporary caches when disk space is tight."
        ),
        MaintainStepCatalogEntry(
            id: "pm2_logs",
            title: "Cap Oversized PM2 Logs",
            description: "Truncates PM2 daemon logs exceeding the configured cap to prevent unbounded disk usage.",
            tooltip: "Truncates oversized PM2 background process logs in place.",
            associatedTool: ToolCatalog.pm2
        ),
        MaintainStepCatalogEntry(
            id: "npm_cache",
            title: "Trim npm Download Cache",
            description: "Cleans npm download cache and unreferenced npx temporary binaries.",
            tooltip: "Trims global package manager caches when no builds are active.",
            associatedTool: ToolCatalog.npm
        ),
        MaintainStepCatalogEntry(
            id: "xcode_derived_data",
            title: "Clear Xcode Build Cache",
            description: "Cleans Xcode DerivedData caches that have not been modified recently.",
            tooltip: "Prunes stale Xcode DerivedData and module caches.",
            associatedTool: ToolCatalog.xcode
        ),
        MaintainStepCatalogEntry(
            id: "shutdown_simulators",
            title: "Shut Down Xcode Simulators",
            description: "Shuts down booted iOS Simulators when no build, test, or Simulator.app is running.",
            tooltip: "Shuts down booted iOS Simulators when no build is running (preserving 1 simulator for Bitrig).",
            associatedTool: ToolCatalog.xcode
        ),
        MaintainStepCatalogEntry(
            id: "simctl_delete_unavailable",
            title: "Remove Unavailable Simulator Runtimes",
            description: "Protects simulator devices and containers; runtime caches are safely cleared by the Simulator cache step.",
            tooltip: "Removes unavailable iOS simulator runtime remnants.",
            associatedTool: ToolCatalog.xcode
        ),
        MaintainStepCatalogEntry(
            id: "coolify_remote",
            title: "Remote Server Maintenance",
            description: "Performs remote Docker and system maintenance on configured host via SSH.",
            tooltip: "Runs remote maintenance over SSH (e.g. using an SSH alias, IP, or user@host) to prune unused Docker containers, images, and container logs."
        ),
        MaintainStepCatalogEntry(
            id: "cleanmymac_cli",
            title: "CleanMyMac CLI Sweep",
            description: "Runs non-interactive junk and purgeable sweeps using CleanMyMac CLI when installed.",
            tooltip: "Invokes the CleanMyMac CLI tool if installed locally.",
            associatedTool: ToolCatalog.cleanMyMac
        ),
    ]

    private func loadStatus() -> MaintainStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(MaintainStatus.self, from: data)
    }

    private func loadHistory() -> [MaintainRun] {
        guard let data = try? Data(contentsOf: historyURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { dict in
            guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(MaintainRun.self, from: d)
        }.reversed().prefix(Self.maxHistoryRuns).map { $0 }
    }

    /// The most runs read from the engine's history file.  The engine keeps
    /// 500 by default (`history_max_runs`, a bit over a day of five minute
    /// checks), so this reads all of them with room to spare.
    nonisolated static let maxHistoryRuns = 600

    /// Steps the engine keeps off until the owner turns them on.  Mirrors
    /// `DEFAULT_OFF_STEPS` in scripts/vacuum/config.py: the toggle must read
    /// off on a fresh install, or the tab promises a sweep the run skips.
    nonisolated static let defaultOffSteps: Set<String> = ["cleanmymac_cli", "coolify_remote"]

    /// Steps shown in the Maintain tab.  Remote server maintenance stays hidden until a host is configured.
    var visibleCatalog: [MaintainStepCatalogEntry] {
        guard coolifyRemoteConfigured else {
            return Self.catalog.filter { $0.id != "coolify_remote" }
        }
        return Self.catalog
    }

    func isStepEnabled(_ stepId: String) -> Bool {
        if let explicit = stepToggles[stepId] {
            return explicit
        }
        return !Self.defaultOffSteps.contains(stepId)
    }

    var activeCatalog: [MaintainStepCatalogEntry] {
        visibleCatalog.filter { isStepEnabled($0.id) }
    }

    /// The remote server SSH host, trimmed, as of the last `refresh()`:
    /// Infisical's `hoghunter.maintain.coolifySshHost` when the settings are
    /// configured and it is set, else `coolify_ssh_host` from config.json.
    /// Held in memory because the Settings view and
    /// `visibleCatalog` read it on every render, which re-read and parsed the
    /// file each time; `setCoolifyHost` refreshes it once the save lands.
    @Published private(set) var coolifyHost: String = ""

    private var coolifyHostTask: Task<Void, Never>?

    func setCoolifyHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let launcher = self.launcher
        let infisical = self.infisical
        // Cancelling a Task does not stop a script it already launched, so a
        // save waits for the previous one to finish before it launches its
        // own: an older run can never land after a newer one and overwrite
        // it.  The cancel still drops a save that has not launched yet.
        let previous = coolifyHostTask
        previous?.cancel()
        coolifyHostTask = Task { [weak self] in
            _ = await previous?.value
            // A newer save superseded this one while it waited: drop it before
            // it writes its older value to Infisical.
            if Task.isCancelled { return }
            if infisical.isConfigured {
                let gen = infisical.connectionGeneration
                do {
                    try await infisical.set(
                        trimmed,
                        forKey: InfisicalKey.maintainCoolifySshHost,
                        expectedGeneration: gen
                    )
                } catch {
                    // Same rule as `setStepEnabled`: a failed Infisical write is a failed
                    // save.  A newer edit that cancelled this one speaks for itself.
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.lastError = Self.infisicalSaveFailure("the remote server SSH host", error: error)
                    self.refresh()
                    return
                }
            }
            let outcome: Result<Bool, Error>
            do {
                if Task.isCancelled { return }
                outcome = .success(try await launcher(["--set-coolify-host", trimmed]))
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success(true):
                    self.lastError = nil
                case .success(false):
                    self.lastError = "Could not save remote server SSH host."
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    private var coolifyRemoteConfigured: Bool {
        return !coolifyHost.isEmpty
    }

    private func loadStepToggles() -> [String: Bool] {
        var toggles: [String: Bool] = [:]
        for entry in visibleCatalog {
            toggles[entry.id] = !Self.defaultOffSteps.contains(entry.id)
        }
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let steps = json["steps"] as? [String: [String: Bool]] {
            for (key, val) in steps {
                if let enabled = val["enabled"] {
                    toggles[key] = enabled
                }
            }
        }
        if infisical.isConfigured {
            for key in toggles.keys {
                if let infisVal = infisicalStore.bool(for: "\(InfisicalKey.maintainStepPrefix)\(key)") {
                    toggles[key] = infisVal
                }
            }
        }
        return toggles
    }

    private static func locateRepoRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["HOGHUNTER_REPO"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let bundle = Bundle.main.bundleURL
        for candidate in [
            bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code/HogHunter"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("apps/HogHunter"),
        ] {
            let maintain = candidate.appendingPathComponent("scripts/maintain.py")
            let legacy = candidate.appendingPathComponent("scripts/robotic-vacuum.py")
            if FileManager.default.fileExists(atPath: maintain.path)
                || FileManager.default.fileExists(atPath: legacy.path) {
                return candidate
            }
        }
        return bundle
    }

    func history24h(for stepId: String, now: Date = Date()) -> Step24hHistory {
        let dayAgo = now.timeIntervalSince1970 - 86400
        let runsIn24h = history.filter { $0.startedAt >= dayAgo }
        var samples: [StepOutcomeSample] = []
        var successes = 0
        var skips = 0
        var fails = 0
        var lastDate: Date? = nil

        // history is newest first
        for run in runsIn24h {
            if let stepResult = run.steps.first(where: { $0.stepId == stepId }) {
                let date = run.finishedOrStartedAt ?? Date(timeIntervalSince1970: run.startedAt)
                if lastDate == nil {
                    lastDate = date
                }
                if stepResult.status == "ran" {
                    successes += 1
                } else if stepResult.status == "failed" {
                    fails += 1
                } else {
                    skips += 1
                }
                samples.append(StepOutcomeSample(timestamp: date, status: stepResult.status, reason: stepResult.reason))
            }
        }

        return Step24hHistory(
            runsCount: samples.count,
            successCount: successes,
            skipCount: skips,
            failCount: fails,
            lastRunDate: lastDate,
            recentOutcomes: samples.reversed()
        )
    }
}

