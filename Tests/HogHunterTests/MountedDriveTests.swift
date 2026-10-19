import XCTest
@testable import HogHunter

final class MountedDriveTests: XCTestCase {
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
