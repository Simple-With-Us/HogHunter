import Darwin
import Foundation

/// Reads every process this user is allowed to read, plus the machine pulse.
///
/// No AppKit, no LaunchServices, no icons: this runs on a utility queue and
/// must never touch the main actor.  Display names and icons are the
/// `MetadataResolver`'s job, and only for rows somebody is looking at.
///
/// Permission facts this design rests on, measured on macOS 27 as uid 501:
/// `proc_pid_rusage`, `PROC_PIDTASKINFO` and `PROC_PIDTBSDINFO` all fail with
/// EPERM together for a process this user does not own — about 28% of pids —
/// and pid 0 (`kernel_task`) is one of them, so there is no kernel row to show.
///
/// `@unchecked Sendable` is honest here: one serial queue owns the instance and
/// nothing else ever calls into it.
final class Sampler: @unchecked Sendable {
    private struct Previous {
        var ticks: UInt64
        var at: TimeInterval
        var diskRead: UInt64
        var diskWrite: UInt64
        var wakeups: UInt64
    }

    private var previous: [ProcessKey: Previous] = [:]
    private var systemRaw: SystemStats.Raw?
    private var lastMachineCpu: Double = 0
    private var passes = 0
    private let stats = SystemStats()
    private let tickToNanos = CpuMath.tickToNanos
    private let selfPid = getpid()

    /// One full pass over the process table plus the machine counters.
    func snapshot() -> Snapshot {
        let now = CpuMath.now()
        let reading = stats.read(previous: systemRaw)
        systemRaw = reading.raw
        if let cpu = reading.cpuPercent { lastMachineCpu = cpu }
        let coreCount = reading.coreCount

        var processes: [ProcessSample] = []
        var unreadable = 0
        var visibleCpu = 0.0
        var next: [ProcessKey: Previous] = [:]
        let sleepBlockers = PowerAssertions.sleepBlockerPids()

        for pid in listPids() {
            // Hog Hunter is itself readable, so its own row would otherwise
            // appear in the panel with the lock icon and a "this app" Quit
            // reason.  Filter at the source so the row never reaches the
            // grouping or alerting paths.
            if pid == selfPid { continue }
            let rusage = processRusage(pid)
            let task = taskInfo(pid)
            let bsd = bsdInfo(pid)

            guard rusage != nil || task != nil else {
                // A pid that vanished between the listing and the read is not
                // a permission problem, so it is not counted as unreadable.
                // `bsd` succeeding already proves the process still exists --
                // both metric reads failing on a live process is exactly the
                // EPERM case this count exists for -- so only fall back to
                // the separate existence check when `bsd` did not.
                if bsd != nil || pidExists(pid) { unreadable += 1 }
                continue
            }

            let startTime = rusage?.ri_proc_start_abstime ?? 0
            let key = ProcessKey(pid: pid, startTime: startTime)

            let ticks: UInt64
            if let rusage {
                ticks = rusage.ri_user_time &+ rusage.ri_system_time
            } else if let task {
                ticks = task.pti_total_user &+ task.pti_total_system
            } else {
                ticks = 0
            }

            var cpuPercent = 0.0
            var hasBaseline = false
            var diskRead = 0.0
            var diskWrite = 0.0
            var wakeups = 0.0
            if let prior = previous[key] {
                let elapsed = now - prior.at
                if let percent = CpuMath.percent(
                    currentTicks: ticks,
                    previousTicks: prior.ticks,
                    elapsed: elapsed,
                    tickToNanos: tickToNanos,
                    coreCount: coreCount
                ) {
                    cpuPercent = percent
                    hasBaseline = true
                }
                if let rusage {
                    diskRead = CpuMath.rate(current: rusage.ri_diskio_bytesread, previous: prior.diskRead, elapsed: elapsed)
                    diskWrite = CpuMath.rate(current: rusage.ri_diskio_byteswritten, previous: prior.diskWrite, elapsed: elapsed)
                    wakeups = CpuMath.rate(current: rusage.ri_pkg_idle_wkups, previous: prior.wakeups, elapsed: elapsed)
                }
            }

            next[key] = Previous(
                ticks: ticks,
                at: now,
                diskRead: rusage?.ri_diskio_bytesread ?? 0,
                diskWrite: rusage?.ri_diskio_byteswritten ?? 0,
                wakeups: rusage?.ri_pkg_idle_wkups ?? 0
            )

            let path = processPath(pid)
            let resident = task.map { UInt64($0.pti_resident_size) } ?? 0
            let footprint = rusage.map { $0.ri_phys_footprint } ?? resident
            visibleCpu += cpuPercent

            processes.append(
                ProcessSample(
                    key: key,
                    ppid: bsd.map { pid_t(bitPattern: $0.pbi_ppid) } ?? -1,
                    uid: bsd.map { uid_t($0.pbi_uid) } ?? uid_t.max,
                    name: displayName(pid: pid, path: path),
                    path: path,
                    cpuPercent: cpuPercent,
                    hasBaseline: hasBaseline,
                    footprintBytes: footprint > 0 ? footprint : resident,
                    residentBytes: resident,
                    threadCount: task.map { Int($0.pti_threadnum) } ?? 0,
                    diskReadBytesPerSec: diskRead,
                    diskWriteBytesPerSec: diskWrite,
                    idleWakeupsPerSec: wakeups,
                    isSleepBlocker: sleepBlockers.contains(pid),
                    isTamed: ProcessControl.isTamed(pid: pid)
                )
            )
        }

        // Pruned by key, so a reused pid never inherits the old process's
        // counters — the old key simply stops being seen.
        previous = next

        let hasBaseline = passes > 0
        passes += 1

        let pulse = MachinePulse(
            cpuPercent: lastMachineCpu,
            coreCount: coreCount,
            visibleCpuPercent: min(100, visibleCpu / Double(coreCount)),
            readableProcessCount: processes.count,
            unreadableProcessCount: unreadable,
            memoryUsedBytes: reading.memoryUsedBytes,
            appMemoryBytes: reading.appMemoryBytes,
            wiredBytes: reading.wiredBytes,
            compressedBytes: reading.compressedBytes,
            cachedFilesBytes: reading.cachedFilesBytes,
            totalMemoryBytes: reading.totalMemoryBytes,
            swapUsedBytes: reading.swapUsedBytes,
            swapTotalBytes: reading.swapTotalBytes,
            swapInBytesPerSec: reading.swapInBytesPerSec,
            swapOutBytesPerSec: reading.swapOutBytesPerSec,
            pressure: reading.pressure,
            thermalState: reading.thermalState,
            batteryPercent: reading.batteryPercent,
            isCharging: reading.isCharging,
            powerSource: reading.powerSource,
            sampledAt: Date()
        )

        return Snapshot(pulse: pulse, processes: processes, hasBaseline: hasBaseline)
    }

