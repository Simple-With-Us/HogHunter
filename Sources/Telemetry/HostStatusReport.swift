import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

// The Mac status report that Muster reads.
//
// The running app writes one small file, `~/.local/state/fleet-tools/hoghunter-mac.json`, and
// Muster (the fleet's control app) decodes it with the same reader pattern it uses for the
// server and the Mac services reports.  It is read only:  nothing here listens, nothing here
// accepts a command, and the file holds no path other than a mount point, no argv, no step
// reason, no lane name, no server host and nothing from the lock's owner record.
//
// Rules the code below keeps:
//
// * A value that was not measured is left out.  It is never written as 0.
// * The folder `~/.local/state/fleet-tools` must already exist.  The writer never creates it,
//   so the file stays off a Mac that is not part of this fleet.  It must also belong to this
//   user and not be group or world writable.
// * The file is written to a temporary name and renamed over the report, with mode 0600.  A
//   report that is a symlink is refused, never written through.
// * Nothing is written in unit tests or in the UI harness unless a test injects a directory.
// * A failed write is logged and otherwise silent.  It never reaches the sampler.

// MARK: - The report

/// The report, as it is encoded.  Field names follow Muster's own `HostMetrics` and
/// `ServerProcess` decoders.
struct HostStatusReport: Codable, Equatable {
    static let schemaVersion = 1
    static let tool = "hoghunter-mac-status"

    var schemaVersion: Int = HostStatusReport.schemaVersion
    var tool: String = HostStatusReport.tool
    var generatedAt: String
    var host: String?
    var appVersion: String?
    var hostMetrics: HostMetrics?
    var processes: [Process]?
    var maintain: Maintain?
    /// One of `free`, `held`, `stale` or `unknown`.
    var housekeeperLock: String?
    var regimen: Regimen?
    var serverSnapshotAgeSeconds: Int?

    struct HostMetrics: Codable, Equatable {
        var loadAverage: [Double]?
        var cpuCount: Int?
        var uptimeSeconds: Int?
        var cpuPercent: Double?
        var memory: Memory?
        var swap: Swap?
        var disks: [Disk]?
    }

    struct Memory: Codable, Equatable {
        var totalBytes: Int?
        var availableBytes: Int?
    }

    struct Swap: Codable, Equatable {
        var totalBytes: Int?
        var freeBytes: Int?
    }

    struct Disk: Codable, Equatable {
        /// A mount point, never a folder inside a volume.
        var mount: String
        var totalBytes: Int?
        var usedBytes: Int?
        var freeBytes: Int?
    }

    struct Process: Codable, Equatable {
        var pid: Int
        /// The executable's name only.
        var name: String?
        var cpuPercent: Double?
        var memoryBytes: Int?
    }

    struct Maintain: Codable, Equatable {
        var health: String?
        var lastRunEndedAt: String?
        var lastRunOutcome: String?
        var lastRunExitCode: Int?
        var bytesFreed: Int?
    }

    struct Regimen: Codable, Equatable {
        var enabled: Bool?
        var lastRunAt: String?
        var waiting: Bool?
    }
}

// MARK: - What the app hands over

/// The raw values the app has on hand when a report is due.
///
/// They are gathered on the main actor and turned into a report on the writer's queue.  The
/// builder below is the only place that decides what leaves the app, so the "no paths, no
/// argv, no step reasons" rule has one home and one test.
struct HostStatusSource: @unchecked Sendable {
    var pulse: MachinePulse
    var hasBaseline: Bool
    var processes: [ProcessSample]
    var bootDisk: DiskSpace?
    var drives: [MountedDriveUsage]
    var maintain: MaintainStatus?
    var regimenEnabled: Bool?
    var regimenLastRunAt: Date?
    var regimenWaiting: Bool?
    /// `generated_at` of the server snapshot Hog Hunter last fetched, as text.
    var serverSnapshotGeneratedAt: String?
}

/// Values the writer reads for itself, off the main actor.
struct HostStatusLiveReadings: Sendable {
    var loadAverage: [Double]?
    var uptimeSeconds: Int?
    var lockState: String
    var host: String?
    var appVersion: String?

