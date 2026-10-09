import Foundation

/// Bonjour service the Mac advertises and the iPhone browses.
/// The pairing code is never put in the TXT record.
enum CompanionService {
    static let type = "_hoghunter._tcp"
    static let path = "/v1/snapshot"
    static let cleanPath = "/v1/clean"
    static let quitPath = "/v1/quit"
    static let tamePath = "/v1/tame"
    static let exclusionsPath = "/v1/exclusions"
    static let viewPath = "/v1/view"
    /// Refresh interval, alerts and the webhook.  Behind the edit opt-in.
    static let settingsPath = "/v1/settings"
    /// Sample for 3 Seconds on one row.  Behind the process-control opt-in.
    static let samplePath = "/v1/sample"
    /// Starts a Robotic Vacuum run.  Behind its own opt-in: a run can retire
    /// old git worktrees and run maintenance on remote servers.
    static let vacuumRunPath = "/v1/vacuum/run"
    /// The only run the phone may start.  The Mac's script also knows
    /// cheaper cadences and a pressure run; none of them is reachable from here.
    static let vacuumRunKinds = ["full"]
    static let pairPath = "/v1/pair"
    /// Trades the shared pairing code for a token of the phone's own.
    static let enrollPath = "/v1/enroll"
    static let version = 1
}

/// Response returned when the iOS companion triggers a safe remote clean on the Mac.
struct CompanionCleanResponse: Codable, Equatable, Sendable {
    var status: String
    var bytesReclaimed: UInt64
    var formattedBytesReclaimed: String
    var itemsRemoved: Int
    var snapshotCreated: Bool
    var snapshotName: String?
    var tier: String
}

/// Live progress and status of an active or recently completed safe disk cleaning run.
struct CompanionCleanProgress: Codable, Equatable, Sendable {
    var isCleaning: Bool
    var phase: String
    var progress: Double
    var statusText: String
    var currentItem: String?
    var itemsCleaned: Int
    var totalItems: Int
    var bytesReclaimed: UInt64
    var formattedBytesReclaimed: String
    var snapshotName: String?
    var error: String?
}

extension Notification.Name {
    static let diskCleanerProgressChanged = Notification.Name("hoghunter.diskCleanerProgressChanged")
}

/// Update payload carrying clean progress and its unique execution run ID.
struct DiskCleanerProgressUpdate: Sendable {
    var runId: UUID
    var progress: CompanionCleanProgress
}

/// What a quit or tame request points at.  The phone sends the id of the row
/// it was looking at, so the Mac acts on that exact app or process.  A bare
/// pid is still accepted from an older phone.
struct CompanionProcessRequest: Equatable, Sendable {
    var rowId: String? = nil
    var pid: Int32? = nil

    var isAddressed: Bool { (rowId?.isEmpty == false) || pid != nil }
}

/// Response returned when the iOS companion asks to quit a process on the Mac.
struct CompanionQuitResponse: Codable, Equatable, Sendable {
    var status: String
    var pid: Int32
    var name: String
    var message: String?
    var error: String?
    /// How many processes of the row were signalled, and how many were left
    /// alone (changed since sampling, protected).  Nil from an older Mac.
    var acted: Int? = nil
    var skipped: Int? = nil
}

/// Response returned when the iOS companion asks to tame or untame a process on the Mac.
struct CompanionTameResponse: Codable, Equatable, Sendable {
    var status: String
    var pid: Int32
    var name: String
    var isTamed: Bool
    var message: String?
    var error: String?
    var acted: Int? = nil
    var skipped: Int? = nil
}

/// Request sent by the iOS companion to update cleaner category and folder exclusions on the Mac.
struct CompanionExclusionsUpdateRequest: Codable, Equatable, Sendable {
    var toggleCategory: String? = nil
    var addPath: String? = nil
    var removePath: String? = nil
}

/// Response returned after updating cleaner exclusions on the Mac.
struct CompanionExclusionsUpdateResponse: Codable, Equatable, Sendable {
    var status: String
    var excludedCategories: [String]
    var excludedPaths: [String]
    var message: String?
}

