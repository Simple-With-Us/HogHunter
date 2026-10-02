import AppKit
import Foundation
import SwiftUI

// MARK: - User choices

enum TimeWindow: String, CaseIterable, Identifiable {
    case now = "Now"
    case hour = "Past Hour"
    case day = "Past 24 Hours"

    var id: String { rawValue }

    var lookback: TimeInterval? {
        switch self {
        case .now: return nil
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        }
    }
}

enum HogSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"

    var id: String { rawValue }
}

enum HogGrouping: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case processes = "Processes"

    var id: String { rawValue }
}

/// How per-process CPU is shown.  `perCore` is Activity Monitor's scale where
/// 100% is one core fully busy.  `machineShare` divides by the core count so a
/// row and the header share one 0-100 scale.
enum CpuScale: String, CaseIterable, Identifiable {
    case perCore = "Per Core"
    case machineShare = "Share of Machine"

    var id: String { rawValue }
}

enum MenuBarLabelMode: String, CaseIterable, Identifiable {
    case machinePercent = "Machine CPU"
    case topHogName = "Top Hog"
    case sparkline = "Live Sparkline"

    var id: String { rawValue }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case light = "Light"
    case system = "System"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - Sampling types

/// A process identity that survives pid reuse.  `startTime` is
/// `ri_proc_start_abstime`; 0 when the kernel did not report one.
struct ProcessKey: Hashable, Codable {
    let pid: pid_t
    let startTime: UInt64

    var isKernelTask: Bool { pid == 0 }
}

/// One process as the sampler saw it.  Cheap fields only: no AppKit, no icons.
struct ProcessSample: Identifiable {
    var id: ProcessKey { key }
    let key: ProcessKey
    let ppid: pid_t
    let uid: uid_t
    /// `proc_name`, or the executable's last path component when the name is
    /// at the 31-character truncation limit.
    let name: String
    /// `proc_pidpath`, or "" when unavailable.
    let path: String
    /// Activity Monitor's scale: 100% is one core fully busy.  0 until a
    /// baseline exists for this key.
    let cpuPercent: Double
    let hasBaseline: Bool
    /// `ri_phys_footprint`, Activity Monitor's Memory column.  Falls back to
    /// `residentBytes` when rusage is unavailable.
    let footprintBytes: UInt64
    let residentBytes: UInt64
    let threadCount: Int
    let diskReadBytesPerSec: Double
    let diskWriteBytesPerSec: Double
    let idleWakeupsPerSec: Double
    var isSleepBlocker: Bool = false
    var isTamed: Bool = false
    var isKernelTask: Bool { key.isKernelTask }
}

enum MemoryPressure: Int, Equatable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

struct MachinePulse: Equatable {
    /// 0-100 across all cores, from host_statistics tick deltas.
    var cpuPercent: Double
    var coreCount: Int
    /// Sum of readable per-core CPU divided by `coreCount`, 0-100.
    var visibleCpuPercent: Double
    var readableProcessCount: Int
    /// Processes whose task info is denied (other users, root).
    var unreadableProcessCount: Int
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    var memoryUsedBytes: UInt64
    var appMemoryBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedFilesBytes: UInt64
    var totalMemoryBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var swapInBytesPerSec: Double
    var swapOutBytesPerSec: Double
    var pressure: MemoryPressure
    var thermalState: ProcessInfo.ThermalState
    var batteryPercent: Int? = nil
    var isCharging: Bool? = nil
    var powerSource: String? = nil
    var sampledAt: Date

    static let empty = MachinePulse(
        cpuPercent: 0, coreCount: max(1, ProcessInfo.processInfo.activeProcessorCount), visibleCpuPercent: 0,
        readableProcessCount: 0, unreadableProcessCount: 0,
        memoryUsedBytes: 0, appMemoryBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0,
        totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        swapUsedBytes: 0, swapTotalBytes: 0, swapInBytesPerSec: 0, swapOutBytesPerSec: 0,
        pressure: .unknown, thermalState: .nominal,
        batteryPercent: nil, isCharging: nil, powerSource: nil,
        sampledAt: .distantPast
    )

    var memoryPercent: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(totalMemoryBytes) * 100
    }

    /// Machine CPU not attributable to any readable process, 0-100.
    var invisibleCpuPercent: Double { max(0, cpuPercent - visibleCpuPercent) }
}

/// Result of one sampler pass.
struct Snapshot {
    var pulse: MachinePulse
    var processes: [ProcessSample]
    /// False on the first pass, when no process has a CPU baseline yet.
    var hasBaseline: Bool
}

// MARK: - Rows