    static func read(lock: HousekeeperLock.ObservedState, now: Date) -> HostStatusLiveReadings {
        HostStatusLiveReadings(
            loadAverage: HostStatusBuilder.loadAverage(),
            uptimeSeconds: HostStatusBuilder.uptimeSeconds(now: now),
            lockState: lock.rawValue,
            host: HostStatusBuilder.hostName(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }
}

// MARK: - The builder

enum HostStatusBuilder {
    /// Process rows in a report.
    static let processLimit = 10

    /// The health words the maintenance engine uses.  Anything else is left out, so a free
    /// text status can never travel in the report.
    static let knownHealth: Set<String> = ["healthy", "overdue", "failed", "unloaded", "critical", "degraded"]
    /// The outcomes the engine records for a run.
    static let knownOutcomes: Set<String> = ["ok", "partial", "skipped", "failed"]

    static func build(
        source: HostStatusSource, live: HostStatusLiveReadings, now: Date
    ) -> HostStatusReport {
        var metrics = HostStatusReport.HostMetrics()
        if let load = live.loadAverage, !load.isEmpty, load.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            metrics.loadAverage = load.map(rounded)
        }
        metrics.uptimeSeconds = live.uptimeSeconds

        let pulse = source.pulse
        let sampled = pulse.sampledAt != .distantPast
        if sampled {
            if pulse.coreCount > 0 { metrics.cpuCount = pulse.coreCount }
            // CPU is a tick delta, so it needs a baseline before it is a measurement.
            if source.hasBaseline, pulse.cpuPercent.isFinite, pulse.cpuPercent >= 0 {
                metrics.cpuPercent = rounded(pulse.cpuPercent)
            }
            if pulse.totalMemoryBytes > 0, pulse.memoryUsedBytes <= pulse.totalMemoryBytes {
                metrics.memory = .init(
                    totalBytes: int(pulse.totalMemoryBytes),
                    availableBytes: int(pulse.totalMemoryBytes - pulse.memoryUsedBytes))
            }
            // A Mac with no swap file in use reports a zero total, which is "none", not a
            // measurement of free swap, so the block is left out.
            if pulse.swapTotalBytes > 0, pulse.swapUsedBytes <= pulse.swapTotalBytes {
                metrics.swap = .init(
                    totalBytes: int(pulse.swapTotalBytes),
                    freeBytes: int(pulse.swapTotalBytes - pulse.swapUsedBytes))
            }
        }

        var disks: [HostStatusReport.Disk] = []
        for drive in StorageDriveList.rows(boot: source.bootDisk, external: source.drives) {
            // Total and available are both present or both nil (see `MountedDriveUsage`).
            guard let total = drive.totalBytes, let available = drive.availableBytes else { continue }
            disks.append(.init(
                mount: drive.path,
                totalBytes: Int(clamping: total),
                usedBytes: Int(clamping: total - available),
                freeBytes: Int(clamping: available)))
        }
        if !disks.isEmpty { metrics.disks = disks }

        var report = HostStatusReport(generatedAt: iso(now))
        report.host = nonEmpty(live.host)
        report.appVersion = nonEmpty(live.appVersion)
        report.hostMetrics = metrics.isEmpty ? nil : metrics

        if source.hasBaseline {
            let top = source.processes
                .filter { $0.hasBaseline && $0.cpuPercent.isFinite }
                .sorted {
                    $0.cpuPercent != $1.cpuPercent
                        ? $0.cpuPercent > $1.cpuPercent
                        : $0.footprintBytes > $1.footprintBytes
                }
                .prefix(processLimit)
            let rows = top.map {
                HostStatusReport.Process(
                    pid: Int($0.key.pid),
                    name: nonEmpty($0.name),
                    cpuPercent: rounded($0.cpuPercent),
                    memoryBytes: int($0.footprintBytes))
            }
            if !rows.isEmpty { report.processes = rows }
        }

        report.maintain = maintain(from: source.maintain)
        report.housekeeperLock = live.lockState
        let regimen = HostStatusReport.Regimen(
            enabled: source.regimenEnabled,
            lastRunAt: source.regimenLastRunAt.map(iso),
            waiting: source.regimenWaiting)
        if regimen.enabled != nil || regimen.lastRunAt != nil || regimen.waiting != nil {
            report.regimen = regimen
        }
        if let text = source.serverSnapshotGeneratedAt, let date = parseISO(text) {
            let age = Int(now.timeIntervalSince(date))
            if age >= 0 { report.serverSnapshotAgeSeconds = age }
        }
        return report
    }

    /// Only the health word, the last run's end, outcome, exit code and bytes freed.  The
    /// steps, their reasons, the current step and target, and the scripts are never read.
    static func maintain(from status: MaintainStatus?) -> HostStatusReport.Maintain? {
        guard let status else { return nil }
        var out = HostStatusReport.Maintain()
        if knownHealth.contains(status.health) { out.health = status.health }
        if let run = status.lastRun {
            if run.endedAt.isFinite, run.endedAt > 0 {
                out.lastRunEndedAt = iso(Date(timeIntervalSince1970: run.endedAt))
            }
            if let outcome = run.outcome, knownOutcomes.contains(outcome) { out.lastRunOutcome = outcome }
            out.lastRunExitCode = run.exitCode
            out.bytesFreed = run.bytesFreed
        }
        let empty = out.health == nil && out.lastRunEndedAt == nil && out.lastRunOutcome == nil
            && out.lastRunExitCode == nil && out.bytesFreed == nil
        return empty ? nil : out
    }

    // MARK: Readings

    static func loadAverage() -> [Double]? {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { return nil }
        return load
    }

    static func uptimeSeconds(now: Date) -> Int? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        let seconds = Int(now.timeIntervalSince1970) - Int(boot.tv_sec)
        return seconds >= 0 ? seconds : nil
    }

