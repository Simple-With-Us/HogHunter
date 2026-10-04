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

/// Response returned when the iOS companion asks to quit a process on the Mac.
struct CompanionQuitResponse: Codable, Equatable, Sendable {
    var status: String
    var pid: Int32
    var name: String
    var message: String?
    var error: String?
}

/// Response returned when the iOS companion asks to tame or untame a process on the Mac.
struct CompanionTameResponse: Codable, Equatable, Sendable {
    var status: String
    var pid: Int32
    var name: String
    var isTamed: Bool
    var message: String?
    var error: String?
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

/// Read-only picture of the Mac panel.  Numbers are already formatted the way
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
