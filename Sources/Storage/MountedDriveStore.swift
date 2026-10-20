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
        let components = URL(fileURLWithPath: path).standardized.pathComponents
        guard isLocal, !isHidden, isExternalPhysical, components.count == 3,
              components[1] == "Volumes", !components[2].hasPrefix(".") else { return nil }
        return MountedDriveUsage(name: name, path: path, totalBytes: totalBytes, availableBytes: availableBytes)
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
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTest.XCTestCase") == nil,
              let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .isHiddenKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> MountedDriveCandidate? in
            let path = url.path
            guard path.hasPrefix("/Volumes/"), let values = try? url.resourceValues(forKeys: keys) else { return nil }
            var physical = false
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
               let whole = DADiskCopyWholeDisk(disk),
               let description = DADiskCopyDescription(whole) as? [String: Any] {
                let internalDevice = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
                let physicalProtocols: Set<String> = ["USB", "FireWire", "Thunderbolt", "PCI-Express", "SATA", "SAS", "ATA", "Secure Digital"]
                physical = internalDevice == false && deviceProtocol.map(physicalProtocols.contains) == true
            }
            var stats = statfs()
            var total: Int64?
            var available: Int64?
            if statfs(path, &stats) == 0 {
                let blockSize = UInt64(stats.f_bsize)
                let totalProduct = stats.f_blocks.multipliedReportingOverflow(by: blockSize)
                let freeProduct = stats.f_bavail.multipliedReportingOverflow(by: blockSize)
                if !totalProduct.overflow, !freeProduct.overflow,
                   totalProduct.partialValue <= UInt64(Int64.max), freeProduct.partialValue <= UInt64(Int64.max) {
                    total = Int64(totalProduct.partialValue)
                    available = Int64(freeProduct.partialValue)
                }
            }
            return MountedDriveCandidate(name: values.volumeName ?? url.lastPathComponent, path: path,
                isLocal: values.volumeIsLocal == true, isHidden: values.isHidden == true,
                isExternalPhysical: physical, totalBytes: total, availableBytes: available)
        }
    }
}
#endif
