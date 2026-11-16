import XCTest

@testable import HogHunter

/// The Mac ⋯ menu gates itself locally, the way the server gates its own
/// menu.  These tests pin which actions a row offers: the destructive ones
/// follow the row's quit and tame permissions, Sample follows its own
/// read-only rule, and a row with nothing to offer disables the menu.
///
/// Sample gating runs the same live readiness check as the action itself
/// (`ProcessControl.sampleChoice`), so the sample cases use real child
/// processes of the test runner — the `ProcessIdentityTests` pattern: same
/// user, harmless (`sleep`), with real start times read back from the
/// kernel.
final class MacActivityActionsTests: XCTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children.removeAll()
        super.tearDown()
    }

    private func spawnSleeper() throws -> ProcessKey {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        children.append(process)
        let pid = process.processIdentifier
        var start: UInt64?
        for _ in 0..<50 {
            start = ProcessControl.startTime(pid)
            if start != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return ProcessKey(pid: pid, startTime: try XCTUnwrap(start))
    }

    /// A key for a process that is already running (this runner, launchd),
    /// with its real start time when the kernel will report it.
    private func liveKey(_ pid: pid_t) -> ProcessKey {
        ProcessKey(pid: pid, startTime: ProcessControl.startTime(pid) ?? 0)
    }

    private func row(
        keys: [ProcessKey],
        canQuit: Bool,
        quitBlockReason: String? = nil,
        isTamed: Bool = false,
        canTame: Bool = false
    ) -> HogRow {
        HogRow(
            id: keys.first.map { "p-\($0.pid)-\($0.startTime)" } ?? "h-history",
            keys: keys,
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

    func testOrdinaryRowOffersQuitForceQuitTameAndSample() throws {
        let row = row(keys: [try spawnSleeper()], canQuit: true, canTame: true)
        XCTAssertEqual(row.allowedActions, ["quit", "force-quit", "tame", "sample"])
        XCTAssertTrue(row.can(action: "quit"))
        XCTAssertTrue(row.can(action: "force-quit"))
        XCTAssertFalse(row.can(action: "untame"))
        XCTAssertNil(row.protectionReason)
    }

    func testTamedRowOffersRestorePriorityInsteadOfTame() throws {
        let row = row(keys: [try spawnSleeper()], canQuit: true, isTamed: true, canTame: true)
        XCTAssertEqual(row.allowedActions, ["quit", "force-quit", "untame", "sample"])
        XCTAssertFalse(row.can(action: "tame"))
        XCTAssertTrue(row.can(action: "untame"))
    }

    func testBlockedRowOffersOnlySampleAndReportsTheReason() throws {
        // Sampling reads a process instead of stopping it, so a row Quit is
        // blocked for may still be sampled; ownership is rechecked when
        // Sample is actually chosen.
        let row = row(keys: [try spawnSleeper()], canQuit: false, quitBlockReason: "owned by another user")
        XCTAssertEqual(row.allowedActions, ["sample"])
        XCTAssertFalse(row.can(action: "quit"))
        XCTAssertEqual(row.protectionReason, "owned by another user")
    }

    func testLaunchdRowOffersNothing() {
        let row = row(keys: [liveKey(1)], canQuit: false, quitBlockReason: "system process")
        XCTAssertTrue(row.allowedActions.isEmpty)
        XCTAssertFalse(row.canSample)
    }

    func testOwnProcessRowOffersNothing() {
        let row = row(keys: [liveKey(getpid())], canQuit: false, quitBlockReason: "this app")
        XCTAssertTrue(row.allowedActions.isEmpty)
        XCTAssertFalse(row.canSample)
    }

    func testHistoryRowOffersNothing() {
        let row = row(keys: [], canQuit: false)
        XCTAssertTrue(row.allowedActions.isEmpty)
        XCTAssertFalse(row.canSample)
    }

    /// The grouped-row case the first-key gate got wrong: when the first
    /// member cannot be sampled — Hog Hunter itself, launchd, a recycled
    /// pid — a later sampleable member still earns the row its Sample
    /// action.
    func testGroupedRowWithUnsampleableFirstKeyStillOffersSample() throws {
        let sleeper = try spawnSleeper()

        let selfFirst = row(keys: [liveKey(getpid()), sleeper], canQuit: true, canTame: true)
        XCTAssertTrue(selfFirst.canSample)
        XCTAssertTrue(selfFirst.can(action: "sample"))

        let launchdFirst = row(keys: [liveKey(1), sleeper], canQuit: true, canTame: true)
        XCTAssertTrue(launchdFirst.canSample)

        let stale = ProcessKey(pid: sleeper.pid, startTime: sleeper.startTime &+ 1)
        let staleFirst = row(keys: [stale, try spawnSleeper()], canQuit: true, canTame: true)
        XCTAssertTrue(staleFirst.canSample)
    }

    func testGroupedRowWithNoSampleableMemberOffersNoSample() {
        let row = row(keys: [liveKey(getpid()), liveKey(1)], canQuit: true, canTame: true)
        XCTAssertFalse(row.canSample)
        XCTAssertEqual(row.allowedActions, ["quit", "force-quit", "tame"])
    }
}
