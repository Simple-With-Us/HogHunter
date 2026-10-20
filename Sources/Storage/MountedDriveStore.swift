#if os(macOS)
import Foundation
import Combine
import DiskArbitration
import Darwin

struct MountedDriveUsage: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let totalBytes: Int64?
    let availableBytes: Int64?

    init(name: String, path: String, totalBytes: Int64?, availableBytes: Int64?) {
        self.name = name
        self.path = path
        if let totalBytes, totalBytes > 0, let availableBytes, availableBytes >= 0 {
            self.totalBytes = totalBytes
            self.availableBytes = min(availableBytes, totalBytes)
        } else {
            self.totalBytes = nil
            self.availableBytes = nil
        }
    }

    var usedPercent: Double? {
        guard let totalBytes, let availableBytes else { return nil }
        return (1 - Double(availableBytes) / Double(totalBytes)) * 100
    }
    enum Severity: Sendable { case normal, warning, critical, unavailable }
    var severity: Severity {
        guard let usedPercent else { return .unavailable }
        if usedPercent >= 95 { return .critical }
        if usedPercent >= 85 { return .warning }
        return .normal
    }
}

struct MountedDriveCandidate: Sendable {
    let name: String
    let path: String
    let isLocal: Bool
    let isHidden: Bool
    let isExternalPhysical: Bool
    let totalBytes: Int64?
    let availableBytes: Int64?

    var usage: MountedDriveUsage? {
        guard isLocal, !isHidden, isExternalPhysical,
              MountedDriveMountRecord.visibleVolumeName(path: path) != nil else { return nil }
        return MountedDriveUsage(name: name, path: path, totalBytes: totalBytes, availableBytes: availableBytes)
    }
}

// A value snapshot from the kernel mount table.  No mounted path is opened for discovery.
struct MountedDriveMountRecord: Sendable {
    let path: String
    let source: String
    let flags: UInt32
    let blockSize: UInt64
    let blocks: UInt64
    let availableBlocks: UInt64

    var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
    var isHidden: Bool { flags & UInt32(MNT_DONTBROWSE) != 0 }
    var volumeName: String? { Self.visibleVolumeName(path: path) }
    var bsdName: String? {
        guard source.hasPrefix("/dev/disk") else { return nil }
        let name = String(source.dropFirst("/dev/".count))
        let suffix = name.dropFirst("disk".count)
        guard let first = suffix.utf8.first, (48...57).contains(first),
              suffix.utf8.allSatisfy({ (48...57).contains($0) || $0 == 115 }) else { return nil }
        return name
    }

    var capacity: (total: Int64?, available: Int64?) {
        guard blockSize > 0, blocks > 0 else { return (nil, nil) }
        let total = blocks.multipliedReportingOverflow(by: blockSize)
        let available = availableBlocks.multipliedReportingOverflow(by: blockSize)
        guard !total.overflow, !available.overflow,
              total.partialValue <= UInt64(Int64.max),
              available.partialValue <= UInt64(Int64.max) else { return (nil, nil) }
        return (Int64(total.partialValue), Int64(available.partialValue))
    }

    static func visibleVolumeName(path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0].isEmpty, components[1] == "Volumes",
              !components[2].isEmpty, !components[2].hasPrefix(".") else { return nil }
        return String(components[2])
    }
}

@MainActor
final class MountedDriveStore: ObservableObject {
    typealias Probe = @Sendable () -> [MountedDriveCandidate]
    @Published private(set) var rows: [MountedDriveUsage] = []
    @Published private(set) var isRefreshing = false
    private let probe: Probe
    private let now: () -> Date
    private var lastAttempt: Date?

    init(now: @escaping () -> Date = Date.init, probe: @escaping Probe = { MountedDriveStore.discover() }) {
        self.now = now
        self.probe = probe
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing, force || lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        isRefreshing = true
        lastAttempt = now()
        defer { isRefreshing = false }
        let probe = self.probe
        let candidates = await Task.detached(priority: .utility) { probe() }.value
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        rows = candidates.compactMap(\.usage).filter { seen.insert($0.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func discover() -> [MountedDriveCandidate] {
        guard ApplicationRunMode.current.allowsLiveProbes,
              let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        return cachedMountRecords().compactMap { mount -> MountedDriveCandidate? in
            guard mount.isLocal, !mount.isHidden, let fallbackName = mount.volumeName,
                  let bsdName = mount.bsdName,
                  let disk = bsdName.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
                  let whole = DADiskCopyWholeDisk(disk),
                  let description = DADiskCopyDescription(whole) as? [String: Any] else { return nil }
            let internalDevice = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
            let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let physicalProtocols: Set<String> = ["USB", "FireWire", "Thunderbolt", "PCI-Express", "SATA", "SAS", "ATA", "Secure Digital"]
            guard internalDevice == false, deviceProtocol.map(physicalProtocols.contains) == true else { return nil }
            let volumeDescription = DADiskCopyDescription(disk) as? [String: Any]
            let volumeName = volumeDescription?[kDADiskDescriptionVolumeNameKey as String] as? String
            let name = volumeName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
            let capacity = mount.capacity
            return MountedDriveCandidate(name: name, path: mount.path,
                isLocal: mount.isLocal, isHidden: mount.isHidden, isExternalPhysical: true,
                totalBytes: capacity.total, availableBytes: capacity.available)
        }
    }

    nonisolated private static func cachedMountRecords() -> [MountedDriveMountRecord] {
        // MNT_NOWAIT uses cached filesystem statistics rather than refreshing each mounted path.
        // Cap memory and retries if mounts change between sizing and copying the table.
        let maximumMounts = 4096
        let initialCount = getfsstat(nil, 0, MNT_NOWAIT)
        guard initialCount > 0, initialCount < maximumMounts else { return [] }
        var capacity = min(Int(initialCount) + 8, maximumMounts)
        for _ in 0..<3 {
            var table = Array<statfs>(repeating: statfs(), count: capacity)
            let byteCount = capacity * MemoryLayout<statfs>.stride
            guard byteCount <= Int(Int32.max) else { return [] }
            let copied = table.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32(byteCount), MNT_NOWAIT)
            }
            guard copied >= 0, Int(copied) <= capacity else { return [] }
            if Int(copied) < capacity {
                return table.prefix(Int(copied)).compactMap { stats in
                    var stats = stats
                    guard let path = mountString(&stats.f_mntonname),
                          let source = mountString(&stats.f_mntfromname) else { return nil }
                    return MountedDriveMountRecord(path: path, source: source, flags: stats.f_flags,
                        blockSize: UInt64(stats.f_bsize), blocks: stats.f_blocks, availableBlocks: stats.f_bavail)
                }
            }
            guard capacity < maximumMounts else { return [] }
            capacity = min(capacity * 2, maximumMounts)
        }
        return []
    }

    nonisolated private static func mountString<T>(_ value: inout T) -> String? {
        withUnsafeBytes(of: &value) { bytes in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[..<end], encoding: .utf8)
        }
    }
}
#endif
