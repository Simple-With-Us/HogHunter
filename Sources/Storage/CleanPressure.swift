import Foundation

/// Resource pressure, in the shape the owner ruling requires.
///
/// The companion Python engine got this wrong for months: it dropped to a
/// binary "do less" gate on `load1 > 40`, and on a machine whose normal load
/// is 15-30 that gate was true almost always, so cleaning almost never ran.
/// The same class of bug as a safety guard whose threshold sits inside the
/// normal operating band.
///
/// The two lessons that generalize, both measured on this machine:
///
/// 1. **Pressure shapes work, it does not shrink it.**  Below, pressure only
///    chooses `chunkSize` and `pauseSeconds`.
/// 2. **`load1` alone cannot tell busy from thrashing.**  Tasks blocked in
///    uninterruptible page-in count as running, so load is a lagging
///    indicator.  A machine at load 25.68 with 27% CPU idle and `kernel_task`
///    absent from the top-CPU sample is doing real work, not thrashing.
struct CleanPressure: Equatable, Sendable {

    /// GiB free on the Data volume.
    var diskFreeGB: Double
    var swapUsedPercent: Double
    var load1: Double

    /// CPU idle percentage.  `nil` when it could not be read.  An unknown
    /// reading is deliberately *not* treated as zero, because zero would
    /// read as thrashing and shrink the work on the strength of a metric we
    /// never actually got.
    var cpuIdlePercent: Double?

    /// `kernel_task` CPU percentage, or `nil` when not cheaply readable.  It
    /// is reported for diagnostics and is deliberately NOT an input to
    /// `isThrashing` -- see `currentKernelTaskPercent()`.
    var kernelTaskPercent: Double?

    /// Below this idle percentage the host is considered to be paging rather
    /// than working.  Chosen against observed normal operation, not guessed:
    /// this Mac idles between roughly 7% and 27% under real fleet load.
    /// Thrash-detection floor for CPU idle %.  Infisical-overridable
    /// (`hoghunter.reclaim.cpuIdleFloorPercent`); the built-in 12.0 stands
    /// when Infisical is not configured, which keeps the existing tests
    /// deterministic.
    static var idleFloorPercent: Double {
        InfisicalStore.shared.double(for: InfisicalKey.reclaimCpuIdleFloorPercent) ?? 12.0
    }

    // MARK: - Derived

    /// True only when the host is genuinely paging.  High load with high
    /// idle is real work and must not be treated as a reason to stand down.
    var isThrashing: Bool {
        guard let idle = cpuIdlePercent else { return false }
        return idle < Self.idleFloorPercent
    }

    /// Pressure words for the UI and for run history.
    var label: String {
        if isThrashing { return "Throttling" }
        if swapUsedPercent >= 90 || load1 > 40 { return "Elevated (Chunked)" }
        return "Calm"
    }

    /// Free-space band, matching the engine's `DiskSpace` bands.  The
    /// thresholds are Infisical-overridable (`hoghunter.reclaim.*FreeGb`);
    /// the built-ins stand when Infisical is not configured.
    var diskBand: String {
        let cache = InfisicalStore.shared
        let critical = cache.double(for: InfisicalKey.reclaimCriticalFreeGb) ?? 25
        let acute = cache.double(for: InfisicalKey.reclaimAcuteFreeGb) ?? 40
        let healthy = cache.double(for: InfisicalKey.reclaimHealthyFreeGb) ?? 80
        if diskFreeGB < critical { return "critical" }
        if diskFreeGB < acute { return "acute" }
        if diskFreeGB < healthy { return "ok" }
        return "healthy"
    }

    /// The honest signal for opening the expensive tier: real space pressure.
    /// Load is not part of this decision.
    var hasSpacePressure: Bool {
        diskBand == "critical" || diskBand == "acute"
    }

