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
    /// Starts a Maintain run.  Behind its own opt-in: a run can retire
    /// old git worktrees and run maintenance on remote servers.
    static let maintainRunPath = "/v1/maintain/run"
    /// Turns built-in Maintain steps on or off and sets the three tuning
    /// thresholds.  Behind the same opt-in as the run.
    static let maintainSettingsPath = "/v1/maintain/settings"
    /// The cleaner's temp file minimum untouched hours.  Behind the cleaner
    /// opt-in, and takes nothing else.
    static let cleanSettingsPath = "/v1/clean/settings"
    /// Acts on one server process.  These three are stricter than every other
    /// route: Tailscale only, behind their own opt-in.
    static let serverProcessPath = "/v1/server/process"
    /// Stops or restarts one server workload.
    static let serverWorkloadPath = "/v1/server/workload"
    /// Scans or runs server maintenance.
    static let serverMaintainPath = "/v1/server/maintain"
    /// Asks the Mac to read the server again now, like the Refresh button on the
    /// Mac's server card.  Read only, so it sits behind Allow iPhone to See
    /// Server Status, not the server-controls opt-in, and like every route but
    /// the snapshot it takes a phone's own token from the local network or
    /// Tailscale.  At most one every `CompanionServerRefresh.minimumInterval`.
    static let serverRefreshPath = "/v1/server/refresh"
    /// The only run the phone may start.  The Mac's script also knows
    /// cheaper cadences and a pressure run; none of them is reachable from here.
    static let maintainRunKinds = ["full"]
    static let pairPath = "/v1/pair"
    /// Trades the shared pairing code for a token of the phone's own.
    static let enrollPath = "/v1/enroll"
    static let version = 1
}

/// Address-backed companion saves (Tailscale MagicDNS, LAN IP, custom domain) are not
/// discovered via `_hoghunter._tcp`.  Bonjour browse churn must not mark them offline.
enum CompanionReach {
    static func keepsManualHost(_ remoteHost: String?) -> Bool {
        let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !host.isEmpty
    }
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
    var observedFreeBytesChange: Int64? = nil
}

enum CleanerSpaceObservation {
    static func text(_ bytes: Int64?) -> String {
        guard let bytes else { return "Available-space change unavailable" }
        var value = Double(bytes.magnitude)
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        let amount = unit == 0 ? "\(bytes.magnitude) B" : String(format: "%.1f %@", value, units[unit])
        if bytes > 0 { return "Available space increased by " + amount }
        if bytes < 0 { return "Available space decreased by " + amount }
        return "Available space unchanged"
    }
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
    /// True when the Mac's size walk hit its file cap, so `bytes` is a
    /// lower bound ("at least N").  Decoded tolerantly: a Mac that predates
    /// the flag sends no key, which reads as false.
    var isApproximate: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, bytes, sizeText, fileCount, detail, isSelected, isApproximate
    }

    init(id: String, title: String, subtitle: String, bytes: UInt64, sizeText: String, fileCount: Int, detail: String? = nil, isSelected: Bool, isApproximate: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.bytes = bytes
        self.sizeText = sizeText
        self.fileCount = fileCount
        self.detail = detail
        self.isSelected = isSelected
        self.isApproximate = isApproximate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        bytes = try container.decode(UInt64.self, forKey: .bytes)
        sizeText = try container.decode(String.self, forKey: .sizeText)
        fileCount = try container.decode(Int.self, forKey: .fileCount)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isSelected = try container.decode(Bool.self, forKey: .isSelected)
        isApproximate = try container.decodeIfPresent(Bool.self, forKey: .isApproximate) ?? false
    }
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
    /// Nil from older Macs; true means the listed totals are lower bounds.
    var isPartial: Bool? = nil
    var incompleteCategories: [String]? = nil
    var scanDepth: String? = nil
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
    var depth: String = "quick"
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
    var observedFreeBytesChange: Int64? = nil
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
    /// The Mac's list sort: "CPU" or "Memory".  The phone sorted its own list
    /// locally and the Mac sorted its own, so the two could disagree about
    /// which app was on top.  The phone now sets the Mac's sort instead.
    var sort: String? = nil
    /// True when the list runs from least to most.
    var sortAscending: Bool? = nil
}

/// Response returned after updating view settings on the Mac.
struct CompanionViewUpdateResponse: Codable, Equatable, Sendable {
    var status: String
    var window: String
    var grouping: String
    var cpuScale: String
    /// The sort the Mac is now using, and the direction.
    var sort: String = "CPU"
    var sortAscending: Bool = false
    var message: String?
    /// Why the change was refused, when it was.
    var error: String? = nil
}

