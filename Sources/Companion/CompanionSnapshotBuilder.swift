import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Builds the phone snapshot from the rows the Mac panel is already showing.
enum CompanionSnapshotBuilder {
    static func make(
        hostName: String,
        sampledAt: Date,
        hasBaseline: Bool,
        window: TimeWindow,
        grouping: HogGrouping,
        scale: CpuScale,
        pulse: MachinePulse,
        rows: [HogRow],
        storage: CompanionStorageSummary? = nil,
        network: [CompanionNetworkRow]? = nil
    ) -> CompanionSnapshot {
        let cores = max(1, pulse.coreCount)
        let pressure = Severity.forPressure(pulse.pressure)
        return CompanionSnapshot(
            version: CompanionService.version,
            hostName: hostName,
            sampledAt: sampledAt,
            hasBaseline: hasBaseline,
            window: window.rawValue,
            grouping: grouping.rawValue,
            cpuScale: scale.rawValue,
            pulse: CompanionPulse(
                cpuPercent: pulse.cpuPercent,
                cpuText: hasBaseline ? HogFormat.percent(pulse.cpuPercent / 100) : "Measuring…",
                cpuCaption: "of all \(cores) cores",
                cpuSeverity: severityName(Severity.forMachineCpu(pulse.cpuPercent)),
                memoryPercent: pulse.memoryPercent,
                memoryText: "\(gigabytes(pulse.memoryUsedBytes)) of \(gigabytes(pulse.totalMemoryBytes)) GB",
                memoryCaption: "Memory in use",
                swapText: pulse.swapUsedBytes > 0 ? "\(HogFormat.memory(pulse.swapUsedBytes)) swapped" : nil,
                pressureText: pulse.pressure == .unknown ? nil : "Pressure \(pulse.pressure.label)",
                pressureSeverity: severityName(pressure),
                thermalState: thermalStateName(pulse.thermalState),
                batteryPercent: pulse.batteryPercent,
                isCharging: pulse.isCharging,
                powerSource: pulse.powerSource
            ),
            rows: rows.map { row in
                let display = displayedCPU(row.cpuPercent, scale: scale, coreCount: cores)
                let severity = Severity.forProcessCpu(display, scale: scale, coreCount: cores)
                return CompanionRow(
                    id: row.id,
                    name: row.name,
                    detail: row.detail,
                    cpuText: HogFormat.cpu(row.cpuPercent, scale: scale, coreCount: cores),
                    memoryText: HogFormat.memory(row.memoryBytes),
                    severity: severityName(severity),
                    isApp: row.isApp,
                    cpuPercent: row.cpuPercent,
                    memoryBytes: row.memoryBytes,
                    pid: row.keys.first?.pid,
                    canQuit: row.canQuit,
                    quitBlockReason: row.quitBlockReason,
                    isTamed: row.isTamed,
                    isSleepBlocker: row.isSleepBlocker,
                    canTame: row.canTame
                )
            },
            storage: storage ?? currentStorageSummary(),
            network: network
        )
    }

    static func currentStorageSummary() -> CompanionStorageSummary? {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0 else {
            return nil
        }
        let totalBytes = UInt64(total)
        let freeBytes = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)))
        let usedBytes = totalBytes > freeBytes ? totalBytes - freeBytes : 0
        let usedPct = totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) * 100.0 : 0.0
        let exclusions = CleanerExclusions.load()

        return CompanionStorageSummary(
            freeBytes: freeBytes,
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            freeText: HogFormat.memory(freeBytes) + " Free",
            totalText: HogFormat.memory(totalBytes) + " Total",
            usedText: HogFormat.memory(usedBytes) + " Used",
            usedPercent: usedPct,
            excludedCategories: Array(exclusions.excludedCategories),
            excludedPathsCount: exclusions.excludedPaths.count
        )
    }

    static func currentNetworkRows(limit: Int = 10) -> [CompanionNetworkRow]? {
        let scanner = NetworkScanner()
        let snapshot = scanner.snapshot { pid in
            #if canImport(AppKit)
            if let app = NSRunningApplication(processIdentifier: pid) {
                return (bundleId: app.bundleIdentifier, name: app.localizedName ?? "PID \(pid)")
            }
            #endif
            return (bundleId: nil, name: "PID \(pid)")
        }
        guard case let .snapshot(_, usages) = snapshot else { return nil }
        let top = usages.sorted { $0.establishedSockets > $1.establishedSockets }.prefix(limit)
        return top.map { usage in
            CompanionNetworkRow(
                id: "\(usage.pid)",
                name: usage.name,
                pid: usage.pid,
                establishedCount: usage.establishedSockets,
                uniqueRemoteHosts: usage.remoteHostCount,
                sampleRemoteHosts: usage.topRemoteHosts
            )
        }
    }

    private static func displayedCPU(_ perCore: Double, scale: CpuScale, coreCount: Int) -> Double {
        switch scale {
        case .perCore:
            return perCore
        case .machineShare:
            return perCore / Double(max(1, coreCount))
        }
    }

    private static func severityName(_ severity: Severity) -> String {
        switch severity {
        case .calm: return "calm"
        case .elevated: return "elevated"
        case .hot: return "hot"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Same rounding the Mac memory caption uses: integer when the value is whole.
    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        let posix = Locale(identifier: "en_US_POSIX")
        if value == value.rounded() {
            return String(format: "%.0f", locale: posix, value)
        }
        return String(format: "%.1f", locale: posix, value)
    }
}
