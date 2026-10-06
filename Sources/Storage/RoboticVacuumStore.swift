import AppKit
import Combine
import Foundation

/// Reads Robotic Vacuum status from the on-disk store the Python engine maintains.
@MainActor
final class RoboticVacuumStore: ObservableObject {
    @Published private(set) var status: RoboticVacuumStatus?
    @Published private(set) var history: [RoboticVacuumRun] = []
    @Published private(set) var stepToggles: [String: Bool] = [:]
    @Published private(set) var isRunningNow = false
    @Published var lastError: String?

    private var timer: Timer?
    private let statusURL: URL
    private let historyURL: URL
    private let configURL: URL
    private let repoRoot: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter/RoboticVacuum", isDirectory: true)
        statusURL = support.appendingPathComponent("status.json")
        historyURL = support.appendingPathComponent("history.json")
        configURL = support.appendingPathComponent("config.json")
        repoRoot = RoboticVacuumStore.locateRepoRoot()
        refresh()
    }

    func startPolling() {
        stopPolling()
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
        status = loadStatus()
        history = loadHistory()
        stepToggles = loadStepToggles()
    }

    func runNow(_ kind: String) {
        guard !isRunningNow else { return }
        isRunningNow = true
        lastError = nil
        let script = repoRoot.appendingPathComponent("scripts/robotic-vacuum.py")
        Task.detached(priority: .utility) { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path, "--run-now", kind]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let failed = proc.terminationStatus != 0
                await MainActor.run {
                    if failed {
                        self?.lastError = "Cleaning did not finish cleanly.  Check Logs for details."
                    }
                    self?.isRunningNow = false
                    self?.refresh()
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isRunningNow = false
                    self?.refresh()
                }
            }
        }
    }

    func setStepEnabled(_ stepId: String, enabled: Bool) {
        stepToggles[stepId] = enabled
        let script = repoRoot.appendingPathComponent("scripts/robotic-vacuum.py")
        Task.detached(priority: .utility) { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path, "--set-step", stepId, enabled ? "on" : "off"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let failed = proc.terminationStatus != 0
                await MainActor.run {
                    if failed {
                        self?.lastError = "Could not save that step setting."
                    } else {
                        self?.lastError = nil
                    }
                    self?.refresh()
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }

    static let catalog: [RoboticVacuumStepCatalogEntry] = [
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
        }.reversed().prefix(30).map { $0 }
    }

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