extension CompanionViewUpdateResponse {
    /// Reads tolerantly: a Mac that predates the sort fields sends no keys
    /// for them, which read as the defaults instead of failing the whole
    /// response.  In an extension so the memberwise initializer and the
    /// synthesized encoder stay intact.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        window = try container.decode(String.self, forKey: .window)
        grouping = try container.decode(String.self, forKey: .grouping)
        cpuScale = try container.decode(String.self, forKey: .cpuScale)
        sort = try container.decodeIfPresent(String.self, forKey: .sort) ?? "CPU"
        sortAscending = try container.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// The values the Mac accepts for the settings a phone may change.  Shared so
/// the phone's pickers offer exactly what the Mac will take; the Mac checks
/// every value again, so a hand-built request gets no further.
enum CompanionSettingsLimits {
    /// The same choices as Settings > General > Refresh Every on the Mac.
    static let refreshIntervals: [Double] = [2, 3, 5, 10, 15]
    /// The same choices as Settings > General > Background Refresh (When
    /// Closed) on the Mac.
    static let backgroundRefreshIntervals: [Double] = [5, 10, 15, 30]
    /// The Mac's appearance choices, in the names the Mac uses.
    static let appearances: [String] = ["System", "Light", "Dark"]
    /// The Mac's menu bar label choices, in the names the Mac uses.
    static let menuBarLabelModes: [String] = ["History Bars & %", "Machine CPU", "Top Hog", "Live Sparkline"]
    /// Per-core percent, the scale the alert compares against.
    static let alertThresholdRange: ClosedRange<Double> = 100...1000
    static let alertThresholdStep: Double = 50
    static let alertSustainedMinutesRange: ClosedRange<Int> = 1...30
    /// A webhook URL longer than this is not a webhook URL.
    static let webhookMaxLength = 2_048
}

/// The bounds on the Maintain tuning knobs.  The Mac's Maintenance settings
/// sliders and steppers and the phone's route both read these, so the phone can
/// never set a value the Mac's own controls would not offer.
enum CompanionMaintainLimits {
    /// Cache reclaim runs when free disk falls below this.  Gigabytes.
    static let lowFreeGiBRange: ClosedRange<Double> = 30...200
    static let lowFreeGiBStep: Double = 5
    /// PM2 log files over this size are truncated.  Megabytes.
    static let pm2LogsCapMBRange: ClosedRange<Int> = 10...200
    static let pm2LogsCapMBStep: Int = 10
    /// Merged git worktrees are retired after this many idle days.
    static let worktreeRetireDaysRange: ClosedRange<Int> = 1...90
    /// The one built-in step that runs maintenance on a remote server.
    static let remoteServerStepId = "coolify_remote"
}

/// The bounds on the cleaner settings a phone may change.
enum CompanionCleanLimits {
    /// Whole hours a temp file must sit untouched before the cleaner lists it.
    /// The Mac's Settings > Cleaner stepper and its safety policy read this.
    static let tempFileHoursRange: ClosedRange<Double> = 1...8_760
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
    /// The Mac's appearance: "System", "Light" or "Dark".
    var appearance: String = "System"
    /// The refresh cadence the Mac uses while its panel is closed, in seconds.
    var backgroundRefreshInterval: Double = 10
    /// What the Mac's menu bar shows: "History Bars & %", "Machine CPU", "Top Hog" or
    /// "Live Sparkline".
    var menuBarLabelMode: String = "History Bars & %"
    /// The Mac's list sort: "CPU" or "Memory".
    var sort: String = "CPU"
    /// True when the Mac's list runs from least to most.
    var sortAscending: Bool = false
    /// The appearance the Mac is actually showing: "Light" or "Dark", never
    /// "System".  The phone's System choice follows the Mac, and the Mac's
    /// own preference says nothing about what the Mac is showing.
    var resolvedAppearance: String = "Light"
    /// True when the Mac opens Hog Hunter at login.  Nil from a Mac that
    /// predates the field.
    var launchesAtLogin: Bool? = nil
}

extension CompanionSettingsSummary {
    /// Reads tolerantly: a Mac that predates the appearance, background
    /// refresh, menu label, sort or resolved appearance fields sends no keys
    /// for them, which read as the defaults instead of failing the whole
    /// snapshot.  In an extension so the memberwise initializer and the
    /// synthesized encoder stay intact.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try container.decode(Double.self, forKey: .refreshInterval)
        alertsEnabled = try container.decode(Bool.self, forKey: .alertsEnabled)
        alertThresholdPercent = try container.decode(Double.self, forKey: .alertThresholdPercent)
        alertSustainedMinutes = try container.decode(Int.self, forKey: .alertSustainedMinutes)
        webhookConfigured = try container.decode(Bool.self, forKey: .webhookConfigured)
        webhookHost = try container.decodeIfPresent(String.self, forKey: .webhookHost)
        webhookStatus = try container.decodeIfPresent(String.self, forKey: .webhookStatus)
        notificationsDenied = try container.decodeIfPresent(Bool.self, forKey: .notificationsDenied)
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "System"
        backgroundRefreshInterval = try container.decodeIfPresent(Double.self, forKey: .backgroundRefreshInterval) ?? 10
        menuBarLabelMode = try container.decodeIfPresent(String.self, forKey: .menuBarLabelMode) ?? "History Bars & %"
        sort = try container.decodeIfPresent(String.self, forKey: .sort) ?? "CPU"
        sortAscending = try container.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? false
        resolvedAppearance = try container.decodeIfPresent(String.self, forKey: .resolvedAppearance) ?? "Light"
        launchesAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchesAtLogin)
    }
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
    /// The Mac's appearance: "System", "Light" or "Dark".
    var appearance: String? = nil
    /// The refresh cadence the Mac uses while its panel is closed, in seconds.
    var backgroundRefreshInterval: Double? = nil
    /// What the Mac's menu bar shows: "Machine CPU", "Top Hog" or
    /// "Live Sparkline".
    var menuBarLabelMode: String? = nil
    /// Opens Hog Hunter at login on the Mac.
    var launchesAtLogin: Bool? = nil

    var isEmpty: Bool {
        refreshInterval == nil && alertsEnabled == nil && alertThresholdPercent == nil
            && alertSustainedMinutes == nil && webhookURL == nil && testWebhook != true
            && appearance == nil && backgroundRefreshInterval == nil && menuBarLabelMode == nil
            && launchesAtLogin == nil
    }
}

/// A change to the Maintain's built-in steps and thresholds.  Every field is
/// optional and the change is applied whole or not at all.  Custom scripts
/// cannot be named: enabling one runs code the phone has never seen, so that
/// stays a Mac choice.
struct CompanionMaintainSettingsRequest: Codable, Equatable, Sendable {
    /// Step id to on or off.  Built-in step ids only.
    var stepEnabled: [String: Bool]? = nil
    var lowFreeGiB: Double? = nil
    var worktreeRetireMinDays: Int? = nil
    var pm2LogsCapMB: Int? = nil
    /// Must be true to turn on the step that runs maintenance on the remote
    /// server.  The phone sets it only after it has said what the step does.
    var acknowledgeRemoteServer: Bool? = nil

    var isEmpty: Bool {
        (stepEnabled ?? [:]).isEmpty && lowFreeGiB == nil && worktreeRetireMinDays == nil && pm2LogsCapMB == nil
    }
}

/// A change to the cleaner's temp file safety minimum.  Nothing else.
struct CompanionCleanSettingsRequest: Codable, Equatable, Sendable {
    var tempFileMinimumHours: Double? = nil

