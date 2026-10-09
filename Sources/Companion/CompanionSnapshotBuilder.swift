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
        network: [CompanionNetworkRow]? = nil,
        networkNote: String? = nil,
        cleanProgress: CompanionCleanProgress? = nil,
        remoteQuitAllowed: Bool? = nil,
        remoteCleanAllowed: Bool? = nil
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
            network: network,
            networkNote: networkNote,
            remoteQuitAllowed: remoteQuitAllowed,
            remoteCleanAllowed: remoteCleanAllowed,
            cleanProgress: cleanProgress
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

        let breakdown = CleanCategory.allCases.map { cat in
            CompanionStorageCategorySummary(
                id: cat.rawValue,
                title: cat.title,
                description: cat.description,
                icon: cat.icon,
                isExcluded: exclusions.isCategoryExcluded(cat),
                isExtremeOnly: cat.isExtremeOnly
            )
        }

        return CompanionStorageSummary(
            freeBytes: freeBytes,
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            freeText: HogFormat.memory(freeBytes) + " Free",
            totalText: HogFormat.memory(totalBytes) + " Total",
            usedText: HogFormat.memory(usedBytes) + " Used",
            usedPercent: usedPct,
            excludedCategories: Array(exclusions.excludedCategories),
            excludedPathsCount: exclusions.excludedPaths.count,
            categoryBreakdown: breakdown,
            excludedPaths: Array(exclusions.excludedPaths).sorted(),
            topApps: Self.cachedTopApps(),
            topAppsScannedAt: Self.topAppsCache?.at
        )
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

    // MARK: - Top apps storage cache
    //
    // The Mac pane refreshes its App Storage list every five minutes via
    // `StorageStore`.  The phone wants the same top-N snapshot.  Rather than
    // running the scanner on every phone poll), we cache it here with the same
    // 5-minute cadence.  The cache is read on the main actor (the snapshot
    // builder is called from `HogStore.publishCompanion`, which is `@MainActor`)
    // and written from the scanner's background queue.

    private struct TopAppsCacheEntry {
        var at: Date
        var rows: [CompanionAppStorageRow]
    }

    nonisolated(unsafe) private static var topAppsCache: TopAppsCacheEntry?
    private static let topAppsLockInterval: TimeInterval = 5 * 60
    private static let topAppsLimit = 8
    private static let topAppsQueue = DispatchQueue(label: "hoghunter.companion.topapps", qos: .utility)
    private static var topAppsScanInFlight = false

    /// Returns the cached top-app rows without scanning.  The phone poll
    /// reads this on every request, so it has to be free.
    static func cachedTopApps() -> [CompanionAppStorageRow] {
        topAppsCache?.rows ?? []
    }

    /// Kicks off a `StorageScanner` walk on a utility queue if the cache is
    /// stale or empty.  Subsequent calls return the cached rows immediately
    /// and re-schedule a refresh in the background.  Safe to call on the
    /// main actor; the heavy work happens off-thread.
    static func refreshTopApps(runningBundleIds: @escaping () -> Set<String>) {
        let now = Date()
        if let cache = topAppsCache, now.timeIntervalSince(cache.at) < topAppsLockInterval {
            return
        }
        if topAppsScanInFlight { return }
        topAppsScanInFlight = true
        let limit = topAppsLimit
        topAppsQueue.async {
            let scanner = StorageScanner()
            let apps = scanner.installedApps(runningBundleIds: runningBundleIds())
            let top = apps
                .sorted { $0.totalBytes > $1.totalBytes }
                .prefix(limit)
                .map { usage -> CompanionAppStorageRow in
                    CompanionAppStorageRow(
                        id: usage.id,
                        name: usage.name,
                        bundleId: usage.bundleId,
                        totalBytes: usage.totalBytes,
                        bundleBytes: usage.bundleBytes,
                        hiddenBytes: usage.hiddenBytes,
                        totalText: HogFormat.memory(usage.totalBytes),
                        bundleText: HogFormat.memory(usage.bundleBytes),
                        hiddenText: HogFormat.memory(usage.hiddenBytes),
                        anyApproximate: usage.anyApproximate,
                        isHiddenHeavy: usage.isHiddenHeavy
                    )
                }
            DispatchQueue.main.async {
                topAppsCache = TopAppsCacheEntry(at: Date(), rows: Array(top))
                topAppsScanInFlight = false
            }
        }
    }

    /// Drops the in-memory top-app cache.  The next call to
    /// `refreshTopApps(runningBundleIds:)` will rescan from scratch.
    /// Exposed for tests and for the host's manual "Refresh" gesture so a
    /// user-initiated pull is not gated by the 5-minute cooldown.
    static func invalidateTopAppsCache() {
        topAppsCache = nil
    }
}
