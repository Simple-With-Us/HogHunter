import XCTest
import Darwin
@testable import HogHunter

final class MountedDriveTests: XCTestCase {
    func testStorageBrowserIncludesInternalDiskWithoutExternalDrives() {
        let rows = StorageDriveList.rows(boot: DiskSpace(freeBytes: 20, totalBytes: 100), external: [])
        XCTAssertEqual(rows.map(\.path), ["/"])
        XCTAssertEqual(rows.first?.name, "Internal")
        XCTAssertEqual(rows.first?.usedPercent, 80)
    }

    func testStorageBrowserKeepsUnavailableInternalDiskVisible() {
        let rows = StorageDriveList.rows(boot: nil, external: [])
        XCTAssertEqual(rows.map(\.path), ["/"])
        XCTAssertEqual(rows.first?.severity, .unavailable)
        XCTAssertNil(rows.first?.availableBytes)
    }

    func testStorageBrowserDoesNotCountAPFSBootAliasesOrDuplicateMountsTwice() {
        let backup = MountedDriveUsage(name: "Backup", path: "/Volumes/Backup", totalBytes: 100, availableBytes: 20)
        let root = MountedDriveUsage(name: "Root", path: "/", totalBytes: 100, availableBytes: 20)
        let data = MountedDriveUsage(name: "Data", path: "/System/Volumes/Data", totalBytes: 100, availableBytes: 20)
        let rows = StorageDriveList.rows(boot: DiskSpace(freeBytes: 10, totalBytes: 100),
                                         external: [root, backup, data, backup])
        XCTAssertEqual(rows.map(\.path), ["/", "/Volumes/Backup"])
        XCTAssertEqual(rows.first?.availableBytes, 10)
    }

    func testCapacityNormalizationDoesNotInventMissingSpace() {
        let missing = MountedDriveUsage(name: "Backup", path: "/Volumes/Backup", totalBytes: 100, availableBytes: nil)
        XCTAssertNil(missing.usedPercent)
        XCTAssertEqual(missing.severity, .unavailable)
        XCTAssertNil(MountedDriveUsage(name: "Invalid", path: "/Volumes/Invalid", totalBytes: 0, availableBytes: 0).usedPercent)
        let clamped = MountedDriveUsage(name: "Empty", path: "/Volumes/Empty", totalBytes: 100, availableBytes: 120)
        XCTAssertEqual(clamped.availableBytes, 100)
        XCTAssertEqual(clamped.usedPercent, 0)
        let full = MountedDriveUsage(name: "Backup", path: "/Volumes/Backup", totalBytes: 1000, availableBytes: 4)
        XCTAssertEqual(full.usedPercent!, 99.6, accuracy: 0.001)
        XCTAssertEqual(full.severity, .critical)
    }

    func testOnlyVisiblePhysicalExternalMountsAreIncluded() {
        func candidate(_ path: String, external: Bool = true, hidden: Bool = false, local: Bool = true) -> MountedDriveCandidate {
            MountedDriveCandidate(name: "Drive", path: path, isLocal: local, isHidden: hidden,
                                  isExternalPhysical: external, totalBytes: 100, availableBytes: 20)
        }
        XCTAssertNotNil(candidate("/Volumes/Time Machine").usage)
        XCTAssertNil(candidate("/").usage)
        XCTAssertNil(candidate("/System/Volumes/Data").usage)
        XCTAssertNil(candidate("/Volumes/.timemachine/snapshot").usage)
        XCTAssertNil(candidate("/Volumes/Disk Image", external: false).usage)
        XCTAssertNil(candidate("/Volumes/Hidden", hidden: true).usage)
        XCTAssertNil(candidate("/Volumes/Network", local: false).usage)
    }

    func testMountRecordUsesCachedFlagsAndBSDSource() {
        let visible = mountRecord()
        XCTAssertTrue(visible.isLocal)
        XCTAssertFalse(visible.isHidden)
        XCTAssertEqual(visible.volumeName, "Backup")
        XCTAssertEqual(visible.bsdName, "disk4s2")
        XCTAssertTrue(mountRecord(flags: UInt32(MNT_LOCAL | MNT_DONTBROWSE)).isHidden)
        XCTAssertFalse(mountRecord(flags: 0).isLocal)
        for source in ["server:/backup", "/dev/rdisk4", "/dev/disk", "/dev/disk4/backup", "/dev/disk4s2 extra"] {
            XCTAssertNil(mountRecord(source: source).bsdName, source)
        }
        for path in ["/", "/System/Volumes/Data", "/Volumes/.hidden", "/Volumes/Backup/child", "/Volumes/", "/Volumes/../Backup"] {
            XCTAssertNil(mountRecord(path: path).volumeName, path)
        }
    }

    func testCachedCapacityRejectsOverflowAndUnavailableStatistics() {
        let valid = mountRecord(blockSize: 4096, blocks: 100, availableBlocks: 20).capacity
        XCTAssertEqual(valid.total, 409600)
        XCTAssertEqual(valid.available, 81920)
        let full = mountRecord(availableBlocks: 0).capacity
        XCTAssertEqual(full.available, 0)
        for record in [
            mountRecord(blockSize: 0),
            mountRecord(blocks: 0),
            mountRecord(blockSize: 2, blocks: UInt64.max),
            mountRecord(blockSize: 2, availableBlocks: UInt64.max),
            mountRecord(blockSize: 1, blocks: UInt64(Int64.max) + 1),
            mountRecord(blockSize: 1, availableBlocks: UInt64(Int64.max) + 1)
        ] {
            XCTAssertNil(record.capacity.total)
            XCTAssertNil(record.capacity.available)
        }
    }