    var isEmpty: Bool { tempFileMinimumHours == nil }
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

/// Response to a Maintain run request.  The Mac answers at once: the run
/// carries on there and the phone watches the snapshot for its progress.
struct CompanionMaintainRunResponse: Codable, Equatable, Sendable {
    /// "started" or "busy" (a run is already going).
    var status: String
    var message: String? = nil
    var error: String? = nil
}

/// One step of the last Maintain run.  Reasons can name lane folders and
/// servers, so the Mac sends steps only when the owner allowed the phone to
/// run the maintain.
struct CompanionMaintainStep: Codable, Equatable, Identifiable, Sendable {
    var stepId: String
    var title: String
    /// "Done", "Skipped" or "Failed", as the Mac shows it.
    var statusLabel: String
    /// At most 120 characters.
    var reason: String
    var bytesFreed: Int

    var id: String { stepId }
}

/// Where the Maintain stands: when it last ran and will next run, whether
/// its background job is loaded, and whether a run is going now.
struct CompanionMaintainStatus: Codable, Equatable, Sendable {
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
    /// What kind of run `lastRunBytesFreed`, `lastRunEndedAt` and `steps` describe:
    /// "janitor", "full", "manual" or "pressure".  It is never "watch" unless
    /// every run on record is a watch tick, because a watch tick is only the
    /// five minute disk and memory check and says nothing about cleaning.
    var lastRunTrigger: String? = nil
    /// What the last run did, step by step.  Nil unless the owner allowed the
    /// phone to run the maintain.
    var steps: [CompanionMaintainStep]? = nil
    /// The Mac's recent cleaning runs, newest first, the way the Mac lists
    /// them: janitor, full, manual and pressure runs, and nothing for the
    /// quiet five minute checks, which `watch` sums up instead.  A run carries
    /// no step text, so unlike `steps` this travels with the plain snapshot.
    /// Nil from a Mac that predates the field (empty means the Mac has
    /// recorded no cleaning runs).  A Mac that predates the cleaning-only list
    /// still sends watch ticks in it, so read it through `cleaningRuns`.
    var recentRuns: [CompanionMaintainRun]? = nil
    /// The five minute disk and memory checks, summed up: when the last one
    /// ran and how many ran today.  Nil from a Mac that predates the field,
    /// and from a Mac that has recorded no check.  Carries no step text.
    var watch: CompanionMaintainWatch? = nil
    /// Every built-in step with its on or off state, in the Mac's order.  Nil
    /// unless the owner allowed the phone to run the maintain.
    var stepSettings: [CompanionMaintainStepSetting]? = nil
    /// The three tuning thresholds.  Nil unless the owner allowed the phone to
    /// run the maintain.
    var tuning: CompanionMaintainTuning? = nil
    /// The custom scripts the Mac knows, by name and on or off state, never by
    /// path.  Read only.  Nil unless the owner allowed the phone to run the maintain.
    var customScripts: [CompanionMaintainScript]? = nil

    /// `recentRuns` without any watch tick, so an older Mac that still lists
    /// them reads the same as a newer one.  Nil when the Mac sent no list.
    ///
    /// An older Mac files a pressure clean under trigger "watch" like a quiet
    /// tick, and sends no steps to tell them apart, so its escalated ticks go
    /// too.  A current Mac has already done this: it leaves quiet ticks out
    /// and sends an escalated one as "pressure", which passes here.
    var cleaningRuns: [CompanionMaintainRun]? {
        recentRuns?.filter { $0.trigger != CompanionMaintainRun.watchTrigger }
    }
}

/// One built-in step and whether the Mac runs it.
struct CompanionMaintainStepSetting: Codable, Equatable, Identifiable, Sendable {
    var stepId: String
    var title: String
    var isEnabled: Bool
    /// True for the step that runs maintenance on the remote server, which the
    /// phone confirms in words of its own before it turns it on.
    var isRemoteServer: Bool = false
    var id: String { stepId }
}

/// The Maintain thresholds as the Mac holds them.
struct CompanionMaintainTuning: Codable, Equatable, Sendable {
    var lowFreeGiB: Double
    var worktreeRetireMinDays: Int
    var pm2LogsCapMB: Int
}

/// A custom maintenance script, by the name the Mac lists it under.  The path
/// and the owner stay on the Mac.
struct CompanionMaintainScript: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var isEnabled: Bool
    /// "owned" or "observed".
    var mode: String
    /// "local" or "remote".
    var scope: String
    var id: String { "\(mode)/\(scope)/\(name)" }
}

/// How a Maintain run ended, for the mark on its row.
enum CompanionMaintainRunResult: String, Equatable, Sendable {
    case ok
    /// A step failed and another one did its work.  The run exits 0, which is
    /// why the exit code alone cannot show it.
    case partial
    /// The run stepped aside without doing work (for example, lock contention).
    case skipped
    case failed

    /// The one rule for both screens.  A non-zero exit is always failed, as in
    /// the engine.  Otherwise the run's recorded outcome decides, and a run
    /// with no outcome (an older Mac or an older history row) or one this
    /// build does not know is judged by its exit code, which is zero here.
    static func resolve(exitCode: Int, outcome: String?) -> CompanionMaintainRunResult {
        if exitCode != 0 { return .failed }
        switch outcome {
        case "partial": return .partial
        case "skipped": return .skipped
        case "failed": return .failed
        default: return .ok
        }
    }

    /// The word on the run's row, or nil for a run with nothing to flag.
    var markLabel: String? {
        switch self {
        case .ok: return nil
        case .partial: return "Partial"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }
}

/// One finished Maintain run in the Recent Runs list.  Only what can be
/// said without naming a folder or a server.
struct CompanionMaintainRun: Codable, Equatable, Identifiable, Sendable {
    var runId: String
    /// "watch", "janitor", "full", "manual" or "pressure", as the engine records it.
    var trigger: String
    var endedAt: Date? = nil
    var bytesFreed: Int
    /// Zero when the run finished cleanly.  A partial run is zero too.
    var exitCode: Int
    var durationSeconds: Int
    /// "ok", "partial", "skipped" or "failed", as the Mac resolved it from the run's
    /// recorded outcome.  Nil from a Mac that predates the field: the exit code
    /// then decides, and a partial run cannot be told from a clean one.
    var outcome: String? = nil

    /// The trigger of the five minute disk and memory check.
    static let watchTrigger = "watch"

