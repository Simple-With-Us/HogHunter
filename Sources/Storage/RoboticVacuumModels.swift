import Foundation

/// JSON shapes written by `scripts/robotic-vacuum.py` for the UI and MCP.
struct RoboticVacuumStatus: Codable, Equatable {
    var health: String
    var launchdLoaded: Bool
    var nextRunAt: [String: Double]
    var intervalsSeconds: [String: Double]
    var lastRunAt: [String: Double]?
    var lastRun: RoboticVacuumRun?
    var stepLastResults: [String: RoboticVacuumStepResult]
    var historyCount: Int
    var updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case health
        case launchdLoaded = "launchd_loaded"
        case nextRunAt = "next_run_at"
        case intervalsSeconds = "intervals_seconds"
        case lastRunAt = "last_runs"
        case lastRun = "last_run"
        case stepLastResults = "step_last_results"
        case historyCount = "history_count"
        case updatedAt = "updated_at"
    }

    var displayHealth: String {
        switch health {
        case "healthy": return "On schedule"
        case "overdue": return "Overdue"
        case "failed": return "Needs attention"
        case "unloaded": return "Not running in background"
        default: return health.capitalized
        }
    }
}

struct RoboticVacuumRun: Codable, Equatable {
    var runId: String
    var trigger: String
    var startedAt: Double
    var endedAt: Double
    var bytesFreed: Int
    var exitCode: Int
    var steps: [RoboticVacuumStepResult]
    /// How the run ended, as the engine recorded it: "ok", "partial" (a step
    /// failed and another did its work, so the run exits 0) or "failed".
    /// Nil for a record written before the engine kept the field.
    var outcome: String? = nil

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case trigger
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case bytesFreed = "bytes_freed"
        case exitCode = "exit_code"
        case steps
        case outcome
    }
}

extension RoboticVacuumRun {
    /// The trigger of the five minute tick.
    static let watchTrigger = "watch"

    /// The only steps a tick records when it just looked: the disk and memory
    /// check, or the lock being held by another run.
    private static let lookOnlyStepIds: Set<String> = ["resource_sample", "housekeeper_lock"]

    /// "ok", "partial" or "failed".  The run's recorded outcome, so a partial
    /// run (exit 0) is told from a clean one; a record from before the field
    /// existed, or one holding a word this build does not know, is judged by
    /// its exit code.  A non-zero exit is always failed, as in the engine.
    var resolvedOutcome: String {
        CompanionVacuumRunResult.resolve(exitCode: exitCode, outcome: outcome).rawValue
    }

    /// A watch tick the engine took no further action on.  Most ticks are.
    /// One that found the disk or memory in trouble goes on to run cleaning
    /// steps under the same record, and that is a cleaning run (see
    /// `isCleaningRun`), not a check.
    var isCheckOnly: Bool {
        trigger == Self.watchTrigger && steps.allSatisfy { Self.lookOnlyStepIds.contains($0.stepId) }
    }

    /// A watch tick that went on to clean: the engine records the pressure
    /// clean's steps inside the tick that asked for it.
    var escalatedToCleaning: Bool {
        trigger == Self.watchTrigger && !isCheckOnly
    }

    /// Janitor, full, manual and pressure runs, and a watch tick that
    /// escalated.  The quiet tick is not one.
    var isCleaningRun: Bool { !isCheckOnly }

    /// A watch tick that took its look.  One that found the lock held did not
    /// (the engine does not count it as a tick either).
    var isCheck: Bool {
        trigger == Self.watchTrigger && !steps.contains { $0.stepId == "housekeeper_lock" }
    }

    /// The kind to show for the run.  An escalated tick says "pressure",
    /// which is what its steps ran as, so it is not mistaken for a quiet tick.
    var displayTrigger: String {
        escalatedToCleaning ? "pressure" : trigger
    }

    /// When the run ended, or started for one that never wrote an end time.
    var finishedOrStartedAt: Date? {
        let epoch = endedAt > 0 ? endedAt : startedAt
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }
}

struct RoboticVacuumStepResult: Codable, Equatable, Identifiable {
    var stepId: String
    var title: String
    var status: String
    var reason: String
    var bytesFreed: Int
    var durationMs: Int

    var id: String { stepId }

    enum CodingKeys: String, CodingKey {
        case stepId = "step_id"
        case title
        case status
        case reason
        case bytesFreed = "bytes_freed"
        case durationMs = "duration_ms"
    }

    var statusLabel: String {
        switch status {
        case "ran": return "Done"
        case "skipped": return "Skipped"
        case "failed": return "Failed"
        default: return status.capitalized
        }
    }
}

struct RoboticVacuumStepCatalogEntry: Identifiable, Sendable {
    let id: String
    let title: String
}
