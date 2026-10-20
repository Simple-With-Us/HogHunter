import XCTest
@testable import HogHunter

@MainActor
final class ManualCleanerOptionsTests: XCTestCase {
    func testDashboardOptionsInvalidateReportWithoutStartingAnotherScan() async throws {
        let suite = "hh174-manual-cleaner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // An explicit scan is safe in this fixture: every category is excluded.
        CleanerExclusions.update(in: defaults) { exclusions in
            exclusions.excludedCategories = Set(CleanCategory.allCases.map(\.rawValue))
        }
        let store = DiskCleanerStore(historyStore: CleanupHistoryStore(inMemory: true),
                                     exclusionsDefaults: defaults, rescanAfterExclusionChange: false)

        store.scan()
        for _ in 0..<100 {
            if case .scanned = store.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .scanned = store.state else {
            return XCTFail("the explicit fixture scan did not finish")
        }
        XCTAssertNotNil(store.report)

        store.setTier(.extreme)
        XCTAssertEqual(store.selectedTier, .extreme)
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.report, "changing tier requires a fresh explicit Scan")
        XCTAssertTrue(store.selectedItemIds.isEmpty)

        store.scan()
        for _ in 0..<100 {
            if case .scanned = store.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .scanned = store.state else {
            return XCTFail("the second explicit fixture scan did not finish")
        }
        store.addExcludedPath("/fixture/keep")
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.report, "editing exclusions requires a fresh explicit Scan")
        XCTAssertEqual(store.exclusions.excludedPaths, ["/fixture/keep"])
    }
}