    var id: String { runId }
    var result: CompanionMaintainRunResult { .resolve(exitCode: exitCode, outcome: outcome) }
    /// True when the run has nothing to flag: not failed and not partial.
    var succeeded: Bool { result == .ok }
}

/// The five minute disk and memory checks in one line's worth of numbers.  The
/// checks are left out of the list of runs because there are hundreds a day.
struct CompanionMaintainWatch: Codable, Equatable, Sendable {
    /// When the newest check ran.
    var lastCheckAt: Date?
    /// How many ran since the start of today on the Mac's clock.
    var checksToday: Int
    /// Set only when the Mac's history does not reach back to the start of
    /// today, so the count covers just the time since this moment.  Then the
    /// line must not say "today".
    var countedSince: Date?
    /// The Mac's time zone, for example "America/Chicago".  "Today" is the
    /// Mac's day, so the line reads its clock in this zone too, and a phone in
    /// another zone says the same thing the Mac does.  Nil from a Mac that does
    /// not say, and then the line uses the reader's own zone.
    var timeZoneIdentifier: String?

    init(lastCheckAt: Date? = nil, checksToday: Int = 0, countedSince: Date? = nil, timeZoneIdentifier: String? = nil) {
        self.lastCheckAt = lastCheckAt
        self.checksToday = checksToday
        self.countedSince = countedSince
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Every field has a default, so a payload missing any of them still reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        checksToday = try container.decodeIfPresent(Int.self, forKey: .checksToday) ?? 0
        countedSince = try container.decodeIfPresent(Date.self, forKey: .countedSince)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
    }

    /// "Last check 5:40pm · 23 checks today".  Twelve-hour time with am or pm
    /// and no zone, read in the Mac's time zone when the payload names it (else
    /// the calendar's).  A check from an earlier day says which day, and a
    /// count that covers only part of today says since when.  Shared by the
    /// Mac and the phone, so the two read alike.
    func summary(now: Date, calendar: Calendar = .current) -> String {
        var calendar = calendar
        if let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = zone
        }
        let last: String
        if let lastCheckAt {
            last = "Last check \(Self.describe(lastCheckAt, now: now, calendar: calendar))"
        } else {
            last = "No checks recorded yet"
        }
        let noun = checksToday == 1 ? "check" : "checks"
        let count: String
        if let countedSince {
            count = "\(checksToday) \(noun) since \(Self.clock(countedSince, calendar: calendar))"
        } else {
            count = "\(checksToday) \(noun) today"
        }
        return last + " \u{00B7} " + count
    }

    private static func describe(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return "\(format("MMM d", date, calendar: calendar)) \(time)"
    }

    /// "5:40pm".  A fixed format on purpose: the owner reads a 12-hour clock
    /// with lower-case am and pm whatever the phone's own setting is.
    static func clock(_ date: Date, calendar: Calendar) -> String {
        format("h:mma", date, calendar: calendar)
    }