    // MARK: - libproc

    private func listPids() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var capacity = Int(needed) / MemoryLayout<pid_t>.stride
        capacity += capacity / 4 + 16                      // 25% slack for growth
        let attempts = 3
        for attempt in 1...attempts {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listpids(
                UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.stride)
            )
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            if count == capacity, attempt < attempts {
                // The buffer filled exactly, so the table may have grown.
                capacity += capacity / 4 + 16
                continue
            }
            return pids.prefix(count).filter { $0 >= 0 }
        }
        return []
    }

    private func processRusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
            }
        }
        return result == 0 ? info : nil
    }

    private func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info : nil
    }

    private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private func pidExists(_ pid: pid_t) -> Bool {
        if pid == 0 { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// `proc_name` truncates at 31 characters, which turns distinct helpers
    /// into the same string.  When it is at the limit the executable's last
    /// path component is used instead.  Claude Code's CLI is a special case
    /// of that: its binary file is itself named after the version being run
    /// (see `ClaudeProcess`), so both `proc_name` and the path fallback can
    /// surface a raw version string like "2.1.266" instead of a readable name.
    private func displayName(pid: pid_t, path: String) -> String {
        if ClaudeProcess.isCLI(path: path) { return ClaudeProcess.displayName }
        var buffer = [CChar](repeating: 0, count: 64)
        var name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let component = path.isEmpty ? "" : (path as NSString).lastPathComponent
        if name.isEmpty || (name.count >= 31 && component.count > name.count) {
            name = component
        }
        return name.isEmpty ? "pid \(pid)" : name
    }
}
