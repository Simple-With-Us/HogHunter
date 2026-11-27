import XCTest
@testable import HogHunter

/// WS2: Mac Run Now confirmations and status clarity.  Copy and status
/// lines are pinned as data so no test renders a sheet or runs a clean.
final class MacRunConfirmationStatusTests: XCTestCase {

    private func status(
        health: String = "healthy",
        launchdLoaded: Bool = true,
        lastFull: Double? = nil,
        updatedAt: Double? = nil
    ) -> MaintainStatus {
        MaintainStatus(
            health: health, launchdLoaded: launchdLoaded,
            nextRunAt: [:], intervalsSeconds: [:],
            lastRunAt: lastFull.map { ["full": $0] },
            lastRun: nil, stepLastResults: [:], historyCount: 0,
            updatedAt: updatedAt)
    }

    // MARK: - Confirmation copy

    func testRunNowCopyIsTitleCaseWithNBSPBodies() {
        XCTAssertEqual(RunNowCopy.maintainTitle, "Run Maintenance Now?")
        XCTAssertEqual(RunNowCopy.maintainConfirm, "Run Maintenance")
        XCTAssertEqual(RunNowCopy.regimenTitle, "Run Automatic Cleanup Now?")
        XCTAssertEqual(RunNowCopy.regimenConfirm, "Run Cleanup")
        for body in [RunNowCopy.maintainBody, RunNowCopy.regimenBody] {
            XCTAssertTrue(body.contains("\u{00A0} "), body)
            XCTAssertFalse(body.contains("  "), body)
        }
    }

    // MARK: - Regimen single status line

    func testRegimenStatusLineShowsGateRetryTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let retry = now.addingTimeInterval(3600)
        let line = CleanRegimenRunner.regimenStatusLine(
            isRunning: false, lastSummary: nil,
            waitingReason: "The last run could not take a safety snapshot, so it will try again later.",
            nextRunDate: retry, gateRetryDate: retry, now: now,
            formatDateTime: { _ in "Nov 14, 2023 at 3:42 PM" })
        XCTAssertEqual(line, "The last run could not take a safety snapshot, so it will try again at Nov 14, 2023 at 3:42 PM.")
        XCTAssertFalse(line.contains("\n"))
    }

    func testRegimenStatusLinePrecedence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let next = now.addingTimeInterval(3600)
        let fmt: (Date) -> String = { _ in "T" }
        XCTAssertEqual(CleanRegimenRunner.regimenStatusLine(
            isRunning: true, lastSummary: "Done.", waitingReason: "Waiting.",
            nextRunDate: next, gateRetryDate: nil, now: now, formatDateTime: fmt), "Running now.")
        XCTAssertEqual(CleanRegimenRunner.regimenStatusLine(
            isRunning: false, lastSummary: "Done.", waitingReason: "Waiting for the Mac to be idle.",
            nextRunDate: next, gateRetryDate: nil, now: now, formatDateTime: fmt), "Waiting for the Mac to be idle.")
        XCTAssertEqual(CleanRegimenRunner.regimenStatusLine(
            isRunning: false, lastSummary: "Done.", waitingReason: nil,
            nextRunDate: next, gateRetryDate: nil, now: now, formatDateTime: fmt), "Done.\u{00A0} Next run T.")
        XCTAssertEqual(CleanRegimenRunner.regimenStatusLine(
            isRunning: false, lastSummary: nil, waitingReason: nil,
            nextRunDate: nil, gateRetryDate: now.addingTimeInterval(-60), now: now, formatDateTime: fmt), "Scheduled.")
    }

    // MARK: - Maintain No Reading / Waiting / Unreachable

    func testMaintainReachabilityDistinguishesStates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = now.timeIntervalSince1970
        XCTAssertEqual(MaintainStatus.reachability(status: nil, isRunning: false, now: now), .noReading)
        XCTAssertEqual(MaintainStatus.reachability(status: nil, isRunning: true, now: now), .running)
        XCTAssertEqual(MaintainStatus.reachability(
            status: status(updatedAt: fresh), isRunning: false, now: now), .waiting)
        XCTAssertEqual(MaintainStatus.reachability(
            status: status(lastFull: fresh, updatedAt: fresh), isRunning: false, now: now), .ready)
        XCTAssertEqual(MaintainStatus.reachability(
            status: status(lastFull: fresh, updatedAt: fresh - 3600), isRunning: false, now: now), .unreachable)
        XCTAssertEqual(MaintainStatus.reachability(
            status: status(health: "unloaded", launchdLoaded: false, lastFull: fresh, updatedAt: fresh),
            isRunning: false, now: now), .unreachable)
        XCTAssertEqual(MaintainReachability.noReading.title, "No Reading Yet")
        XCTAssertEqual(MaintainReachability.waiting.title, "Waiting For First Run")
        XCTAssertEqual(MaintainReachability.unreachable.title, "Unreachable")
    }
}