    private static func format(_ pattern: String, _ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
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

    static func normalizeCode(_ raw: String) -> String {
        if isDeviceToken(raw) { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0 != "-" && $0 != " " }
            .uppercased()
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let normA = normalizeCode(lhs)
        let normB = normalizeCode(rhs)
        let a = Array(normA.utf8)
        let b = Array(normB.utf8)
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
    /// Whether the phone may start a Maintain run.  Nil from an older
    /// Mac, which has no such route.
    var remoteMaintainAllowed: Bool? = nil
    /// Maintain status.  Nil from an older Mac, and on a Mac that has
    /// never run it.
    var maintain: CompanionMaintainStatus? = nil
    /// Whether the owner allows the phone to see server status.  Nil from an
    /// older Mac.  Says nothing about the server itself, so it travels in the
    /// plain snapshot and the phone can say why the block is missing.
    var remoteServerStatusAllowed: Bool? = nil
    /// The server's readings.  Nil from an older Mac, while the opt-in is off,
    /// and always in the plain snapshot the shared code reads.
    var server: CompanionServerStatus? = nil
    /// Flagged Issues, most urgent first.  Nil from an older Mac.  Server rows
    /// are here only when `server` is.
    var flaggedIssues: [CompanionFlaggedIssue]? = nil
    /// Whether `flaggedIssues` looked at the server.  False means the list is
    /// the Mac's alone, so an empty list does not mean all is calm.
    var flaggedIssuesCoverServer: Bool? = nil
    /// Whether the owner allows the phone to act on the server.  Nil from an
    /// older Mac, and always in the plain snapshot: it travels with the server
    /// block.  True says the Mac will listen, not that this link will be
    /// accepted: the routes also need a Tailscale connection.
    var remoteServerControlAllowed: Bool? = nil
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

/// Text fallback for ranking rows from a Mac too old to send the numeric
/// fields, mirroring the phone's `CompanionRow.sortCPU`/`sortMemory`
/// fallback.  Text without digits means "no reading" (nil), so a genuinely
/// unnumbered row still ranks after numbered ones instead of sorting as
/// zero.
private enum CompanionActivityText {
    static func cpu(_ text: String) -> Double? {
        let digits = text.filter { $0.isNumber || $0 == "." }
        guard !digits.isEmpty else { return nil }
        return Double(digits)
    }

    static func memoryBytes(_ text: String) -> UInt64? {
        let upper = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let numPart = upper.filter { $0.isNumber || $0 == "." }
        guard !numPart.isEmpty, let val = Double(numPart) else { return nil }
        let scale: Double
        if upper.contains("TB") {
            scale = 1_099_511_627_776
        } else if upper.contains("GB") {
            scale = 1_073_741_824
        } else if upper.contains("MB") {
            scale = 1_048_576
        } else if upper.contains("KB") {
            scale = 1_024
        } else {
            scale = 1
        }
        // Display text is untrusted: a reading at or beyond 2^64 (or one
        // whose scaling overflows to infinity) must not trap the trapping
        // initializer while ranking.  Reject those, keep truncating the
        // ordinary fractional cases the way the trapping init did.
        let scaled = val * scale
        guard scaled.isFinite, scaled >= 0, scaled < 0x1p64 else { return nil }
        return UInt64(scaled)
    }
}

extension Array where Element == CompanionRow {
    /// The phone Overview's busiest ranking (HH-212): strictly descending
    /// CPU, then memory, then name, then id.  A total order, so the list is
    /// stable and cannot cycle the way an epsilon comparator can (a within
    /// 0.05 of b and b within 0.05 of c says nothing about a and c).  A row
    /// whose Mac sent only text readings is ranked by the parsed text, the
    /// same kind of display-text fallback the phone's
    /// `CompanionRow.sortCPU`/`sortMemory` apply through `UsageParser`;
    /// unlike `UsageParser.parseMemoryBytes`, `CompanionActivityText` rejects
    /// a reading at or beyond 2^64 as no reading instead of trapping.  A row
    /// with no reading at all ranks after numbered rows.
    func rankedByActivity() -> [CompanionRow] {
        // Parse each row's text fallback once, not once per comparison: the
        // fallback allocates, and the comparator runs O(N log N) times per
        // snapshot update.
        let enriched = map { row -> (row: CompanionRow, cpu: Double, mem: UInt64) in
            // JSON decoding already refuses NaN and infinity, so no snapshot
            // delivers them; a hand-built row still gets them counted as
            // missing, because NaN's unordered comparisons would break the
            // total order.
            let cpu = row.cpuPercent.flatMap { $0.isFinite ? $0 : nil } ?? CompanionActivityText.cpu(row.cpuText) ?? -1
            let mem = row.memoryBytes ?? CompanionActivityText.memoryBytes(row.memoryText) ?? 0
            return (row, cpu, mem)
        }
        return enriched.sorted { a, b in
            if a.cpu != b.cpu { return a.cpu > b.cpu }
            if a.mem != b.mem { return a.mem > b.mem }
            // Equal names skip the ICU-backed compare entirely.
            let aName = a.row.name, bName = b.row.name
            if aName != bName {
                switch aName.localizedStandardCompare(bName) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame:
                    // Distinct strings the collation calls equivalent still
                    // need the id tiebreaker, or two different rows compare
                    // equal both ways and the order is no longer total.
                    break
                }
            }
            return a.row.id < b.row.id
        }.map { $0.row }
    }
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
    /// The drives mounted on the host, with the path each one is mounted at.
    /// The Mac's own storage screen shows the same list.  Optional because the
    /// host may not have collected it yet.
    var drives: [CompanionDriveRow]? = nil
    /// The host's largest directories, with the same short status line the
    /// Mac's rows show.  Optional for the same reason.
    var topDirectories: [CompanionDirectoryRow]? = nil
    /// What the scanned apps add up to by kind of data (caches, containers,
    /// logs and so on), the way the Mac's Storage tab sums them for its
    /// subtitle.  Largest first.  Optional because the scan may not have run.
    var categoryTotals: [CompanionStorageCategoryTotal]? = nil
    /// Whole hours a temp file must sit untouched before the cleaner lists it,
    /// as the Mac's Settings > Cleaner holds it.  Nil from a Mac that predates the field.
    var tempFileMinimumHours: Double? = nil
}

/// One kind of app data, summed across the scanned apps.
struct CompanionStorageCategoryTotal: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var bytes: UInt64
    /// The size, already formatted for display ("2.1 GB").
    var text: String
}

/// One mounted drive, as the host sees it.
///
/// The mount path is the point of this row: the old Mac layout listed the
/// drives with where they were mounted, and the new dashboard shows only
/// capacity cards.
struct CompanionDriveRow: Codable, Equatable, Identifiable, Sendable {
    /// The mount path, which is also the row's identity.
    var id: String
    var name: String
    /// Where the drive is mounted, for example "/Volumes/External".
    var path: String
    var totalBytes: UInt64? = nil
    var availableBytes: UInt64? = nil
    /// How full the drive is, 0 to 100.  Absent when the host cannot read it.
    var usedPercent: Double? = nil
    /// "normal", "warning", "critical" or "unavailable".
    var severity: String = "unavailable"
    /// True for a drive on the boot volume.
    var isLocal: Bool = true
}

/// One of the host's largest directories, with the status line the Mac's own
/// row shows under it.
struct CompanionDirectoryRow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// The full path, which the Mac's rows show too.
    var path: String
    var bytes: UInt64
    /// The size, already formatted for display ("12 GB").  The phone shows it
    /// as it is rather than re-doing the scale rules.
    var bytesText: String
    /// A short status line, such as "Safe to clean."  The Mac's rows used to
    /// show this under the name and now keep it in a tooltip; the phone shows
    /// it inline, which is what the old layout did.
    var detail: String
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

// MARK: - Server control

/// The vocabulary of the three server control routes.  The phone names an
/// action and an opaque row, and the Mac builds everything else itself, so
/// nothing here can carry a host, a pid, a path or a command.
enum CompanionServerControl {
    static let processActions = ["quit", "forceQuit", "tame", "untame", "sample"]
    static let workloadActions = ["stop", "restart"]
    static let maintainModes = ["scan", "run"]
    static let packageCacheStrategy = "package-cache"
    static let rotatedLogsStrategy = "rotated-logs"
    static let buildCacheStrategy = "docker-build-cache"
    static let imageStrategy = "docker-images"
    static let strategies = [packageCacheStrategy, rotatedLogsStrategy, buildCacheStrategy, imageStrategy]

    /// The refusal a local-network phone hears, and the sentence the phone
    /// shows in place of the actions.  Shared, so the two cannot differ.
    static let tailscaleOnlyNote = "Server controls work only over Tailscale, because this link is not encrypted.\u{00A0} Connect to your Mac at its Tailscale address, then try again."
    static let optInNote = "Controlling the server from iPhone is off.\u{00A0} Turn on Allow iPhone to Control the Server and Allow iPhone to See Server Status in Hog Hunter Settings > iPhone on your Mac."

