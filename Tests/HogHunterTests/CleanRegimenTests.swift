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

    func testEmptyRulesDoNotSelectEveryScannedItem() {
        let item = CleanItem(
            category: .userCaches,
            title: "cache",
            subtitle: "cache",
            url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-test"),
            bytes: 10,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
        let empty = CleanRegimenRunner.pendingItems(from: [item], rules: [])
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.skipReason, "No cleaning rules are enabled.")

        let unmatched = CleanRegimenRunner.pendingItems(from: [item], rules: ["logs"])
        XCTAssertTrue(unmatched.items.isEmpty)
        XCTAssertEqual(unmatched.skipReason, "Nothing matched the enabled rules.")

        let matched = CleanRegimenRunner.pendingItems(from: [item], rules: ["dev-caches"])
        XCTAssertEqual(matched.items.map(\.title), ["cache"])
        XCTAssertNil(matched.skipReason)
    }

    func testTempFilesRuleIsDecoupledFromTrash() {
        func item(category: CleanCategory, title: String) -> CleanItem {
            CleanItem(
                category: category,
                title: title,
                subtitle: title,
                url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-\(title)"),
                bytes: 10,
                fileCount: 1,
                lastModified: nil,
                isSelected: true,
                detail: nil
            )
        }
        let trash = item(category: .trash, title: "trash")
        let temp = item(category: .tempFiles, title: "tmp")
        XCTAssertEqual(CleanRegimenRunner.ruleName(for: trash), "temp-scratch")
        XCTAssertEqual(CleanRegimenRunner.ruleName(for: temp), "tmp-files")

        let onlyTrash = CleanRegimenRunner.pendingItems(from: [trash, temp], rules: ["temp-scratch"])
        XCTAssertEqual(onlyTrash.items.map(\.title), ["trash"])
        XCTAssertNil(onlyTrash.skipReason)

        let onlyTemp = CleanRegimenRunner.pendingItems(from: [trash, temp], rules: ["tmp-files"])
        XCTAssertEqual(onlyTemp.items.map(\.title), ["tmp"])
        XCTAssertNil(onlyTemp.skipReason)

        XCTAssertTrue(CleanRegimen.schedulableRules.contains("tmp-files"))
        XCTAssertFalse(
            CleanRegimen.defaultRules.contains("tmp-files"),
            "temp files stay opt-in for unattended runs, like snapshots"
        )
    }

    func testStaleBackupsNeverScheduleUnattended() {
        let backup = CleanItem(
            category: .staleBackups,
            title: "state.vscdb.bak-old",
            subtitle: "backup",
            url: URL(fileURLWithPath: "/tmp/hoghunter-regimen-backup"),
            bytes: 10,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
        XCTAssertEqual(CleanRegimenRunner.ruleName(for: backup), "ask-first")
        let pending = CleanRegimenRunner.pendingItems(from: [backup], rules: Set(CleanRegimen.schedulableRules))
        XCTAssertTrue(pending.items.isEmpty, "no schedulable rule may take tool-made backups unattended")
    }

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
