import CryptoKit
import Foundation

/// Turns what the Mac read from the server into the phone's server block.
///
/// Mac only: the phone sees the wire types in `CompanionSnapshot.swift`, never
/// the server's own models.  Two things happen here that the phone relies on.
/// A number the server did not give stays nil, so the phone draws a dash and
/// never a zero.  And every `Double` is checked for being finite, because one
/// NaN or infinity makes `JSONEncoder` refuse the whole snapshot, which would
/// freeze the phone on its last reading.
enum CompanionServerStatusBuilder {
    /// As many as the Mac's own card lists.
    static let processLimit = 12
    /// Enough for any real host, and a ceiling on what one poll carries.
    static let workloadLimit = 40
    static let directoryLimit = 20
    /// One line of a connection error is what the phone needs.
    static let errorTextLimit = 240

    static func make(
        configuredHost: String,
        snapshot: VPSStatusSnapshot?,
        error: String?,
        fetchedAt: Date?,
        cpuHistory: [Double],
        databaseChange: (String) -> Double?,
        directoryChange: (String) -> Double?,
        now: Date = Date()
    ) -> CompanionServerStatus {
        let host = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return CompanionServerStatus(state: CompanionServerState.notConfigured.rawValue)
        }
        let errorText = oneLine(error)
        guard let snapshot else {
            let state: CompanionServerState = errorText == nil ? .noReading : .error
            return CompanionServerStatus(state: state.rawValue, fetchedAt: fetchedAt, errorText: errorText)
        }
        let generatedAt = snapshot.generatedAtDate
        let state: CompanionServerState = errorText != nil
            ? .error
            : CompanionServerStatus.readingState(generatedAt: generatedAt, now: now)
        let cpu = snapshot.cpu.map { self.cpu($0, history: cpuHistory) }
        let memory = snapshot.memory.flatMap(self.memory)
        let swap = snapshot.swap.flatMap(self.swap)
        let devices = self.devices(snapshot)
        let processes = snapshot.processes
        return CompanionServerStatus(
            state: state.rawValue,
            host: snapshot.host.isEmpty ? nil : snapshot.host,
            generatedAt: generatedAt,
            fetchedAt: fetchedAt,
            errorText: errorText,
            headline: headline(snapshot, cpu: cpu, memory: memory),
            cpu: cpu,
            memory: memory,
            swap: swap,
            pressure: snapshot.memoryPressure.map(pressure),
            devices: devices,
            databases: snapshot.appDbs.map { databases($0, change: databaseChange) },
            directories: snapshot.largestDirs.map { directories($0, change: directoryChange) },
            storageDiagnostics: snapshot.storageDiagnostics.map(diagnostics),
            tools: snapshot.toolStatuses?.map(tool),
            processes: processes?.prefix(processLimit).map(process),
            processCount: processes?.count,
            workloads: snapshot.coolify?.prefix(workloadLimit).map(workload)
        )
    }

    /// The Flagged Issues as the phone reads them.  The Mac's action buttons
    /// stay behind: this stage of the phone cannot act on them.
    static func issues(_ issues: [FlaggedIssue]) -> [CompanionFlaggedIssue] {
        issues.map { issue in
            CompanionFlaggedIssue(
                id: issue.id,
                title: issue.title,
                message: issue.message,
                priority: issue.priority.rawValue,
                priorityText: issue.priority.shortLabel,
                host: issue.host == .server ? CompanionFlaggedIssue.serverHost : issue.host.rawValue,
                category: issue.category.rawValue
            )
        }
    }

    /// An id the phone can hand back later without having learned anything.
    /// Hex of a hash, because the row ids the server uses carry the pid, the
    /// boot id and the start time.
    static func opaqueID(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pieces

    private static func headline(_ snapshot: VPSStatusSnapshot, cpu: CompanionServerCPU?, memory: CompanionServerMeter?) -> CompanionServerHeadline? {
        guard !snapshot.host.isEmpty else { return nil }
        let disk = fraction(snapshot.rootDevice?.usedFraction)
        let extra = fraction(snapshot.fleetExtraDevice?.usedFraction)
        return CompanionServerHeadline(
            host: snapshot.host,
            cpuText: cpu?.percent.map { String(format: "%.0f%%", $0) },
            cpuSeverity: cpu?.severity,
            memoryText: memory?.percentText,
            memorySeverity: memory?.severity,
            diskText: disk.map { String(format: "%.0f%% used", $0 * 100) },
            diskSeverity: disk.map { CompanionSnapshotBuilder.severityName(Severity.forDisk($0)) },
            extraDiskText: extra.map { String(format: "%.0f%% used", $0 * 100) },
            extraDiskSeverity: extra.map { CompanionSnapshotBuilder.severityName(Severity.forDisk($0)) }
        )
    }

    private static func cpu(_ cpu: VPSCPU, history: [Double]) -> CompanionServerCPU {
        let percent = nonNegative(cpu.pct)
        return CompanionServerCPU(
            percent: percent,
            percentText: percent.map { String(format: "%.1f%%", $0) },
            severity: percent == nil ? nil : CompanionSnapshotBuilder.severityName(cpu.severity),
            cores: cpu.cores > 0 ? cpu.cores : nil,
            loadText: nonNegative(cpu.load1).map { String(format: "%.2f", $0) },
            history: history.filter(\.isFinite)
        )
    }

    /// Nil when the total is missing: a machine with no memory did not report
    /// zero percent, it did not report.
    private static func memory(_ memory: VPSMemory) -> CompanionServerMeter? {
        guard memory.totalBytes > 0, memory.usedBytes >= 0 else { return nil }
        return CompanionServerMeter(
            percent: nonNegative(memory.usedPercentage),
            percentText: String(format: "%.0f%%", memory.usedPercentage),
            detail: "\(size(memory.usedBytes)) of \(size(memory.totalBytes))",
            severity: CompanionSnapshotBuilder.severityName(memory.severity)
        )
    }

    /// A server with no swap has no percentage to show, and says so.
    private static func swap(_ swap: VPSSwap) -> CompanionServerMeter? {
        guard swap.usedBytes >= 0, swap.totalBytes >= 0 else { return nil }
        guard swap.totalBytes > 0 else { return CompanionServerMeter(detail: "No swap") }
        return CompanionServerMeter(
            percent: nonNegative(swap.usedPercentage),
            percentText: String(format: "%.0f%%", swap.usedPercentage),
            detail: "\(size(swap.usedBytes)) of \(size(swap.totalBytes)) swapped",
            severity: CompanionSnapshotBuilder.severityName(swap.severity)
        )
    }

    private static func pressure(_ pressure: VPSMemoryPressure) -> CompanionServerPressure {
        CompanionServerPressure(
            sampledAt: pressure.sampledAtDate,
            durationSeconds: finite(pressure.durationSeconds),
            swapInText: rate(pressure.swapInBytesPerSecond),
            swapOutText: rate(pressure.swapOutBytesPerSecond),
            memoryStallsText: nonNegative(pressure.memoryFullAvg10).map { String(format: "%.1f%%", $0) }
        )
    }

    private static func rate(_ bytes: Double?) -> String? {
        guard let bytes = nonNegative(bytes), bytes < Double(UInt64.max) else { return nil }
        return HogFormat.memory(UInt64(bytes)) + "/s"
    }

    /// In the Mac card's order: the disks it names first, then anything else
    /// the server reported, so a device the Mac has no title for still shows.
    private static func devices(_ snapshot: VPSStatusSnapshot) -> [CompanionServerDevice] {
        let extra = ["fleet_extra", "fleet-extra", "extra"].first { snapshot.devices[$0] != nil }
            ?? snapshot.devices.keys.sorted().first {
                let mount = snapshot.devices[$0]?.mount ?? ""
                return mount == "/mnt/fleet-extra" || mount.hasPrefix("/mnt/fleet-extra/")
            }
        var titled: [(key: String, title: String)] = [("root", "Disk (/)")]
        if let extra { titled.append((extra, "Fleet Extra (/mnt/fleet-extra)")) }
        titled.append(("tmp", "Tmpfs (/tmp)"))
        titled.append(("shm", "Shared Mem (/dev/shm)"))
        let named = Set(titled.map(\.key))
        let others = snapshot.devices.keys.filter { !named.contains($0) }.sorted()
        let rows = titled + others.map { (key: $0, title: snapshot.devices[$0]?.mount ?? $0) }
        return rows.compactMap { key, title in
            snapshot.devices[key].map { device(key: key, title: title, $0) }
        }
    }

    private static func device(key: String, title: String, _ device: VPSDevice) -> CompanionServerDevice {
        let used = fraction(device.usedFraction)
        return CompanionServerDevice(
            id: key,
            title: title,
            mount: device.mount,
            freeText: device.freeBytes >= 0 ? size(device.freeBytes) : nil,
            totalText: device.estimatedTotalBytes.map(size),
            usedPercent: used.map { $0 * 100 },
            usedText: used.map { String(format: "%.0f%% used", $0 * 100) },
            severity: used.map { CompanionSnapshotBuilder.severityName(Severity.forDisk($0)) },
            note: device.note
        )
    }

    /// The Mac names three databases.  Anything else the server sends still
    /// travels, under its own key, rather than vanishing.
    private static func databases(_ databases: [String: Int64], change: (String) -> Double?) -> [CompanionServerSizeRow] {
        let known = [("st_app_db", "Socratic Trade"), ("ct_db", "Congress Trade"), ("um_db", "Usage Monitor")]
        let knownKeys = Set(known.map(\.0))
        let others = databases.keys.filter { !knownKeys.contains($0) }.sorted().map { ($0, $0) }
        return (known + others).compactMap { key, name in
            guard let bytes = databases[key] else { return nil }
            return sizeRow(id: key, name: name, bytes: bytes, percent: change(key))
        }
    }

    private static func directories(_ directories: [VPSDirectory], change: (String) -> Double?) -> [CompanionServerSizeRow] {
        directories.prefix(directoryLimit).map { directory in
            sizeRow(id: directory.path, name: directory.path, bytes: directory.bytes, percent: change(directory.path))
        }
    }

    private static func sizeRow(id: String, name: String, bytes: Int64, percent: Double?) -> CompanionServerSizeRow {
        let percent = finite(percent)
        return CompanionServerSizeRow(
            id: id,
            name: name,
            bytesText: bytes >= 0 ? size(bytes) : nil,
            changeText: SizeGrowthFormat.delta(percent),
            changePercent: percent
        )
    }

    private static func diagnostics(_ diagnostics: VPSStorageDiagnostics) -> CompanionServerStorageDiagnostics {
        let complete = diagnostics.categories.status == "complete"
        return CompanionServerStorageDiagnostics(
            sampledAt: isoDate(diagnostics.sampledAt),
            durationSeconds: finite(diagnostics.durationSeconds),
            categoriesComplete: complete,
            categories: complete ? diagnostics.categories.items.map { category in
                CompanionServerStorageCategory(
                    id: category.id,
                    title: category.title,
                    sizeText: size(category.sizeBytes),
                    reclaimableText: size(category.engineReclaimableBytes)
                )
            } : nil,
            usesContainerd: diagnostics.daemon.usesContainerd,
            blobText: blobText(diagnostics)
        )
    }

    private static func blobText(_ diagnostics: VPSStorageDiagnostics) -> String? {
        guard diagnostics.daemon.usesContainerd == true else { return nil }
        if diagnostics.blobs.status == "complete", let bytes = diagnostics.blobs.allocatedBytes {
            return size(bytes)
        }
        return diagnostics.blobs.status == "incomplete" ? "Reading incomplete" : "Reading unavailable"
    }

    private static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func tool(_ tool: VPSToolStatus) -> CompanionServerTool {
        let reason = tool.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanionServerTool(
            id: tool.id,
            name: tool.name,
            state: tool.state.rawValue,
            stateText: toolStateText(tool.state),
            count: tool.count >= 0 ? tool.count : nil,
            reason: reason?.isEmpty == false ? reason : nil
        )
    }

    /// The same words the Mac's Tools list uses.
    private static func toolStateText(_ state: VPSToolStatus.State) -> String {
        switch state {
        case .running: return "Running"
        case .stopped: return "Not running"
        case .absent: return "Not found"
        case .unknown: return "Unknown"
        }
    }

    private static func process(_ process: VPSProcess) -> CompanionServerProcess {
        CompanionServerProcess(
            id: opaqueID(process.id),
            name: process.name,
            owner: process.owner,
            container: process.container?.isEmpty == false ? process.container : nil,
            cpuText: nonNegative(process.cpuPercent).map { String(format: "%.0f%%", $0) },
            memoryText: process.memoryBytes.flatMap { $0 >= 0 ? size($0) : nil },
            swapText: process.swapBytes.flatMap { $0 >= 0 ? size($0) : nil },
            isTamed: process.nice == nil ? nil : process.isTamed,
            protectionReason: process.protectionReason?.isEmpty == false ? process.protectionReason : nil
        )
    }

    private static func workload(_ resource: VPSCoolifyResource) -> CompanionServerWorkload {
        CompanionServerWorkload(
            id: opaqueID(resource.id),
            name: resource.name,
            type: resource.type.isEmpty ? nil : resource.type,
            status: resource.status.isEmpty ? nil : resource.status,
            isHealthy: resource.status.isEmpty ? nil : resource.isHealthy,
            cpuText: nonNegative(resource.cpuPercent).map { String(format: "%.0f%%", $0) },
            memoryText: resource.memoryBytes.flatMap { $0 >= 0 ? size($0) : nil }
        )
    }

    // MARK: - Values

    private static func size(_ bytes: Int64) -> String {
        HogFormat.memory(UInt64(max(0, bytes)))
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value = finite(value), value >= 0 else { return nil }
        return value
    }

    private static func fraction(_ value: Double?) -> Double? {
        guard let value = finite(value), (0...1).contains(value) else { return nil }
        return value
    }

    /// The first line that says anything, cut to a length that fits a row.
    private static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > errorTextLimit ? String(line.prefix(errorTextLimit)) + "…" : line
    }
}