    /// A row id is what the Mac put in the server block: 16 lowercase hex
    /// characters.  Anything else is free text and is refused unread.
    static func isRowID(_ text: String) -> Bool {
        text.utf8.count == 16 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// One server action a phone asked for, already checked for shape.  Which row
/// it means, and whether that row allows it, the Mac decides from its own copy.
enum CompanionServerActionRequest: Equatable, Sendable {
    case process(rowId: String, action: String)
    case workload(rowId: String, action: String)
    case maintain(mode: String, strategies: [String], imageRemovalAcknowledged: Bool)

    var isMaintenance: Bool {
        if case .maintain = self { return true }
        return false
    }

    /// The wire body.  The Mac reads it with `CompanionHTTP.parseServerAction`.
    var body: Data {
        let object: [String: Any]
        switch self {
        case .process(let rowId, let action), .workload(let rowId, let action):
            object = ["rowId": rowId, "action": action]
        case .maintain(let mode, let strategies, let acknowledged):
            var fields: [String: Any] = ["mode": mode, "strategies": strategies]
            if acknowledged { fields["acknowledgeImageRemoval"] = true }
            object = fields
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    var path: String {
        switch self {
        case .process: return CompanionService.serverProcessPath
        case .workload: return CompanionService.serverWorkloadPath
        case .maintain: return CompanionService.serverMaintainPath
        }
    }
}

/// The Mac's answer to a server action.  `status` is `acted`, `partial`,
/// `noWork`, `unknown`, `refused`, `busy`, `stale`, `changed`, `protected`,
/// `rejected`, `forbidden` or `tailscaleRequired`.  A sample or a scan can name server
/// internals, which is why these answers exist only behind the routes' gates.
struct CompanionServerActionResponse: Codable, Equatable, Sendable {
    var status: String
    var message: String? = nil
    var error: String? = nil
    /// The row acted on.
    var name: String? = nil
    var sampleText: String? = nil
    var maintenance: CompanionServerMaintenanceSummary? = nil

    /// Whatever the phone should show for this answer.
    var displayText: String { error ?? message ?? "The Mac did not say what happened." }

    /// What the headline says.  These are kept apart because they call for
    /// different next steps: retrying after a run that may still be going, or
    /// that already deleted something, is a different act from retrying after
    /// a refusal.  A status this phone does not know is not assumed to be safe.
    var outcome: CompanionServerActionOutcome {
        switch status {
        case "acted": return .done
        case "partial": return .partial
        case "noWork": return .noWork
        case "refused", "busy", "stale", "changed", "protected", "rejected", "forbidden", "tailscaleRequired": return .refused
        default: return .unknown
        }
    }

    /// What the phone makes of the Mac's reply, whatever its status.  A typed
    /// body wins, because that is where a refusal says why.  Without one, a 4xx
    /// is still a definite refusal: nothing ran.  Only a reply that says nothing
    /// about the action leaves the outcome open.
    static func answer(status: Int, body: Data) -> CompanionServerActionResponse {
        if let typed = try? JSONDecoder().decode(CompanionServerActionResponse.self, from: body) {
            return typed
        }
        switch status {
        case 401:
            return CompanionServerActionResponse(status: "forbidden", error: "This iPhone is no longer paired with the Mac, so nothing was done.\u{00A0} Pair it again.")
        case 404:
            return CompanionServerActionResponse(status: "refused", error: "This Mac's copy of Hog Hunter is older than this app and has no server controls, so nothing was done.\u{00A0} Update it on the Mac.")
        case 429:
            return CompanionServerActionResponse(status: "refused", error: "The Mac asked this iPhone to slow down, so nothing was done.\u{00A0} Wait a moment, then try again.")
        case 400..<500:
            return CompanionServerActionResponse(status: "refused", error: "The Mac refused that, so nothing was done.")
        default:
            return CompanionServerActionResponse(status: "unknown", error: "The Mac's answer could not be read, so the outcome is not known.\u{00A0} Check the server before trying again.")
        }
    }
}

/// How a server action came out, as far as the phone can honestly say.
enum CompanionServerActionOutcome: Equatable, Sendable {
    /// It happened.
    case done
    /// Some of it happened, and some work may have been done.
    case partial
    /// It may have happened, and may still be going.
    case unknown
    /// The server looked and started nothing.
    case noWork
    /// Nothing ran.
    case refused

    var headline: String {
        switch self {
        case .done: return "Done"
        case .partial: return "Partly Done"
        case .unknown: return "Outcome Unknown"
        case .noWork: return "No Work Done"
        case .refused: return "Not Done"
        }
    }
}

/// What a server maintenance scan or run found, in the Mac card's words.
struct CompanionServerMaintenanceSummary: Codable, Equatable, Sendable {
    var mode: String
    var status: String
    var strategies: [CompanionServerMaintenanceRow]
    var removedBytesText: String? = nil
    var observedChangeText: String? = nil
}

struct CompanionServerMaintenanceRow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
}

// MARK: - Server status

/// Which of the phone's server states a reading is in.  The wire carries a
/// plain string, so a state a later Mac adds cannot stop this phone decoding
/// the whole snapshot.
enum CompanionServerState: String, Equatable, Sendable {
    /// The Mac has no server set up.  Nothing is wrong and nothing can be read.
    case notConfigured
    /// A server is set up and the Mac has not read it yet.
    case noReading
    /// The last read failed.  Earlier readings may still be in the block.
    case error
    /// The server's own reading is too old to be taken as the state of it now.
    case stale
    case ok
}

/// The server's readings, as the Mac last fetched them.
///
/// Process names, directories, mount notes and tool reasons name server
/// internals, so this block goes only to a phone's own token on the local
/// network or Tailscale while the owner has allowed it, and never into the
/// plain snapshot the shared pairing code reads.
///
/// A number the Mac does not have is nil and the phone draws `dash`, because a
/// zero would read as a measurement.  Everything is optional so an older or
/// newer Mac still decodes.
struct CompanionServerStatus: Codable, Equatable, Sendable {
    /// What the phone draws in place of a missing number.
    static let dash = "—"
    /// How old the server's own reading can be and still count as current.
    /// The same 15 minutes the Mac's pressure and storage readings allow.
    static let staleAfter: TimeInterval = 900
    /// How far ahead of this clock a reading can claim to be.  Further than
    /// this is a wrong clock on one side, not a fresh reading.
    static let futureTolerance: TimeInterval = 300

    var state: String
    var host: String? = nil
    /// When the server wrote the reading.
    var generatedAt: Date? = nil
    /// When the Mac last fetched it.
    var fetchedAt: Date? = nil
    /// The last read's failure, as one short line.  Can name the host.
    var errorText: String? = nil
    var headline: CompanionServerHeadline? = nil
    var cpu: CompanionServerCPU? = nil
    var memory: CompanionServerMeter? = nil
    var swap: CompanionServerMeter? = nil
    var pressure: CompanionServerPressure? = nil
    var devices: [CompanionServerDevice]? = nil
    var databases: [CompanionServerSizeRow]? = nil
    var directories: [CompanionServerSizeRow]? = nil
    var storageDiagnostics: CompanionServerStorageDiagnostics? = nil
    var tools: [CompanionServerTool]? = nil
    /// The busiest processes.  `processCount` is how many the server listed,
    /// which can be more than travel here.
    var processes: [CompanionServerProcess]? = nil
    var processCount: Int? = nil
    var workloads: [CompanionServerWorkload]? = nil

    /// Whether anything in the block came from a reading.
    var hasReading: Bool { generatedAt != nil || cpu != nil || memory != nil || devices?.isEmpty == false }

    /// The state to show now.  The Mac stamps a state when it publishes, and
    /// the phone keeps showing that snapshot if the Mac then goes quiet, so a
    /// reading that was current when it was sent still ages here.
    func resolvedState(now: Date = Date()) -> CompanionServerState {
        switch CompanionServerState(rawValue: state) {
        case .notConfigured: return .notConfigured
        case .noReading, nil: return .noReading
        case .error: return .error
        case .stale, .ok: return Self.readingState(generatedAt: generatedAt, now: now)
        }
    }

    /// A reading with no usable time cannot be called current.
    static func readingState(generatedAt: Date?, now: Date) -> CompanionServerState {
        guard let generatedAt else { return .stale }
        let age = now.timeIntervalSince(generatedAt)
        return age > staleAfter || age < -futureTolerance ? .stale : .ok
    }
}

/// The one-line answer to "is the server all right?".
struct CompanionServerHeadline: Codable, Equatable, Sendable {
    var host: String
    var cpuText: String? = nil
    var cpuSeverity: String? = nil
    var memoryText: String? = nil
    var memorySeverity: String? = nil
    var diskText: String? = nil
    var diskSeverity: String? = nil
    var extraDiskText: String? = nil
    var extraDiskSeverity: String? = nil
}

struct CompanionServerCPU: Codable, Equatable, Sendable {
    var percent: Double? = nil
    var percentText: String? = nil
    var severity: String? = nil
    var cores: Int? = nil
    var loadText: String? = nil
    /// One mean per minute, oldest first, 0 to 100.
    var history: [Double]? = nil
}

/// Memory or swap: how full it is and how much that is.
struct CompanionServerMeter: Codable, Equatable, Sendable {
    var percent: Double? = nil
    var percentText: String? = nil
    var detail: String? = nil
    var severity: String? = nil
}

/// Paging and stalls, measured over a short window on the server.
struct CompanionServerPressure: Codable, Equatable, Sendable {
    var sampledAt: Date? = nil
    var durationSeconds: Double? = nil
    var swapInText: String? = nil
    var swapOutText: String? = nil
    var memoryStallsText: String? = nil

    /// The same rule as the Mac's: a measured window of up to 10 seconds,
    /// taken within the last 15 minutes.
    func isFresh(now: Date = Date()) -> Bool {
        guard let sampledAt, let durationSeconds, durationSeconds > 0, durationSeconds <= 10 else { return false }
        let age = now.timeIntervalSince(sampledAt)
        return age >= -5 && age <= CompanionServerStatus.staleAfter
    }
}

struct CompanionServerDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var mount: String? = nil
    var freeText: String? = nil
    var totalText: String? = nil
    /// Nil when the server does not say how large the device is.
    var usedPercent: Double? = nil
    var usedText: String? = nil
    var severity: String? = nil
    var note: String? = nil
}

/// A database or a directory, with how much it changed over the last day.
struct CompanionServerSizeRow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var bytesText: String? = nil
    /// Nil until the Mac has a day of history to compare with.
    var changeText: String? = nil
    var changePercent: Double? = nil
}

struct CompanionServerStorageDiagnostics: Codable, Equatable, Sendable {
    var sampledAt: Date? = nil
    var durationSeconds: Double? = nil
    /// False when Docker's totals could not be read: the rows are then absent,
    /// not zero.
    var categoriesComplete: Bool? = nil
    var categories: [CompanionServerStorageCategory]? = nil
    var usesContainerd: Bool? = nil
    /// The containerd blob reading, or why there is none.
    var blobText: String? = nil