/// Request sent by the iOS companion to switch time window, grouping, or CPU scale on the Mac.
struct CompanionViewUpdateRequest: Codable, Equatable, Sendable {
    var window: String? = nil
    var grouping: String? = nil
    var cpuScale: String? = nil
}

/// Response returned after updating view settings on the Mac.
struct CompanionViewUpdateResponse: Codable, Equatable, Sendable {
    var status: String
    var window: String
    var grouping: String
    var cpuScale: String
    var message: String?
}

/// The values the Mac accepts for the settings a phone may change.  Shared so
/// the phone's pickers offer exactly what the Mac will take; the Mac checks
/// every value again, so a hand-built request gets no further.
enum CompanionSettingsLimits {
    /// The same choices as Settings > General > Refresh Every on the Mac.
    static let refreshIntervals: [Double] = [2, 3, 5, 10, 15]
    /// Per-core percent, the scale the alert compares against.
    static let alertThresholdRange: ClosedRange<Double> = 100...1000
    static let alertThresholdStep: Double = 50
    static let alertSustainedMinutesRange: ClosedRange<Int> = 1...30
    /// A webhook URL longer than this is not a webhook URL.
    static let webhookMaxLength = 2_048
}

/// Download and upload speed on the Mac, formatted the way the Network tab on
/// the Mac prints it.  The Mac does the formatting so both screens agree.
struct CompanionBandwidth: Codable, Equatable, Sendable {
    /// False until two counter readings far enough apart exist.
    var isMeasured: Bool
    var downBytesPerSecond: Double
    var upBytesPerSecond: Double
    var downText: String
    var upText: String
    /// "Measuring…" or "Last 25 s".
    var nowFootnote: String
    var peakDownBytesPerSecond: Double
    var peakUpBytesPerSecond: Double
    var peakDownText: String
    var peakUpText: String
    /// "No History Yet" or "Sampled 3h 12m".
    var peakFootnote: String
    /// When the 24-hour peak was reached, in words, or what the peak means.
    var peakHelp: String
    /// Set when the Mac could not read its interface counters.
    var error: String? = nil
}

/// The settings the phone may read and, with the edit opt-in, change.  The
/// webhook URL is the one secret among them, so it is never sent: the phone
/// learns whether one is set and which host it points at, and can replace or
/// clear it, but cannot read it back.
struct CompanionSettingsSummary: Codable, Equatable, Sendable {
    var refreshInterval: Double
    var alertsEnabled: Bool
    var alertThresholdPercent: Double
    var alertSustainedMinutes: Int
    var webhookConfigured: Bool
    /// The host of the webhook ("hooks.slack.com"), never its path.
    var webhookHost: String? = nil
    /// The outcome of the last webhook delivery, as the Mac shows it.
    var webhookStatus: String? = nil
    /// True when macOS has refused Hog Hunter permission to notify.
    var notificationsDenied: Bool? = nil
}

/// A change to the settings above.  Every field is optional; only the ones
/// present are applied.  An empty `webhookURL` clears the webhook.
struct CompanionSettingsUpdateRequest: Codable, Equatable, Sendable {
    var refreshInterval: Double? = nil
    var alertsEnabled: Bool? = nil
    var alertThresholdPercent: Double? = nil
    var alertSustainedMinutes: Int? = nil
    var webhookURL: String? = nil
    /// Sends one test message to the webhook the Mac holds after the other
    /// fields are applied.
    var testWebhook: Bool? = nil

    var isEmpty: Bool {
        refreshInterval == nil && alertsEnabled == nil && alertThresholdPercent == nil
            && alertSustainedMinutes == nil && webhookURL == nil && testWebhook != true
    }
}

struct CompanionSettingsUpdateResponse: Codable, Equatable, Sendable {
    var status: String
    var message: String?
    var error: String?
}

