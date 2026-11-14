import XCTest

@testable import HogHunter

/// The Mac ⋯ menu gates itself locally, the way the server gates its own
/// menu.  These tests pin which actions a row offers: the destructive ones
/// follow the row's quit and tame permissions, Sample follows its own
/// read-only rule, and a row with nothing to offer disables the menu.
final class MacActivityActionsTests: XCTestCase {
    private func row(
        pid: pid_t?,
        canQuit: Bool,
        quitBlockReason: String? = nil,
        isTamed: Bool = false,
        canTame: Bool = false
    ) -> HogRow {
        HogRow(
            id: pid.map { "p-\($0)-11" } ?? "h-history",
            keys: pid.map { [ProcessKey(pid: $0, startTime: 11)] } ?? [],
            name: "tool",
            detail: "",
            cpuPercent: 0,
            memoryBytes: 0,
            peakMemoryBytes: nil,
            presence: nil,
            icon: nil,
            path: nil,
            isApp: false,
            isGroup: false,
            canQuit: canQuit,
            quitBlockReason: quitBlockReason,
            isTamed: isTamed,
            canTame: canTame
        )
    }

    func testOrdinaryRowOffersQuitForceQuitTameAndSample() {
        let row = row(pid: 4242, canQuit: true, canTame: true)
        XCTAssertEqual(row.allowedActions, ["quit", "force-quit", "tame", "sample"])
        XCTAssertTrue(row.can(action: "quit"))
        XCTAssertTrue(row.can(action: "force-quit"))
        XCTAssertFalse(row.can(action: "untame"))
        XCTAssertNil(row.protectionReason)
    }

    func testTamedRowOffersRestorePriorityInsteadOfTame() {
        let row = row(pid: 4242, canQuit: true, isTamed: true, canTame: true)
        XCTAssertEqual(row.allowedActions, ["quit", "force-quit", "untame", "sample"])
        XCTAssertFalse(row.can(action: "tame"))
        XCTAssertTrue(row.can(action: "untame"))
    }

    func testBlockedRowOffersOnlySampleAndReportsTheReason() {
        // Sampling reads a process instead of stopping it, so a row Quit is
        // blocked for may still be sampled; ownership is rechecked when
        // Sample is actually chosen.
        let row = row(pid: 4242, canQuit: false, quitBlockReason: "owned by another user")
        XCTAssertEqual(row.allowedActions, ["sample"])
        XCTAssertFalse(row.can(action: "quit"))
        XCTAssertEqual(row.protectionReason, "owned by another user")
    }

    func testLaunchdRowOffersNothing() {
        let row = row(pid: 1, canQuit: false, quitBlockReason: "system process")
        XCTAssertTrue(row.allowedActions.isEmpty)
        XCTAssertFalse(row.canSample)
    }

    func testOwnProcessRowOffersNothing() {
        let row = row(pid: getpid(), canQuit: false, quitBlockReason: "this app")
        XCTAssertTrue(row.allowedActions.isEmpty)
        XCTAssertFalse(row.canSample)
    }

    func testHistoryRowOffersNothing() {
        let row = row(pid: nil, canQuit: false)
        XCTAssertTrue(row.allowedActions.isEmpty)
        XCTAssertFalse(row.canSample)
    }
}
