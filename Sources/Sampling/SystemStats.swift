import Darwin
import Foundation
import IOKit.ps

/// Machine-wide CPU, memory, swap, pressure, battery, and thermal state.
///
/// The mach host port is acquired once and released in `deinit`; asking for it
/// on every tick leaks a send right.  Every reading is a pure function of the
/// kernel counters plus the caller's previous `Raw`, so the class holds no
/// hidden state.
final class SystemStats {
    /// The counters a reading needs from the previous pass.
    struct Raw {
        var idleTicks: UInt64
        var totalTicks: UInt64
        var swapins: UInt64
        var swapouts: UInt64
        var at: TimeInterval
    }

    struct Reading {
        /// 0-100 across all cores.  Nil on the first pass and whenever the
        /// kernel's 32-bit tick counters rolled over.
        var cpuPercent: Double?
        var coreCount: Int
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
        var batteryPercent: Int?
        var isCharging: Bool?
        var powerSource: String?
        var raw: Raw
    }

    private let host: host_t
    private let pageSize: UInt64
    private let totalMemory: UInt64

    init() {
        host = mach_host_self()
        pageSize = UInt64(vm_kernel_page_size)
        totalMemory = ProcessInfo.processInfo.physicalMemory
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func read(previous: Raw?) -> Reading {
        let now = CpuMath.now()
        let load = cpuLoad()
        let vm = vmStatistics()
        let swap = swapUsage()
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let battery = batteryStatus()

        let raw = Raw(
            idleTicks: load.idle,
            totalTicks: load.total,
            swapins: vm.swapins,
            swapouts: vm.swapouts,
            at: now
        )

        var cpuPercent: Double?
        var swapIn = 0.0
        var swapOut = 0.0
        if let previous {
            cpuPercent = CpuMath.machinePercent(
                idle: load.idle,
                total: load.total,
                previousIdle: previous.idleTicks,
                previousTotal: previous.totalTicks
            )
            let elapsed = now - previous.at
            swapIn = CpuMath.rate(current: vm.swapins, previous: previous.swapins, elapsed: elapsed) * Double(pageSize)
            swapOut = CpuMath.rate(current: vm.swapouts, previous: previous.swapouts, elapsed: elapsed) * Double(pageSize)
        }

        return Reading(
            cpuPercent: cpuPercent,
            coreCount: cores,
            memoryUsedBytes: MemoryMath.used(
                internal: vm.internalPages,
                purgeable: vm.purgeablePages,
                wired: vm.wiredPages,
                compressor: vm.compressorPages,
                pageSize: pageSize
            ),
            appMemoryBytes: MemoryMath.appMemory(
                internal: vm.internalPages,
                purgeable: vm.purgeablePages,
                pageSize: pageSize
            ),
            wiredBytes: vm.wiredPages &* pageSize,
            compressedBytes: vm.compressorPages &* pageSize,
            cachedFilesBytes: MemoryMath.cachedFiles(
                external: vm.externalPages,
                purgeable: vm.purgeablePages,
                pageSize: pageSize
            ),
            totalMemoryBytes: totalMemory,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            swapInBytesPerSec: swapIn,
            swapOutBytesPerSec: swapOut,
            pressure: memoryPressure(),
            thermalState: ProcessInfo.processInfo.thermalState,
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            powerSource: battery.source,
            raw: raw
        )
    }

    // MARK: - Battery status

    private func batteryStatus() -> (percent: Int?, isCharging: Bool?, source: String?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return (nil, nil, nil)
        }
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            let cap = desc[kIOPSCurrentCapacityKey as String] as? Int
            let charging = desc[kIOPSIsChargingKey as String] as? Bool
            return (cap, charging, state)
        }
        return (nil, nil, nil)
    }

    // MARK: - Kernel reads

    private func cpuLoad() -> (idle: UInt64, total: UInt64) {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics(host, HOST_CPU_LOAD_INFO, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (idle, user &+ system &+ idle &+ nice)
    }

    private struct VMCounters {
        var internalPages: UInt64 = 0
        var externalPages: UInt64 = 0
        var purgeablePages: UInt64 = 0
        var wiredPages: UInt64 = 0
        var compressorPages: UInt64 = 0
        var swapins: UInt64 = 0
        var swapouts: UInt64 = 0
    }

    private func vmStatistics() -> VMCounters {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics64(host, HOST_VM_INFO64, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return VMCounters() }
        return VMCounters(
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            swapins: UInt64(stats.swapins),
            swapouts: UInt64(stats.swapouts)
        )
    }

    private func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressure(rawValue: Int(level)) ?? .unknown
    }
}
