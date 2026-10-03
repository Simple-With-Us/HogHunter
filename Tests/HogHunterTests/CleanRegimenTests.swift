import XCTest
@testable import HogHunter

/// Tests for the regimen model: what a scheduled unattended clean is allowed
/// to do, and what a corrupt stored regimen must never be able to do.
final class CleanRegimenTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "hoghunter.tests.regimen.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - Defaults

    func testRegimenIsOffByDefault() {
        // An unattended delete is a different promise than a button press.
        XCTAssertFalse(CleanRegimen().isEnabled)
    }

    func testDefaultsAreValid() {
        let r = CleanRegimen()
        XCTAssertTrue(r.isValid)
        XCTAssertGreaterThanOrEqual(r.targetsPerChunk, 1)
        XCTAssertTrue(r.createSnapshotBeforeClean, "an unattended clean needs a rollback point")
    }

    func testDefaultRulesExcludeAskFirst() {
        // Nothing in ask-first is ever deleted without a human, so a regimen
        // has no business listing it.
        XCTAssertFalse(CleanRegimen.defaultRules.contains("ask-first"))
        for rule in CleanRegimen.defaultRules {
            XCTAssertTrue(CleanRegimen.schedulableRules.contains(rule), "\(rule) is not schedulable")
        }
    }

    // MARK: - Sanitizing a stored value

    func testSanitizeRepairsOutOfRangeValues() {
        var r = CleanRegimen()
        r.intervalHours = 0
        r.targetsPerChunk = 0
        r.pressuredTargetsPerChunk = -3
        r.chunkPauseSeconds = .nan
        r.expensiveTierFreeGB = -1
        let fixed = r.sanitized()
        XCTAssertTrue(fixed.isValid)
        XCTAssertGreaterThanOrEqual(fixed.targetsPerChunk, 1)
        XCTAssertGreaterThanOrEqual(fixed.pressuredTargetsPerChunk, 1)
        XCTAssertEqual(fixed.chunkPauseSeconds, 5, "NaN pause falls back to the default")
        XCTAssertGreaterThan(fixed.expensiveTierFreeGB, 0)
    }

    func testSanitizeDropsRulesThatAreNotSchedulable() {
        var r = CleanRegimen()
        // A hand-edited or future-written blob must not smuggle in a rule the
        // scheduler has no business running.
        r.enabledRules = ["dev-caches", "ask-first", "totally-made-up"]
        let fixed = r.sanitized()
        XCTAssertEqual(fixed.enabledRules, ["dev-caches"])
    }

    func testSanitizeCapsAbsurdInterval() {
        var r = CleanRegimen()
        r.intervalHours = 1_000_000
        XCTAssertEqual(r.sanitized().intervalHours, 24 * 14)
    }

    func testSanitizeHandlesInfiniteInterval() {
        var r = CleanRegimen()
        r.intervalHours = .infinity
        XCTAssertTrue(r.sanitized().isValid)
    }

    // MARK: - Persistence

    func testRoundTripsThroughDefaults() {
        // Exercised through a private defaults suite so the test never touches
        // the real user's saved regimen.
        let suite = "hoghunter.tests.regimen.\(UUID().uuidString)"
        let defaults = makeDefaults()

        var r = CleanRegimen()
        r.isEnabled = true
        r.intervalHours = 6
        r.pressuredTargetsPerChunk = 1
        r.enabledRules = ["logs", "brew"]

        let data = try? JSONEncoder().encode(r)
        defaults.set(data, forKey: "hoghunter.cleaner.regimen")
        let decoded = try? JSONDecoder().decode(CleanRegimen.self, from: data ?? Data())
        XCTAssertEqual(decoded, r)

        defaults.removePersistentDomain(forName: suite)
    }

    func testUnknownFieldsDoNotBreakDecoding() {
        // Forward compatibility: a blob written by a newer build must still
        // load, and must not take the app down with it.
        let json = """
        {"isEnabled":true,"intervalHours":8,"someFieldFromTheFuture":{"a":1}}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(CleanRegimen.self, from: json)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.isEnabled, true)
        XCTAssertEqual(decoded?.intervalHours, 8)
    }
}