    /// The same rule as the Mac's: a window of up to 15 seconds, taken within
    /// the last 15 minutes.
    func isFresh(now: Date = Date()) -> Bool {
        guard let sampledAt, let durationSeconds, durationSeconds >= 0, durationSeconds <= 15 else { return false }
        let age = now.timeIntervalSince(sampledAt)
        return age >= -5 && age <= CompanionServerStatus.staleAfter
    }
}

struct CompanionServerStorageCategory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var sizeText: String? = nil
    var reclaimableText: String? = nil
}

struct CompanionServerTool: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// `running`, `stopped`, `absent` or `unknown`.
    var state: String
    var stateText: String
    var count: Int? = nil
    /// Why the state is what it is.  Names server internals.
    var reason: String? = nil
}

/// One server process.  `id` is opaque: it carries no pid, no boot id and no
/// start time, and only the Mac can turn it back into a process.
struct CompanionServerProcess: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var owner: String? = nil
    var container: String? = nil
    var cpuText: String? = nil
    var memoryText: String? = nil
    var swapText: String? = nil
    var isTamed: Bool? = nil
    var protectionReason: String? = nil
    /// What the Mac would accept for this row, from `CompanionServerControl`.
    var actions: [String]? = nil
}

/// One Coolify workload.  `id` is opaque, like a process's.
struct CompanionServerWorkload: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var type: String? = nil
    var status: String? = nil
    var isHealthy: Bool? = nil
    var cpuText: String? = nil
    var memoryText: String? = nil
    var protectionReason: String? = nil
    /// What the Mac would accept for this row, from `CompanionServerControl`.
    var actions: [String]? = nil
}