/// Response to Sample for 3 Seconds.  The report stays on the Mac; the phone
/// gets its name, its size and the busiest call sites.
struct CompanionSampleResponse: Codable, Equatable, Sendable {
    var status: String
    var name: String
    var message: String?
    var error: String?
    var fileName: String? = nil
    var bytes: Int? = nil
    /// The top of the report's "Sort by top of stack" section, a dozen lines at most.
    var summary: [String]? = nil
}

/// Response to a Robotic Vacuum run request.  The Mac answers at once: the run
/// carries on there and the phone watches the snapshot for its progress.
struct CompanionVacuumRunResponse: Codable, Equatable, Sendable {
    /// "started" or "busy" (a run is already going).
    var status: String
    var message: String? = nil
    var error: String? = nil
}

/// One step of the last Robotic Vacuum run.  Reasons can name lane folders and
/// servers, so the Mac sends steps only when the owner allowed the phone to
/// run the vacuum.
struct CompanionVacuumStep: Codable, Equatable, Identifiable, Sendable {
    var stepId: String
    var title: String
    /// "Done", "Skipped" or "Failed", as the Mac shows it.
    var statusLabel: String
    /// At most 120 characters.
    var reason: String
    var bytesFreed: Int

    var id: String { stepId }
}

/// Where the Robotic Vacuum stands: when it last ran and will next run, whether
/// its background job is loaded, and whether a run is going now.
struct CompanionVacuumStatus: Codable, Equatable, Sendable {
    /// The engine's own word: healthy, overdue, failed or unloaded.  "unknown"
    /// while the first run has not written a status yet.
    var health: String
    /// What the Mac prints for `health`.
    var displayHealth: String
    var launchdLoaded: Bool
    var isRunning: Bool
    var lastFullRunAt: Date? = nil
    var nextFullRunAt: Date? = nil
    var lastRunBytesFreed: Int? = nil
    var lastRunEndedAt: Date? = nil
    /// The last result of each step.  Nil unless the owner allowed the phone
    /// to run the vacuum.
    var steps: [CompanionVacuumStep]? = nil
}

/// Eight characters, no look-alike glyphs.  Shown on the Mac and typed on the iPhone.
enum CompanionToken {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// A phone's own token starts with this.  The 8 character pairing code
    /// cannot, so the two are told apart at a glance.
    static let devicePrefix = "hh1_"

    static func isDeviceToken(_ token: String) -> Bool {
        token.hasPrefix(devicePrefix) && token.count > devicePrefix.count
    }

    static func make(length: Int = 8) -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for index in a.indices {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }
}

/// Live telemetry snapshot of the Mac panel.  Numbers are already formatted the way
/// the menu bar app shows them, so the phone does not keep a second copy of
/// the scale rules.
struct CompanionSnapshot: Codable, Equatable {
    var version: Int
    var hostName: String
    var sampledAt: Date
    var hasBaseline: Bool
    var window: String
    var grouping: String
    var cpuScale: String
    var pulse: CompanionPulse
    var rows: [CompanionRow]
    var storage: CompanionStorageSummary? = nil
    var network: [CompanionNetworkRow]? = nil
    /// Why `network` is empty ("still looking", "lsof denied"), so the phone
    /// can say so instead of claiming the Mac has no connections.
    var networkNote: String? = nil
    /// What the Mac owner has allowed the phone to do.  Optional so an older
    /// Mac that does not send them decodes as "unknown" rather than failing.
    var remoteQuitAllowed: Bool? = nil
    var remoteCleanAllowed: Bool? = nil
    /// Whether the phone may change cleaner exclusions and the panel view.
    var remoteEditAllowed: Bool? = nil
    var cleanProgress: CompanionCleanProgress? = nil
    /// Interface throughput and its 24-hour peak.  Nil from an older Mac.
    var bandwidth: CompanionBandwidth? = nil
    /// The last readings of machine CPU, 0 to 100, oldest first, for the sparkline.
    var cpuHistory: [Double]? = nil
    /// Refresh interval, alerts and the webhook as the Mac holds them.
    var settings: CompanionSettingsSummary? = nil
    /// Whether the phone may start a Robotic Vacuum run.  Nil from an older
    /// Mac, which has no such route.
    var remoteVacuumAllowed: Bool? = nil
    /// Robotic Vacuum status.  Nil from an older Mac, and on a Mac that has
    /// never run it.
    var vacuum: CompanionVacuumStatus? = nil
}

