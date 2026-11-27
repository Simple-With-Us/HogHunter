import XCTest
@testable import HogHunter

final class CompanionFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testFreshSnapshotIsLive() {
        XCTAssertEqual(
            CompanionFreshness.state(sampledAt: now.addingTimeInterval(-5), lastSuccessfulRefresh: now, now: now),
            .live)
    }

    func testOldSnapshotIsStale() {
        XCTAssertEqual(
            CompanionFreshness.state(
                sampledAt: now.addingTimeInterval(-CompanionFreshness.staleAfter - 1),
                lastSuccessfulRefresh: now, now: now),
            .stale)
    }

    func testNoSuccessfulPollRecentlyIsReconnecting() {
        XCTAssertEqual(
            CompanionFreshness.state(
                sampledAt: now, lastSuccessfulRefresh: now.addingTimeInterval(-CompanionFreshness.reconnectingAfter - 1),
                now: now),
            .reconnecting)
        XCTAssertEqual(
            CompanionFreshness.state(sampledAt: nil, lastSuccessfulRefresh: now, now: now),
            .reconnecting)
    }

    func testRemainingSecondsRoundsUpAndNeverGoesNegative() {
        XCTAssertEqual(CompanionFreshness.remainingSeconds(until: now.addingTimeInterval(14.2), now: now), 15)
        XCTAssertEqual(CompanionFreshness.remainingSeconds(until: now.addingTimeInterval(-3), now: now), 0)
        XCTAssertEqual(CompanionFreshness.remainingSeconds(until: nil, now: now), 0)
    }

    func testCountdownText() {
        XCTAssertNil(CompanionFreshness.countdownText(remainingSeconds: 0))
        XCTAssertEqual(CompanionFreshness.countdownText(remainingSeconds: 1), "Try again in 1 second")
        XCTAssertEqual(CompanionFreshness.countdownText(remainingSeconds: 15), "Try again in 15 seconds")
    }
}