struct HogRow: Identifiable, Hashable {
    /// "a-<groupKey>" for app groups, "p-<pid>-<start>" for processes,
    /// "h-<key>" for history rows.
    var id: String
    /// Live members; empty for history rows.
    var keys: [ProcessKey]
    var name: String
    var detail: String
    /// Per-core scale, before any `CpuScale` conversion for display.
    var cpuPercent: Double
    /// Footprint, summed across group members.
    var memoryBytes: UInt64
    /// History only.
    var peakMemoryBytes: UInt64?
    /// History only: fraction (0-1) of window samples in which the key appeared.
    var presence: Double?
    var icon: NSImage?
    var path: String?
    var isApp: Bool
    var isGroup: Bool
    var canQuit: Bool
    /// Why Quit is unavailable: "system process", "owned by another user", "this app".
    var quitBlockReason: String?
    var isTamed: Bool = false
    var isSleepBlocker: Bool = false
    var canTame: Bool = false

    var pid: pid_t? { keys.first?.pid }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Every stored property except `icon`, which is an `NSImage` reference
    /// that is stable per bundle and would only ever compare by identity.
    static func == (lhs: HogRow, rhs: HogRow) -> Bool {
        lhs.id == rhs.id
            && lhs.cpuPercent == rhs.cpuPercent
            && lhs.memoryBytes == rhs.memoryBytes
            && lhs.keys == rhs.keys
            && lhs.name == rhs.name
            && lhs.detail == rhs.detail
            && lhs.path == rhs.path
            && lhs.isApp == rhs.isApp
            && lhs.isGroup == rhs.isGroup
            && lhs.peakMemoryBytes == rhs.peakMemoryBytes
            && lhs.presence == rhs.presence
            && lhs.canQuit == rhs.canQuit
            && lhs.quitBlockReason == rhs.quitBlockReason
            && lhs.isTamed == rhs.isTamed
            && lhs.isSleepBlocker == rhs.isSleepBlocker
            && lhs.canTame == rhs.canTame
    }
}

// MARK: - Severity

enum Severity: Equatable {
    case calm
    case elevated
    case hot

    /// Header CPU on the 0-100 all-cores scale.
    static func forMachineCpu(_ percent: Double) -> Severity {
        if percent >= 85 { return .hot }
        if percent >= 60 { return .elevated }
        return .calm
    }

    /// Row CPU on whatever scale the value is already on.  The per-core scale
    /// is calibrated against the original Activity Monitor thresholds
    /// (300% = 3 cores busy, 100% = 1 core busy); `machineShare` divides the
    /// per-core thresholds by `coreCount` so the colour tracks the value the
    /// user is actually looking at.
    static func forProcessCpu(_ percent: Double, scale: CpuScale = .perCore, coreCount: Int = 1) -> Severity {
        let perCore: Double
        switch scale {
        case .perCore: perCore = percent
        case .machineShare: perCore = percent * Double(max(1, coreCount))
        }
        if perCore >= 300 { return .hot }
        if perCore >= 100 { return .elevated }
        return .calm
    }

    static func forPressure(_ pressure: MemoryPressure) -> Severity {
        switch pressure {
        case .critical: return .hot
        case .warning: return .elevated
        case .normal, .unknown: return .calm
        }
    }

    var color: Color {
        switch self {
        case .calm: return Color(red: 0.18, green: 0.42, blue: 0.78)
        case .elevated: return Color(red: 0.80, green: 0.52, blue: 0.10)
        case .hot: return Color(red: 0.75, green: 0.18, blue: 0.16)
        }
    }
}

// MARK: - Formatting

enum HogFormat {
    /// Locale that prints `.` as the decimal separator regardless of the
    /// user's region.  Cached because `Locale(identifier:)` is not free, and
    /// every formatted number in the panel goes through here.
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// One decimal below 100, an integer at or above.  Always a "%" suffix.
    static func cpu(_ value: Double) -> String {
        let v = value.isFinite ? max(0, value) : 0
        if v < 100 { return String(format: "%.1f%%", locale: posix, v) }
        return String(format: "%.0f%%", locale: posix, v)
    }

    /// Converts a per-core value for display under the chosen scale.
    static func cpu(_ perCore: Double, scale: CpuScale, coreCount: Int) -> String {
        switch scale {
        case .perCore: return cpu(perCore)
        case .machineShare: return cpu(perCore / Double(max(1, coreCount)))
        }
    }

    /// Binary units labeled GB and MB, like Activity Monitor.  Integer MB
    /// below 1 GB, one decimal GB above.  The unit is chosen against the value
    /// the next unit down would round to, so "1024 MB" and "1024 KB" -- which
    /// are just the next unit up -- can never be printed.
    static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        let kb = Double(bytes) / 1024
        if mb >= 1023.5 { return String(format: "%.1f GB", locale: posix, gb) }
        if kb >= 1023.5 { return String(format: "%.0f MB", locale: posix, mb) }
        return String(format: "%.0f KB", locale: posix, kb)
    }

    /// "12 MB/s", "1.4 GB/s", "0 KB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 KB/s" }
        return memory(UInt64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", locale: posix, max(0, min(1, fraction)) * 100)
    }
}