    private func mountRecord(path: String = "/Volumes/Backup", source: String = "/dev/disk4s2",
                             flags: UInt32 = UInt32(MNT_LOCAL), blockSize: UInt64 = 4096,
                             blocks: UInt64 = 100, availableBlocks: UInt64 = 20) -> MountedDriveMountRecord {
        MountedDriveMountRecord(path: path, source: source, flags: flags, blockSize: blockSize,
                               blocks: blocks, availableBlocks: availableBlocks)
    }

    // MARK: - Discovery eligibility (all physical volumes, not name-keyed)

    private func identity(_ internalDisk: Bool, _ proto: String?, _ volumeName: String? = nil) -> WholeDiskIdentity? {
        WholeDiskIdentity(isInternal: internalDisk, deviceProtocol: proto, volumeName: volumeName)
    }

    func testDiscoveryIncludesAdditionalInternalAndExternalPhysicalVolumes() {
        let mounts = [
            mountRecord(path: "/Volumes/External", source: "/dev/disk4s2"),
            mountRecord(path: "/Volumes/StorageHD", source: "/dev/disk0s5"),
        ]
        let rows = MountedDriveStore.discover(mounts: mounts) { bsd in
            switch bsd {
            case "disk4s2": return identity(false, "USB", "External")
            case "disk0s5": return identity(true, "PCI-Express", "StorageHD")
            default: return nil
            }
        }
        XCTAssertEqual(rows.map(\.path), ["/Volumes/External", "/Volumes/StorageHD"])
        XCTAssertEqual(rows.map(\.name), ["External", "StorageHD"])
        XCTAssertEqual(rows.compactMap(\.usage).count, 2)
    }

    func testDiscoveryAcceptsEveryPhysicalBusAndRejectsVirtualOrUnknownDisks() {
        let buses = ["USB", "FireWire", "Thunderbolt", "PCI-Express", "Apple Fabric", "SATA", "SAS", "ATA", "Secure Digital"]
        for (index, bus) in buses.enumerated() {
            for internalDisk in [false, true] {
                let path = "/Volumes/Drive\(index)\(internalDisk ? "i" : "e")"
                let rows = MountedDriveStore.discover(mounts: [mountRecord(path: path, source: "/dev/disk\(index)s1")]) { _ in
                    identity(internalDisk, bus)
                }
                XCTAssertEqual(rows.count, 1, "\(bus) internal=\(internalDisk)")
            }
        }
        for proto in ["Disk Image", "Virtual Interface", ""] as [String?] {
            let rows = MountedDriveStore.discover(mounts: [mountRecord()]) { _ in identity(false, proto) }
            XCTAssertTrue(rows.isEmpty, "protocol \(proto ?? "nil")")
        }
        let noProtocol = MountedDriveStore.discover(mounts: [mountRecord()]) { _ in identity(false, nil) }
        XCTAssertTrue(noProtocol.isEmpty)
        let uninspectable = MountedDriveStore.discover(mounts: [mountRecord()]) { _ in nil }
        XCTAssertTrue(uninspectable.isEmpty)
    }

    func testDiscoveryKeepsBootAliasesHiddenAndNetworkMountsOut() {
        let mounts = [
            mountRecord(path: "/", source: "/dev/disk0s1"),
            mountRecord(path: "/System/Volumes/Data", source: "/dev/disk0s2"),
            mountRecord(path: "/Volumes/.timemachine/snapshot", source: "/dev/disk4s9"),
            mountRecord(path: "/Volumes/Hidden", source: "/dev/disk7s1", flags: UInt32(MNT_LOCAL | MNT_DONTBROWSE)),
            mountRecord(path: "/Volumes/Network", source: "/dev/disk8s1", flags: 0),
        ]
        let rows = MountedDriveStore.discover(mounts: mounts) { _ in identity(true, "PCI-Express") }
        XCTAssertTrue(rows.isEmpty)
    }

    func testDiscoveryListsOneRowPerDiskAndFallsBackToMountName() {
        let mounts = [
            mountRecord(path: "/Volumes/Backup", source: "/dev/disk4s2"),
            mountRecord(path: "/Volumes/BackupAlias", source: "/dev/disk4s2"),
            mountRecord(path: "/Volumes/Named", source: "/dev/disk9s1"),
            mountRecord(path: "/Volumes/EmptyName", source: "/dev/disk9s2"),
        ]
        let rows = MountedDriveStore.discover(mounts: mounts) { bsd in
            switch bsd {
            case "disk9s1": return identity(false, "USB", "Real Name")
            case "disk9s2": return identity(false, "USB", "")
            default: return identity(false, "USB")
            }
        }
        XCTAssertEqual(rows.map(\.path), ["/Volumes/Backup", "/Volumes/Named", "/Volumes/EmptyName"])
        XCTAssertEqual(rows.map(\.name), ["Backup", "Real Name", "EmptyName"])
    }

    @MainActor
    func testDisconnectedDriveDisappearsRatherThanBecomingZero() async {
        final class SequenceProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func next() -> [MountedDriveCandidate] {
                lock.lock()
                defer { lock.unlock() }
                calls += 1
                guard calls == 1 else { return [] }
                return [MountedDriveCandidate(name: "Backup", path: "/Volumes/Backup", isLocal: true, isHidden: false,
                                              isExternalPhysical: true, totalBytes: 1000, availableBytes: 70)]
            }
        }
        let sequence = SequenceProbe()
        let store = MountedDriveStore(probe: { sequence.next() })
        await store.refresh()
        XCTAssertEqual(store.rows.first?.usedPercent ?? -1, 93, accuracy: 0.001)
        await store.refresh(force: true)
        XCTAssertTrue(store.rows.isEmpty)
    }
}
