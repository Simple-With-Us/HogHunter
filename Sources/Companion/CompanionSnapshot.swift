import Foundation

/// Bonjour service the Mac advertises and the iPhone browses.
/// The pairing code is never put in the TXT record.
enum CompanionService {
    static let type = "_hoghunter._tcp"
    static let path = "/v1/snapshot"
    static let cleanPath = "/v1/clean"
    /// Cleans the items chosen from a scan the Mac holds.  Its own path, so a Mac
    /// that predates it answers 404 and the phone says so, instead of reading the
    /// body-less route and running its default clean in place of the chosen one.
    static let cleanRunPath = "/v1/clean/run"
    /// Starts a scan of the Mac's clutter for the Standard or Extreme tier.
    static let cleanScanPath = "/v1/clean/scan"
    /// The last scan (categories and items), the scan's progress and recent cleanup history.
    static let cleanReportPath = "/v1/clean/report"
    static let quitPath = "/v1/quit"
    static let tamePath = "/v1/tame"
    static let exclusionsPath = "/v1/exclusions"
    static let viewPath = "/v1/view"
    /// Refresh interval, alerts and the webhook.  Behind the edit opt-in.
    static let settingsPath = "/v1/settings"
    /// Sample for 3 Seconds on one row.  Behind the process-control opt-in.
    static let samplePath = "/v1/sample"
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

/// What the disk cleaner tells the person.  One copy, shared by the Mac's
/// cleaner and the phone's, so the two cannot drift apart.
enum CleanerCopy {
    static let extremeTitle = "Extreme Clean Targets AI Agent & Deep Developer Clutter"
    static let extremeBody = "Extreme Clean scans for uninstalled app leftovers, older AI agent transcripts (>7 days) across Gemini/Grok/Codex, temporary update downloads, and large/old files.\nWhile git repositories and critical directories are strictly protected, local AI tools may need to re-download model caches, re-index workspaces, or re-authenticate ephemeral CLI sessions."
    static let extremeAcknowledgement = "I understand this targets AI tool caches, orphaned app data, and older transcripts."

    /// The confirmation before a clean, with the amount and the count filled in.
    static func confirmationMessage(sizeText: String, itemCount: Int) -> String {
        "Are you sure you want to clean \(sizeText) across \(itemCount) items?\u{00A0} An APFS local snapshot is created first.\u{00A0} If that snapshot fails, nothing is deleted.\u{00A0} Items that are not already in the Trash move to the Trash, where Put Back still works.\u{00A0} Items already in the Trash are removed permanently."
    }
}

/// One thing a scan found, as the phone sees it.  The phone never names a
/// path: `id` is a short reference into the Mac's copy of the scan, and the
/// Mac resolves it to the real item itself.
struct CompanionCleanItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var bytes: UInt64
    var sizeText: String
    var fileCount: Int
    var detail: String? = nil
    /// Whether the Mac's own cleaner would start with this item ticked.
    var isSelected: Bool
}

struct CompanionCleanCategory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var icon: String
    var isExtremeOnly: Bool
    var totalBytes: UInt64
    var totalText: String
    /// How many items the Mac found, which can be more than `items` holds.
    var itemCount: Int
    /// The largest items first, capped so the report stays small.
    var items: [CompanionCleanItem]
}

/// One completed cleanup, newest first in the report.
struct CompanionCleanupRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var cleanedAt: Date
    var bytesReclaimed: UInt64
    var sizeText: String
    var itemsRemoved: Int
    /// `standard` or `extreme`.
    var tier: String
    var tierTitle: String
    var categoryTitles: [String]
    /// The first few titles, so the phone can say what went.
    var itemTitles: [String]
    var snapshotName: String? = nil
    /// "iPhone" for a clean the phone started; nil for one started at the Mac.
    var source: String? = nil
}

/// The Mac's last scan, its progress, and cleanup history.
struct CompanionCleanReport: Codable, Equatable, Sendable {
    /// `idle`, `scanning` or `ready`.
    var state: String
    var scanId: String? = nil
    /// `standard` or `extreme`.
    var tier: String? = nil
    var scannedAt: Date? = nil
    /// The category being scanned now, while `state` is `scanning`.
    var scanningCategory: String? = nil
    var totalBytes: UInt64 = 0
    var totalText: String = "0 B"
    var totalItems: Int = 0
    var categories: [CompanionCleanCategory] = []
    var history: [CompanionCleanupRecord] = []
}

/// A request to clean, from a scan the Mac is holding, sent to
/// `POST /v1/clean/run`.  The older `POST /v1/clean` takes no body: it is always
/// the Standard clean with the Mac's default selection.
struct CompanionCleanRequest: Codable, Equatable, Sendable {
    var scanId: String? = nil
    /// `standard` or `extreme`.  Must match the scan's tier.
    var tier: String? = nil
    /// References from the report, never paths.
    var items: [String]? = nil
    /// The phone's confirmation of the Extreme notice.
    var acknowledgedExtreme: Bool? = nil
}

/// A request to scan.
struct CompanionCleanScanRequest: Equatable, Sendable {
    /// `standard` or `extreme`.
    var tier: String
    var acknowledgedExtreme: Bool = false
}

struct CompanionCleanScanResponse: Codable, Equatable, Sendable {
    var status: String
    var scanId: String? = nil
    var tier: String? = nil
    var message: String? = nil
    var error: String? = nil
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
