import Foundation
import SwiftUI

/// Priority categories for system health and resource issues.
///
/// Five tiers, strictly ordered from most urgent (P0 Critical) to informational (P4 Info).
enum FlaggedPriority: Int, Comparable, CaseIterable, Identifiable, Codable, Sendable {
    /// P0: Immediate danger — out of disk space, severe memory pressure, critical service down.
    case critical = 0
    /// P1: High priority — urgent resource exhaustion, sustained runaway process, server unreadable.
    case high = 1
    /// P2: Medium priority — warning thresholds, thermal throttling, elevated pressure.
    case medium = 2
    /// P3: Low priority — notice / trend, notable clutter accumulation, sampling lag.
    case low = 3
    /// P4: Info — system calm or informational notice.
    case info = 4

    var id: Int { rawValue }

    static func < (lhs: FlaggedPriority, rhs: FlaggedPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var badgeText: String {
        switch self {
        case .critical: return "P0 Critical"
        case .high: return "P1 High"
        case .medium: return "P2 Warning"
        case .low: return "P3 Notice"
        case .info: return "P4 Info"
        }
    }

    var shortLabel: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Warning"
        case .low: return "Notice"
        case .info: return "Info"
        }
    }

    var color: Color {
        switch self {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .info: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "info.circle.fill"
        case .info: return "checkmark.circle.fill"
        }
    }
}

enum IssueHost: String, Codable, Sendable {
    case mac = "Mac"
    case server = "Server"

    var systemImage: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .server: return "server.rack"
        }
    }
}

enum IssueCategory: String, Codable, Sendable {
    case disk = "Storage"
    case cpu = "CPU"
    case memory = "Memory"
    case service = "Service"
    case maintenance = "Maintenance"