    /// How many candidates to apply per chunk.  Pressure makes the burst
    /// smaller, never zero -- a chunk size of 0 would be the old bug wearing
    /// a new hat.  The pressure thresholds are Infisical-overridable; the
    /// chunk sizes come from the regimen's Infisical-overridable effective
    /// values.
    func chunkSize(regimen: CleanRegimen) -> Int {
        if isThrashing { return 1 }
        let cache = InfisicalStore.shared
        let swapPct = cache.double(for: InfisicalKey.reclaimSwapUsedPct) ?? 90
        let load1Threshold = cache.double(for: InfisicalKey.reclaimLoad1Threshold) ?? 40
        if swapUsedPercent >= swapPct || load1 > load1Threshold {
            return max(1, regimen.effectivePressuredTargetsPerChunk)
        }
        return max(1, regimen.effectiveTargetsPerChunk)
    }

    func pauseSeconds(regimen: CleanRegimen) -> Double {
        if isThrashing { return regimen.effectivePressuredChunkPauseSeconds * 2 }
        let cache = InfisicalStore.shared
        let swapPct = cache.double(for: InfisicalKey.reclaimSwapUsedPct) ?? 90
        let load1Threshold = cache.double(for: InfisicalKey.reclaimLoad1Threshold) ?? 40
        if swapUsedPercent >= swapPct || load1 > load1Threshold {
            return regimen.effectivePressuredChunkPauseSeconds
        }
        return regimen.effectiveChunkPauseSeconds
    }

    /// The expensive tier is metadata-and-bulk-delete work: simulator
    /// runtimes and device support, the biggest wins on this machine and the
    /// biggest I/O bursts.  It opens on disk pressure alone.
    func allowsExpensiveTier(regimen: CleanRegimen) -> Bool {
        hasSpacePressure && diskFreeGB < regimen.effectiveExpensiveTierFreeGB
    }

    // MARK: - Reading

    /// Live pressure.  Kept deliberately cheap -- this runs on a timer and
    /// must never become a reason the machine is busy.
    static func current() -> CleanPressure {
        let freeBytes = DiskSpace.current()?.freeBytes ?? 0
        return CleanPressure(
            diskFreeGB: Double(freeBytes) / 1_073_741_824,
            swapUsedPercent: swapUsedPercent(),
            load1: currentLoad(),
            cpuIdlePercent: currentCPUIdlePercent(),
            kernelTaskPercent: currentKernelTaskPercent()
        )
    }

    /// Swap is already sampled by `SystemStats`, but the regimen runs on its
    /// own cadence and needs the number without a tick, so it is read
    /// directly.  Returns 0 when unavailable rather than a fabricated 100.
    static func swapUsedPercent() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let name = "vm.swapusage"
        guard sysctlbyname(name, &usage, &size, nil, 0) == 0 else { return 0 }
        let total = Double(usage.xsu_total)
        guard total > 0 else { return 0 }
        return 100.0 * Double(usage.xsu_used) / total
    }

    static func currentLoad() -> Double {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { return 0 }
        return load[0]
    }

    /// Idle percentage via `host_statistics`.  Same source the sampler uses
    /// for CPU busy, read standalone so a regimen can run between ticks.
    /// `nil` on failure, never 0.
    static func currentCPUIdlePercent() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let total = Double(ticks.0) + Double(ticks.1) + Double(ticks.2) + Double(ticks.3)
        guard total > 0 else { return nil }
        return 100.0 * Double(ticks.3) / total
    }

    /// `kernel_task` CPU share, for diagnostics only.
    ///
    /// It is **not** an input to `isThrashing` -- that reads idle alone, in
    /// both this file and the Python engine.  kernel_task runs in the kernel
    /// task port, whose per-thread CPU needs `thread_info` on every kernel
    /// thread, which is not worth the cost on a timer.  So the honest answer
    /// is "not cheaply readable" and the field is informational.
    static func currentKernelTaskPercent() -> Double? { nil }
}
