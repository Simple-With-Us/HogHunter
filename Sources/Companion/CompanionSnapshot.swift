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
}

struct CompanionPulse: Codable, Equatable {
    /// Machine CPU, 0 to 100 across all cores.  Drives the meter, not the label.
    var cpuPercent: Double
    var cpuText: String
    var cpuCaption: String
    var cpuSeverity: String
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
