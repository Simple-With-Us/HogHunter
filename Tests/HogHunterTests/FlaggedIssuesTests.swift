import XCTest
@testable import HogHunter

@MainActor
final class FlaggedIssuesTests: XCTestCase {
    func testPriorityOrdering() {
        XCTAssertTrue(FlaggedPriority.critical < FlaggedPriority.high)
        XCTAssertTrue(FlaggedPriority.high < FlaggedPriority.medium)
        XCTAssertTrue(FlaggedPriority.medium < FlaggedPriority.low)
        XCTAssertTrue(FlaggedPriority.low < FlaggedPriority.info)

        let sorted = [FlaggedPriority.info, FlaggedPriority.critical, FlaggedPriority.medium].sorted()
        XCTAssertEqual(sorted, [.critical, .medium, .info])
    }

    func testEvaluatorFlagsCriticalMacDisk() {
        let store = HogStore(
            historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flagged-disk-\(UUID().uuidString).sqlite")
        )
        // Simulate low disk
        store.setDiskSpaceForTest(DiskSpace(freeBytes: 5 * 1024 * 1024 * 1024, totalBytes: 500 * 1024 * 1024 * 1024))

        let issues = FlaggedIssueEvaluator.evaluate(
            macStore: store,
            vpsSnapshot: nil,
            vpsError: nil,
            vpsConfigured: false
        )

        let diskIssues = issues.filter { $0.category == .disk && $0.host == .mac }
        XCTAssertFalse(diskIssues.isEmpty)
        XCTAssertEqual(diskIssues.first?.priority, .critical)
        XCTAssertEqual(diskIssues.first?.id, "mac.disk.critical")
    }

    func testEvaluatorFlagsServerFleetExtra() {
        let store = HogStore(
            historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flagged-server-\(UUID().uuidString).sqlite")
        )

        let snap = VPSStatusSnapshot(
            generatedAt: "2026-10-25T12:00:00Z",
            host: "fleet-hetzner-nbg1",
            devices: [
                "root": VPSDevice(mount: "/", freeBytes: 150 * 1024 * 1024 * 1024, note: "300GB disk: root"),
                "fleet_extra": VPSDevice(mount: "/mnt/fleet-extra", freeBytes: 8 * 1024 * 1024 * 1024, note: "1TB disk: extra volume /mnt/fleet-extra")
            ]
        )

        let issues = FlaggedIssueEvaluator.evaluate(
            macStore: store,
            vpsSnapshot: snap,
            vpsError: nil,
            vpsConfigured: true
        )

        let extraIssues = issues.filter { $0.id == "server.disk.extra.critical" }
        XCTAssertFalse(extraIssues.isEmpty)
        XCTAssertEqual(extraIssues.first?.priority, .critical)
        XCTAssertEqual(extraIssues.first?.host, .server)
        XCTAssertEqual(extraIssues.first?.category, .disk)
    }

    func testEvaluatorFlagsServerUnreachable() {
        let store = HogStore(
            historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flagged-err-\(UUID().uuidString).sqlite")
        )

        let issues = FlaggedIssueEvaluator.evaluate(
            macStore: store,
            vpsSnapshot: nil,
            vpsError: "ssh: connect to host 167.233.254.55 port 22: Connection refused",
            vpsConfigured: true
        )

        let errIssues = issues.filter { $0.id == "server.unreachable" }
        XCTAssertFalse(errIssues.isEmpty)
        XCTAssertEqual(errIssues.first?.priority, .high)
        XCTAssertEqual(errIssues.first?.host, .server)
    }

    func testEvaluatorPrioritizesIssues() {
        let store = HogStore(
            historyURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flagged-prio-\(UUID().uuidString).sqlite")
        )
        // High mac disk (92% used, <95% but >=90%) + critical server extra (<15GB)
        store.setDiskSpaceForTest(DiskSpace(freeBytes: 40 * 1024 * 1024 * 1024, totalBytes: 500 * 1024 * 1024 * 1024))

        let snap = VPSStatusSnapshot(
            generatedAt: "2026-10-25T12:00:00Z",
            host: "fleet-hetzner-nbg1",
            devices: [
                "root": VPSDevice(mount: "/", freeBytes: 150 * 1024 * 1024 * 1024, note: "300GB disk: root"),
                "fleet_extra": VPSDevice(mount: "/mnt/fleet-extra", freeBytes: 5 * 1024 * 1024 * 1024, note: "1TB disk: extra")
            ]
        )

        let issues = FlaggedIssueEvaluator.evaluate(
            macStore: store,
            vpsSnapshot: snap,
            vpsError: nil,
            vpsConfigured: true
        )

        // Critical must precede High
        XCTAssertGreaterThanOrEqual(issues.count, 2)
        XCTAssertEqual(issues[0].priority, .critical)
        XCTAssertEqual(issues[1].priority, .high)
    }
}
