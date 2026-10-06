import XCTest

@testable import HogHunter

/// Covers `AlertPolicy`, the decision half of alerting.  The policy is a pure
/// struct with an injected clock, so every case here is exact: no waiting, no
/// notification centre, no store.
final class AlertPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let sustained: TimeInterval = 5 * 60
    private let cooldown: TimeInterval = 30 * 60

    private func makePolicy() -> AlertPolicy {
        AlertPolicy(sustained: sustained, cooldown: cooldown)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    func testProjectWithoutCooldownCannotRetainPreviousProjectValue() {
        var policy = makePolicy()
        for missingOrInvalid in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            policy.applyCooldown(minutes: 90)
            XCTAssertEqual(policy.cooldown, 90 * 60)
            policy.applyCooldown(minutes: missingOrInvalid)
            XCTAssertEqual(policy.cooldown, 30 * 60)
        }
    }

    // MARK: - Sustained duration

    func testDoesNotFireBeforeTheSustainedDurationHasElapsed() {
        var policy = makePolicy()
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(0)))
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(60)))
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(sustained - 1)))
    }

    func testFiresOnceTheSustainedDurationIsReached() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))
    }

    func testFiresOnlyOnceWhileItStaysAboveTheThreshold() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))

        var firings = 0
        for second in stride(from: sustained + 1, through: cooldown, by: 1) {
            if policy.step(id: "a", above: true, now: at(second)) { firings += 1 }
        }
        XCTAssertEqual(firings, 0, "one sustained hog must produce one notification")
    }

    func testTimeAboveThresholdReportsHowLongTheRowHasBeenHigh() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "a", above: true, now: at(90))
        XCTAssertEqual(policy.timeAboveThreshold(id: "a", now: at(90)), 90, accuracy: 0.0001)
        XCTAssertEqual(policy.timeAboveThreshold(id: "b", now: at(90)), 0, accuracy: 0.0001)
    }

    // MARK: - Cooldown

    func testCooldownSuppressesASecondNotification() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))
        XCTAssertFalse(
            policy.step(id: "a", above: true, now: at(sustained + cooldown - 1)),
            "a row must stay quiet for the whole cooldown"
        )
    }

    func testFiresAgainOnceTheCooldownHasPassed() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained + cooldown)))
    }

    func testCooldownSurvivesTheRowLeavingTheCandidateSet() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))

        // The row drops out of the candidate set for one tick and comes back.
        policy.forgetAll(except: [], now: at(sustained + 1))

        _ = policy.step(id: "a", above: true, now: at(sustained + 2))
        XCTAssertFalse(
            policy.step(id: "a", above: true, now: at(sustained + 2 + sustained)),
            "leaving the candidate set must not hand the row a fresh cooldown"
        )
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained + cooldown + 1)))
    }

    func testAnExpiredCooldownEntryIsForgotten() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))
        XCTAssertEqual(policy.trackedIds, ["a"])

        policy.forgetAll(except: [], now: at(sustained + cooldown - 1))
        XCTAssertEqual(policy.trackedIds, ["a"], "the cooldown is still running")

        policy.forgetAll(except: [], now: at(sustained + cooldown + 1))
        XCTAssertTrue(policy.trackedIds.isEmpty, "an expired cooldown must not be kept forever")
    }

    // MARK: - Dropping below the threshold

    func testDroppingBelowTheThresholdResetsTheSustainedClock() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "a", above: true, now: at(sustained - 1))
        XCTAssertFalse(policy.step(id: "a", above: false, now: at(sustained)))
        XCTAssertEqual(policy.timeAboveThreshold(id: "a", now: at(sustained)), 0, accuracy: 0.0001)

        // The clock starts again from here, so the old head start is gone.
        _ = policy.step(id: "a", above: true, now: at(sustained + 1))
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(sustained + sustained)))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained + 1 + sustained)))
    }

    func testFlappingNeverFires() {
        var policy = makePolicy()
        var above = true
        for second in stride(from: 0.0, through: 4 * 3600, by: 30) {
            XCTAssertFalse(
                policy.step(id: "a", above: above, now: at(second)),
                "a row that never stays high for the sustained duration must never fire"
            )
            above.toggle()
        }
    }

    // MARK: - Independence

    func testRowsAreTrackedIndependently() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "b", above: true, now: at(120))
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))
        XCTAssertFalse(policy.step(id: "b", above: true, now: at(sustained)))
        XCTAssertTrue(policy.step(id: "b", above: true, now: at(120 + sustained)))
    }

    func testForgettingKeepsTheRowsTheCallerStillHasInHand() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "b", above: true, now: at(0))
        policy.forgetAll(except: ["a"], now: at(1))
        XCTAssertEqual(policy.trackedIds, ["a"])
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained)))
        XCTAssertFalse(policy.step(id: "b", above: true, now: at(sustained)), "b's clock restarted")
    }

    // MARK: - Reset

    /// Reset drops every entry, the way it looked when the policy was first
    /// created.  Used when alerting is turned off, so re-enabling starts from
    /// a clean slate instead of letting a row that was in cooldown fire
    /// immediately or letting a row that was almost through a sustained
    /// window finish where it left off.
    func testResetDropsEveryEntry() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "b", above: true, now: at(0))
        _ = policy.step(id: "a", above: true, now: at(sustained))   // a fires
        XCTAssertEqual(policy.trackedIds, ["a", "b"])
        policy.reset()
        XCTAssertEqual(policy.trackedIds, [])
        // Both rows start over: neither is in cooldown, neither is partway
        // through a sustained window.
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(sustained + 1)))
        XCTAssertFalse(policy.step(id: "b", above: true, now: at(sustained + 1)))
    }

    func testResetAllowsARowThatJustFiredToFireAgainOnTheNextTick() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "a", above: true, now: at(sustained))
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(sustained + 1)), "cooldown is active")
        policy.reset()
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(sustained + 1)), "sustained clock starts over")
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained + 1 + sustained)))
    }

    func testResetLetsAPartwayThroughRowRestartFromZero() {
        var policy = makePolicy()
        _ = policy.step(id: "a", above: true, now: at(0))
        _ = policy.step(id: "a", above: true, now: at(sustained - 60))
        // Without reset the next step at sustained + 1 would fire, because
        // the sustained clock has been running since t=0.
        XCTAssertTrue(policy.step(id: "a", above: true, now: at(sustained + 1)))
        // Reset and try again from the same wall-clock instant.
        policy.reset()
        XCTAssertFalse(policy.step(id: "a", above: true, now: at(sustained + 1)), "sustained clock started over")
    }

    // MARK: - Copy

    @MainActor
    func testMessageNamesThePerCoreScaleTheThresholdIsSetOn() {
        XCTAssertEqual(
            Alerts.message(name: "Chrome", cpuPercent: 412, seconds: 300),
            "Chrome has used 412% of one core for 5 minutes."
        )
        XCTAssertEqual(
            Alerts.message(name: "node", cpuPercent: 99.5, seconds: 60),
            "node has used 99.5% of one core for 1 minute."
        )
    }
}