struct CompanionPulse: Codable, Equatable {
    /// Machine CPU, 0 to 100 across all cores.  Drives the meter, not the label.
    var cpuPercent: Double
    var cpuText: String
    var cpuCaption: String
    var cpuSeverity: String
    /// Logical cores, which the Per Machine scale divides by.  Nil from an older Mac.
    var coreCount: Int? = nil
    /// Memory used over physical memory, 0 to 100.
    var memoryPercent: Double
    var memoryText: String
    var memoryCaption: String
    var swapText: String?
    var pressureText: String?
    var pressureSeverity: String
    var thermalState: String? = nil
    var batteryPercent: Int? = nil
    var isCharging: Bool? = nil
    var powerSource: String? = nil

    var batteryText: String? {
        guard let percent = batteryPercent else { return nil }
        let src = powerSource ?? (isCharging == true ? "AC" : "Battery")
        return "\(percent)% (\(src))"
    }
}

struct CompanionRow: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var cpuText: String
    var memoryText: String
    /// `calm`, `elevated`, or `hot`.  Calm stays in the ordinary text color.
    var severity: String
    var isApp: Bool
    var cpuPercent: Double? = nil
    var memoryBytes: UInt64? = nil
    var pid: Int32? = nil
    var canQuit: Bool = false
    var quitBlockReason: String? = nil
    var isTamed: Bool? = false
    var isSleepBlocker: Bool? = false
    var canTame: Bool? = false
}

struct CompanionStorageCategorySummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var icon: String
    var isExcluded: Bool
    var isExtremeOnly: Bool
}

struct CompanionStorageSummary: Codable, Equatable {
    var freeBytes: UInt64
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeText: String
    var totalText: String
    var usedText: String
    var usedPercent: Double
    var standardCleanableBytes: UInt64? = nil
    var standardCleanableText: String? = nil
    var excludedCategories: [String]? = nil
    var excludedPathsCount: Int? = nil
    var categoryBreakdown: [CompanionStorageCategorySummary]? = nil
    var excludedPaths: [String]? = nil
    /// Top storage-heavy apps on the host.  Mirrors the Mac pane's "App Storage"
    /// tab so the phone can show "Mac Storage by App" without owning a separate
    /// scanner.  Optional because the scanner is cached on the host and the first
    /// snapshot after pairing may not have run yet.
    var topApps: [CompanionAppStorageRow]? = nil
    /// When `topApps` was last refreshed on the host.  The phone uses this for
    /// a "Scanned 2 min ago" caption.
    var topAppsScannedAt: Date? = nil
}

/// One row of the Mac pane's App Storage list, packaged for the phone.  All
/// values are pre-formatted on the host so the phone can render without
/// re-doing the scale rules.
struct CompanionAppStorageRow: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var bundleId: String?
    var totalBytes: UInt64
    var bundleBytes: UInt64
    var hiddenBytes: UInt64
    var totalText: String
    var bundleText: String
    var hiddenText: String
    /// True when one or more walks had to be capped (time or file-count budget).
    var anyApproximate: Bool
    /// True when hidden bytes are at least 5x the bundle and over 200 MB.
    var isHiddenHeavy: Bool
}

struct CompanionNetworkRow: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var pid: Int32
    var establishedCount: Int
    var uniqueRemoteHosts: Int
    var sampleRemoteHosts: [String]
}

enum CompanionJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ snapshot: CompanionSnapshot) throws -> Data {
        try encoder().encode(snapshot)
    }

    static func decode(_ data: Data) throws -> CompanionSnapshot {
        try decoder().decode(CompanionSnapshot.self, from: data)
    }
}
