import AppKit
import Combine
import Foundation

/// Reads Robotic Vacuum status from the on-disk store the Python engine maintains.
///
/// One instance lives in `HogStore` and is shared by the Mac's Storage tab and
/// the iPhone route, so a run started from either is the only run: neither can
/// start a second over the other.
@MainActor
final class RoboticVacuumStore: ObservableObject {
    /// Runs `scripts/robotic-vacuum.py` with these arguments and reports
    /// whether it exited cleanly.  Throws when the script could not be
    /// started.  Injected so no test ever launches the real script, whose
    /// full run retires git worktrees and trims caches on this Mac.
    typealias Launcher = @Sendable (_ scriptArguments: [String]) async throws -> Bool

    @Published private(set) var status: RoboticVacuumStatus?
    /// The engine's recent runs, newest first, every kind: the quiet five
    /// minute checks too, which the Mac's Recent Runs line sums up and the
    /// list leaves out (see `CompanionVacuum.recentRuns` and `.watch`).  The
    /// checks are most of the file, so reading only the newest few would push
    /// the cleaning runs out of the list within hours.
    @Published private(set) var history: [RoboticVacuumRun] = []
    @Published private(set) var stepToggles: [String: Bool] = [:]
    @Published private(set) var isRunningNow = false
    @Published var lastError: String?

    private var timer: Timer?
    private let statusURL: URL
    private let historyURL: URL
    private let configURL: URL
    private let launcher: Launcher
    /// When the files were last read, so a caller that only wants fresh
    /// enough data can skip the read.
    private(set) var lastRefreshAt = Date.distantPast

    /// `supportDirectory`, `repoRoot` and `launcher` exist for tests, which
    /// point the store at a temporary folder and a stub.  The app uses the
    /// defaults.
    init(supportDirectory: URL? = nil, repoRoot: URL? = nil, fileManager: FileManager = .default, launcher: Launcher? = nil) {
        let support = supportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter/RoboticVacuum", isDirectory: true)
        statusURL = support.appendingPathComponent("status.json")
        historyURL = support.appendingPathComponent("history.json")
        configURL = support.appendingPathComponent("config.json")
        let root = repoRoot ?? RoboticVacuumStore.locateRepoRoot()
        self.launcher = launcher ?? RoboticVacuumStore.pythonLauncher(repoRoot: root)
        refresh()
    }

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
        stepToggles = loadStepToggles()
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

    func setStepEnabled(_ stepId: String, enabled: Bool) {
        stepToggles[stepId] = enabled
        let launcher = self.launcher
        Task { [weak self] in
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
            self.refresh()
        }
    }

    /// True inside an XCTest run.  The default launcher refuses to start the
    /// script there, so a test that forgets to inject a stub cannot clean
    /// this Mac.
    nonisolated static var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    struct LauncherRefused: LocalizedError {
        var errorDescription: String? { "The Robotic Vacuum does not run from a test." }
    }

    /// The launcher the app uses: `/usr/bin/python3 scripts/robotic-vacuum.py ...`.
    nonisolated static func pythonLauncher(repoRoot: URL) -> Launcher {
        { arguments in
            guard !isRunningUnderTest else { throw LauncherRefused() }
            let script = repoRoot.appendingPathComponent("scripts/robotic-vacuum.py")
            return try await withCheckedThrowingContinuation { continuation in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = [script.path] + arguments
                // Not pipes: nothing reads them, and a script that writes
                // enough to fill one would stall for good.
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                proc.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus == 0)
                }
                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated static let catalog: [RoboticVacuumStepCatalogEntry] = [
        RoboticVacuumStepCatalogEntry(id: "resource_sample", title: "Check disk and memory"),
        RoboticVacuumStepCatalogEntry(id: "hoghunter_reclaim", title: "Hog Hunter disk reclaim"),
        RoboticVacuumStepCatalogEntry(id: "janitor_worktree_retire", title: "Retire old merged git worktrees"),
        RoboticVacuumStepCatalogEntry(id: "janitor_cache_reclaim", title: "Reclaim caches when disk is low"),
        RoboticVacuumStepCatalogEntry(id: "pm2_logs", title: "Cap oversized PM2 logs"),
        RoboticVacuumStepCatalogEntry(id: "npm_cache", title: "Trim npm download cache"),
        RoboticVacuumStepCatalogEntry(id: "xcode_derived_data", title: "Clear Xcode build cache"),
        RoboticVacuumStepCatalogEntry(id: "simctl_delete_unavailable", title: "Remove unavailable Simulator runtimes"),
        RoboticVacuumStepCatalogEntry(id: "coolify_remote", title: "Remote server maintenance"),
    ]

    private func loadStatus() -> RoboticVacuumStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(RoboticVacuumStatus.self, from: data)
    }

    private func loadHistory() -> [RoboticVacuumRun] {
        guard let data = try? Data(contentsOf: historyURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { dict in
            guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(RoboticVacuumRun.self, from: d)
        }.reversed().prefix(Self.maxHistoryRuns).map { $0 }
    }

    /// The most runs read from the engine's history file.  The engine keeps
    /// 500 by default (`history_max_runs`, a bit over a day of five minute
    /// checks), so this reads all of them with room to spare.
    nonisolated static let maxHistoryRuns = 600

    private func loadStepToggles() -> [String: Bool] {
        var toggles: [String: Bool] = [:]
        for entry in Self.catalog {
            toggles[entry.id] = true
        }
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = json["steps"] as? [String: [String: Bool]] else { return toggles }
        for (key, val) in steps {
            if let enabled = val["enabled"] {
                toggles[key] = enabled
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
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("scripts/robotic-vacuum.py").path) {
                return candidate
            }
        }
        return bundle
    }
}
