import Foundation

/// JSON shapes written by `scripts/robotic-vacuum.py` for the UI and MCP.
struct RoboticVacuumStatus: Codable, Equatable {
    var health: String
    var launchdLoaded: Bool
    var nextRunAt: [String: Double]
    var intervalsSeconds: [String: Double]
    var lastRun: RoboticVacuumRun?
    var stepLastResults: [String: RoboticVacuumStepResult]
    var historyCount: Int
    var updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case health
        case launchdLoaded = "launchd_loaded"
        case nextRunAt = "next_run_at"
        case intervalsSeconds = "intervals_seconds"
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

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case trigger
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case bytesFreed = "bytes_freed"
        case exitCode = "exit_code"
        case steps
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

struct RoboticVacuumStepCatalogEntry: Identifiable {
    let id: String
    let title: String
}