    var systemImage: String {
        switch self {
        case .disk: return "internaldrive"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .service: return "gearshape.2"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

/// A flagged issue requiring operator awareness or action.
struct FlaggedIssue: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var message: String
    var priority: FlaggedPriority
    var host: IssueHost
    var category: IssueCategory
    var actionTitle: String?
    var timestamp: Date

    init(
        id: String,
        title: String,
        message: String,
        priority: FlaggedPriority,
        host: IssueHost,
        category: IssueCategory,
        actionTitle: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.priority = priority
        self.host = host
        self.category = category
        self.actionTitle = actionTitle
        self.timestamp = timestamp
    }
}

/// Evaluates live Mac and Server state to produce prioritized flagged issues.
enum FlaggedIssueEvaluator {
    /// Minimum free bytes before flagging critical disk full (10 GB).
    static let criticalFreeDiskFloor: Int64 = 10 * 1024 * 1024 * 1024
    /// Minimum free bytes before flagging low disk warning (25 GB).
    static let lowFreeDiskFloor: Int64 = 25 * 1024 * 1024 * 1024

    private static func formatBytes(_ bytes: Int64) -> String {
        HogFormat.memory(UInt64(max(0, bytes)))
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        HogFormat.memory(bytes)
    }

    @MainActor
    static func evaluate(
        macStore: HogStore,
        vpsSnapshot: VPSStatusSnapshot?,
        vpsError: String?,
        vpsConfigured: Bool,
        externalDrives: [MountedDriveUsage] = []
    ) -> [FlaggedIssue] {
        var issues: [FlaggedIssue] = []

        // MARK: - Mac Disk Checks
        if let disk = macStore.diskSpace {
            if disk.freeBytes < criticalFreeDiskFloor || disk.usedFraction >= 0.95 {
                issues.append(FlaggedIssue(
                    id: "mac.disk.critical",
                    title: "Mac Boot Drive Critically Full",
                    message: "\(formatBytes(disk.freeBytes)) remaining (\(Int(disk.usedFraction * 100))% used).",
                    priority: .critical,
                    host: .mac,
                    category: .disk,
                    actionTitle: "Clean"
                ))
            } else if disk.freeBytes < lowFreeDiskFloor || disk.usedFraction >= 0.90 {
                issues.append(FlaggedIssue(
                    id: "mac.disk.low",
                    title: "Mac Boot Drive Space Low",
                    message: "\(formatBytes(disk.freeBytes)) remaining (\(Int(disk.usedFraction * 100))% used).",
                    priority: .high,
                    host: .mac,
                    category: .disk,
                    actionTitle: "Clean"
                ))
            } else if disk.usedFraction >= 0.85 {
                issues.append(FlaggedIssue(
                    id: "mac.disk.warning",
                    title: "Mac Boot Drive Filling Up",
                    message: "\(formatBytes(disk.freeBytes)) free (\(Int(disk.usedFraction * 100))% used).",
                    priority: .medium,
                    host: .mac,
                    category: .disk
                ))
            }
        }

        // External drives
        for drive in externalDrives {
            let usedPct = drive.usedPercent ?? 0
            guard let avail = drive.availableBytes else { continue }
            if (avail < 5 * 1024 * 1024 * 1024 && avail > 0) || usedPct >= 95 {
                issues.append(FlaggedIssue(
                    id: "mac.drive.\(drive.id).critical",
                    title: "External Drive Almost Full",
                    message: "\(drive.name): \(formatBytes(avail)) remaining (\(Int(usedPct))% used).",
                    priority: .high,
                    host: .mac,
                    category: .disk
                ))
            }
        }

        // MARK: - Mac Memory & CPU
        if macStore.pulse.pressure == .critical {
            issues.append(FlaggedIssue(
                id: "mac.memory.critical",
                title: "Mac Memory Pressure Critical",
                message: "System is experiencing severe RAM pressure.",
                priority: .critical,
                host: .mac,
                category: .memory
            ))
        } else if macStore.pulse.pressure == .warning {
            issues.append(FlaggedIssue(
                id: "mac.memory.warning",
                title: "Mac Memory Pressure Elevated",
                message: "RAM pressure is elevated; heavy processes may swap.",
                priority: .medium,
                host: .mac,
                category: .memory
            ))
        }

        // Heavy runaway processes (evaluated by highest CPU regardless of current view sort)
        let topHogs = macStore.rows.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
        for hog in topHogs where hog.cpuPercent >= 200.0 {
            issues.append(FlaggedIssue(
                id: "mac.cpu.hog.\(hog.id)",
                title: "Runaway CPU Hog: \(hog.name)",
                message: "Using \(HogFormat.cpu(hog.cpuPercent)) of one core.",
                priority: hog.cpuPercent >= 300.0 ? .critical : .high,
                host: .mac,
                category: .cpu,
                actionTitle: hog.canQuit ? "Quit" : nil
            ))
        }

        // Thermal state
        if macStore.pulse.thermalState == .critical {
            issues.append(FlaggedIssue(
                id: "mac.thermal.critical",
                title: "Mac Thermal Throttling Critical",
                message: "CPU is heavily throttled due to high heat.",
                priority: .high,
                host: .mac,
                category: .cpu
            ))
        } else if macStore.pulse.thermalState == .serious {
            issues.append(FlaggedIssue(
                id: "mac.thermal.serious",
                title: "Mac Thermal Throttling",
                message: "CPU clock is reduced due to temperature.",
                priority: .medium,
                host: .mac,
                category: .cpu
            ))
        }

        // Sampler staleness
        if macStore.isStale {
            issues.append(FlaggedIssue(
                id: "mac.sampler.stale",
                title: "Sampling Falling Behind",
                message: "Process sampler did not update within the refresh window.",
                priority: .low,
                host: .mac,
                category: .maintenance
            ))
        }

        // MARK: - Server Issues
        if vpsConfigured {
            if let vpsError, !vpsError.isEmpty {
                issues.append(FlaggedIssue(
                    id: "server.unreachable",
                    title: "Remote Server Unreadable",
                    message: vpsError,
                    priority: .high,
                    host: .server,
                    category: .service,
                    actionTitle: "Retry"
                ))
            }

            if let snap = vpsSnapshot {
                // Server root disk
                if let root = snap.rootDevice {
                    if root.freeBytes < criticalFreeDiskFloor || (root.usedFraction ?? 0) >= 0.95 {
                        issues.append(FlaggedIssue(
                            id: "server.disk.root.critical",
                            title: "Server Root Disk (/) Critically Full",
                            message: "\(formatBytes(root.freeBytes)) free on \(snap.host).",
                            priority: .critical,
                            host: .server,
                            category: .disk
                        ))
                    } else if root.freeBytes < lowFreeDiskFloor || (root.usedFraction ?? 0) >= 0.90 {
                        issues.append(FlaggedIssue(
                            id: "server.disk.root.low",
                            title: "Server Root Disk Space Low",
                            message: "\(formatBytes(root.freeBytes)) remaining (\(Int((root.usedFraction ?? 0) * 100))% used).",
                            priority: .high,
                            host: .server,
                            category: .disk
                        ))
                    } else if (root.usedFraction ?? 0) >= 0.85 {
                        issues.append(FlaggedIssue(
                            id: "server.disk.root.warning",
                            title: "Server Root Disk Filling Up",
                            message: "\(Int((root.usedFraction ?? 0) * 100))% used on \(snap.host).",
                            priority: .medium,
                            host: .server,
                            category: .disk
                        ))
                    }
                }

                // Server fleet-extra volume
                if let extra = snap.fleetExtraDevice {
                    if extra.freeBytes < 15 * 1024 * 1024 * 1024 || (extra.usedFraction ?? 0) >= 0.95 {
                        issues.append(FlaggedIssue(
                            id: "server.disk.extra.critical",
                            title: "Server Volume /mnt/fleet-extra Full",
                            message: "\(formatBytes(extra.freeBytes)) remaining on extra volume.",
                            priority: .critical,
                            host: .server,
                            category: .disk
                        ))
                    } else if extra.freeBytes < 30 * 1024 * 1024 * 1024 || (extra.usedFraction ?? 0) >= 0.90 {
                        issues.append(FlaggedIssue(
                            id: "server.disk.extra.low",
                            title: "Server Volume /mnt/fleet-extra Low",
                            message: "\(formatBytes(extra.freeBytes)) free on /mnt/fleet-extra.",
                            priority: .high,
                            host: .server,
                            category: .disk
                        ))
                    } else if (extra.usedFraction ?? 0) >= 0.85 {
                        issues.append(FlaggedIssue(
                            id: "server.disk.extra.warning",
                            title: "Server /mnt/fleet-extra Filling Up",
                            message: "\(Int((extra.usedFraction ?? 0) * 100))% used on /mnt/fleet-extra.",
                            priority: .medium,
                            host: .server,
                            category: .disk
                        ))
                    }
                }

                // Server CPU & Load
                if let cpu = snap.cpu {
                    if cpu.pct >= 85.0 || cpu.load1 > Double(cpu.cores * 2) {
                        issues.append(FlaggedIssue(
                            id: "server.cpu.high",
                            title: "Server CPU / Load High",
                            message: "\(String(format: "%.0f%%", cpu.pct)) CPU, 1m load \(String(format: "%.1f", cpu.load1)) (\(cpu.cores) cores).",
                            priority: .high,
                            host: .server,
                            category: .cpu
                        ))
                    } else if cpu.pct >= 70.0 {
                        issues.append(FlaggedIssue(
                            id: "server.cpu.elevated",
                            title: "Server CPU Elevated",
                            message: "\(String(format: "%.0f%%", cpu.pct)) CPU on \(snap.host).",
                            priority: .medium,
                            host: .server,
                            category: .cpu
                        ))
                    }
                }

                // Server RAM & Swap
                if let mem = snap.memory {
                    if mem.usedPercentage >= 90.0 {
                        issues.append(FlaggedIssue(
                            id: "server.memory.high",
                            title: "Server RAM Exhaustion",
                            message: "\(String(format: "%.0f%%", mem.usedPercentage)) used (\(formatBytes(mem.availableBytes)) available).",
                            priority: .high,
                            host: .server,
                            category: .memory
                        ))
                    } else if mem.usedPercentage >= 80.0 {
                        issues.append(FlaggedIssue(
                            id: "server.memory.warning",
                            title: "Server RAM Elevated",
                            message: "\(String(format: "%.0f%%", mem.usedPercentage)) used on \(snap.host).",
                            priority: .medium,
                            host: .server,
                            category: .memory
                        ))
                    }
                }

                if let swap = snap.swap, swap.usedPercentage >= 75.0 {
                    issues.append(FlaggedIssue(
                        id: "server.swap.high",
                        title: "Server Swap Usage High",
                        message: "\(String(format: "%.0f%%", swap.usedPercentage)) swap used (\(formatBytes(swap.usedBytes))).",
                        priority: .high,
                        host: .server,
                        category: .memory
                    ))
                }

                // Server tool statuses (stopped)
                for tool in snap.toolStatuses ?? [] {
                    if tool.state == .stopped && ["docker", "postgres", "redis", "shellular"].contains(tool.id) {
                        issues.append(FlaggedIssue(
                            id: "server.tool.\(tool.id).stopped",
                            title: "Critical Service Stopped: \(tool.name)",
                            message: "Essential service is stopped on \(snap.host).",
                            priority: .high,
                            host: .server,
                            category: .service
                        ))
                    }
                }
            }
        }

        // Sort strictly by priority: Critical (0), High (1), Medium (2), Low (3), Info (4)
        return issues.sorted { $0.priority < $1.priority }
    }
}