/// One Flagged Issues row.  A server row's text can name the host, a service
/// or a raw connection error, so a server row travels only with the server
/// block.  A Mac row names only what the plain snapshot's rows and drives name.
struct CompanionFlaggedIssue: Codable, Equatable, Identifiable, Sendable {
    static let serverHost = "Server"

    var id: String
    var title: String
    var message: String
    /// 0 is most urgent, 4 is informational.
    var priority: Int
    var priorityText: String
    /// `Mac` or `Server`.
    var host: String
    var category: String? = nil
    /// What the phone may do about it, by the Mac's word: `clean`, `quit` or
    /// `retry`.  A plain string rather than the enum, so a kind a later Mac adds
    /// leaves an older phone decoding the snapshot and simply showing no button.
    /// The Mac sends it only while the opt-in the action needs is on.
    var action: String? = nil

    var isServer: Bool { host == Self.serverHost }

    /// The action, when this phone knows it.
    var actionKind: CompanionIssueAction? { action.flatMap(CompanionIssueAction.init(rawValue:)) }

    /// The id the Mac gives a runaway-process issue.  The phone finds the row to
    /// quit from it, so a Quit button needs no new field: the row id is the one
    /// the snapshot's rows already carry, and the quit route re-checks it.
    static func quitIssueID(forRow rowId: String) -> String { "mac.cpu.hog.\(rowId)" }
}

/// What a Flagged Issue's button does on the phone.  Each maps to something the
/// phone already has: the server refresh, the quit flow with its confirmation,
/// or the Disk Cleaner screen.  None is a new way to change the Mac.
enum CompanionIssueAction: String, Codable, CaseIterable, Sendable {
    case clean
    case quit
    case retry

    /// The button's words, the same as the Mac panel's.
    var title: String {
        switch self {
        case .clean: return "Clean"
        case .quit: return "Quit"
        case .retry: return "Retry"
        }
    }
}

/// The server refresh route's rules, shared by the Mac and the phone.
enum CompanionServerRefresh {
    /// One forced read of the server per this many seconds, from every phone
    /// together.  The Mac's own poll is once a minute.
    static let minimumInterval: TimeInterval = 15
}

/// The Mac's answer to a server refresh.  `status` is `started`, `forbidden`,
/// `noServer`, `throttled` or `rejected`.  `retryAfter` is in seconds and comes with
/// `throttled`, beside the `Retry-After` header.
struct CompanionServerRefreshResponse: Codable, Equatable, Sendable {
    var status: String
    var message: String? = nil
    var error: String? = nil
    var retryAfter: Int? = nil

    var isStarted: Bool { status == "started" }
    var displayText: String { error ?? message ?? "The Mac did not say what happened." }

    /// What the phone makes of the reply, whatever its status.  A typed body
    /// wins, because that is where a refusal says why.
    static func answer(status: Int, body: Data) -> CompanionServerRefreshResponse {
        if let typed = try? JSONDecoder().decode(CompanionServerRefreshResponse.self, from: body) {
            return typed
        }
        switch status {
        case 401:
            return CompanionServerRefreshResponse(status: "forbidden", error: "This iPhone is no longer paired with the Mac.\u{00A0} Pair it again.")
        case 404:
            return CompanionServerRefreshResponse(status: "rejected", error: "This Mac's copy of Hog Hunter is older than this app and cannot refresh the server from iPhone.\u{00A0} Update it on the Mac.")
        case 429:
            return CompanionServerRefreshResponse(status: "throttled", error: "The server was just refreshed.\u{00A0} Wait a moment, then try again.")
        default:
            return CompanionServerRefreshResponse(status: "rejected", error: "The Mac did not refresh the server.")
        }
    }
}

/// What the phone can say about server status on this link.
enum CompanionServerAccess: Equatable, Sendable {
    /// The Mac predates server status.
    case macTooOld
    /// The owner has not turned on Allow iPhone to See Server Status.
    case optInOff
    /// It is on, but this link reads the plain snapshot: the shared pairing
    /// code, or an address outside the local network and Tailscale.
    case notOnThisLink
    case available(CompanionServerStatus)
}

/// What the top of the phone's issues section says.
enum CompanionFlaggedSummary: Equatable, Sendable {
    /// An older Mac sends no issues.  Silence, not "calm".
    case unavailable
    /// Issues to list.  `serverIncluded` says whether the server was looked at.
    case issues(count: Int, serverIncluded: Bool)
    /// Nothing on the Mac and nothing on a server with a current reading, or
    /// no server at all.  The only case that may say All Systems Calm.
    case allCalm
    /// Nothing on the Mac, and server issues are withheld on this link.
    case macCalmServerNotShown
    /// Nothing on the Mac, and the server has no current reading to judge.
    case macCalmServerUnknown
}

extension CompanionSnapshot {
    var serverAccess: CompanionServerAccess {
        if let server { return .available(server) }
        switch remoteServerStatusAllowed {
        case nil: return .macTooOld
        case false?: return .optInOff
        case true?: return .notOnThisLink
        }
    }

    /// An empty list only means calm when the server was looked at and its
    /// reading is current, or when there is no server to look at.
    func flaggedSummary(now: Date = Date()) -> CompanionFlaggedSummary {
        guard let flaggedIssues else { return .unavailable }
        let included = flaggedIssuesCoverServer == true && server != nil
        if !flaggedIssues.isEmpty {
            return .issues(count: flaggedIssues.count, serverIncluded: included)
        }
        guard included, let server else { return .macCalmServerNotShown }
        switch server.resolvedState(now: now) {
        case .ok, .notConfigured: return .allCalm
        case .noReading, .stale, .error: return .macCalmServerUnknown
        }
    }

    /// This snapshot with everything that names server internals taken out,
    /// for anything that outlives the screen: the widget's shared container.
    func withoutServerDetail() -> CompanionSnapshot {
        var copy = self
        copy.server = nil
        copy.flaggedIssues = flaggedIssues?.filter { !$0.isServer }
        copy.flaggedIssuesCoverServer = flaggedIssues == nil ? nil : false
        return copy
    }
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