    static func hostName() -> String? {
        let name = HousekeeperLock.currentHostName()
        return name.isEmpty ? nil : name
    }

    // MARK: Helpers

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseISO(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
    private static func int(_ value: UInt64) -> Int { Int(clamping: value) }
    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

private extension HostStatusReport.HostMetrics {
    var isEmpty: Bool {
        loadAverage == nil && cpuCount == nil && uptimeSeconds == nil && cpuPercent == nil
            && memory == nil && swap == nil && disks == nil
    }
}

// MARK: - The writer

/// Writes the report once a minute while the app runs.
final class HostStatusReporter {
    static let interval: TimeInterval = 60
    private static let fileName = "hoghunter-mac.json"
    private static let log = Logger(subsystem: "com.simplewithus.hoghunter", category: "HostStatus")

    /// `~/.local/state/fleet-tools`.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/fleet-tools", isDirectory: true)
    }

    private let directory: URL
    /// A test that hands over its own folder opts in to writing under XCTest.
    private let directoryInjected: Bool
    private let lock: () -> HousekeeperLock
    private let queue = DispatchQueue(label: "com.simplewithus.hoghunter.hoststatus", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var busy = false

    init(directory: URL? = nil, lock: @escaping () -> HousekeeperLock = { HousekeeperLock() }) {
        self.directory = directory ?? Self.defaultDirectory
        self.directoryInjected = directory != nil
        self.lock = lock
    }

    var reportURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// Start the timer.  `provider` runs on the main actor.
    func start(provider: @escaping @MainActor () async -> HostStatusSource?) {
        queue.async { [weak self] in
            guard let self, self.timer == nil, self.mayWrite else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: Self.interval, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.fire(provider: provider) }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private var mayWrite: Bool { directoryInjected || ApplicationRunMode.current.allowsLiveProbes }

    private func fire(provider: @escaping @MainActor () async -> HostStatusSource?) {
        guard !busy else { return }
        busy = true
        Task { @MainActor [weak self] in
            let source = await provider()
            self?.queue.async {
                defer { self?.busy = false }
                guard let self, let source else { return }
                self.write(source: source, now: Date())
            }
        }
    }

    /// Build and write one report.  Returns whether a file was written.  Runs on the writer's
    /// queue, or on the caller's thread in a test.
    @discardableResult
    func write(source: HostStatusSource, now: Date) -> Bool {
        guard mayWrite else { return false }
        let live = HostStatusLiveReadings.read(lock: lock().observedState(), now: now)
        let report = HostStatusBuilder.build(source: source, live: live, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else {
            Self.log.error("Could not encode the host status report")
            return false
        }
        return Self.atomicWrite(data, to: reportURL)
    }

    /// Write `data` to `url` through a temporary file in the same folder.
    ///
    /// The folder must already exist.  An existing report that is a symlink is refused.
    static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().path
        var info = stat()
        guard stat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            // Not part of this fleet's Mac set up: nothing to do, and nothing to log.
            return false
        }
        // A folder someone else owns or can write to could block the temporary name or swap
        // the report, whatever the file's own mode says.
        guard info.st_uid == getuid(), (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            log.error("The host status folder is not private to this user; refusing to write")
            return false
        }
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            log.error("The host status report is a symlink; refusing to write")
            return false
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp").path
        unlink(temp)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            log.error("Could not create the temporary host status file (errno \(errno))")
            return false
        }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += n
                }
                return true
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if ok { ok = rename(temp, url.path) == 0 }
        if !ok {
            log.error("Could not write the host status report (errno \(errno))")
            unlink(temp)
        }
        return ok
    }
}

// MARK: - Store glue

extension HogStore {
    /// Gathers the values a report is built from.  Runs on the main actor, reads only, and
    /// changes nothing in the store or the regimen.
    func hostStatusSource() async -> HostStatusSource {
        // The drive list stops refreshing while the panel is closed, so a report has to probe
        // now and then or its free space goes stale.  Every fifth report, about five minutes,
        // keeps those numbers honest without walking the volumes every minute.
        hostStatusReportsSinceProbe += 1
        if MountedDriveStore.shared.rows.isEmpty || hostStatusReportsSinceProbe >= 5 {
            hostStatusReportsSinceProbe = 0
            await MountedDriveStore.shared.refresh()
        }
        let runner = CleanRegimenRunner.shared
        return HostStatusSource(
            pulse: pulse,
            hasBaseline: hasBaseline,
            processes: lastProcesses,
            bootDisk: diskSpace,
            drives: MountedDriveStore.shared.rows,
            maintain: maintain.status,
            regimenEnabled: CleanRegimen.load().isEnabled,
            regimenLastRunAt: UserDefaults.standard.object(
                forKey: "hoghunter.cleaner.regimen.lastRunAt") as? Date,
            regimenWaiting: runner.waitingReason != nil,
            serverSnapshotGeneratedAt: maintain.vpsStore.snapshot?.generatedAt)
    }
}
