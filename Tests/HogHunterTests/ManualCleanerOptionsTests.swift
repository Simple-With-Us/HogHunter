import XCTest
@testable import HogHunter

@MainActor
final class ManualCleanerOptionsTests: XCTestCase {
    func testExternalExclusionEditPreventsCleaningAStaleSelection() async throws {
        let suite = "hh174-clean-revalidation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let logs = home.appendingPathComponent("Library/Logs/FixtureLogs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("fixture.log")
        try Data(repeating: 65, count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }
        CleanerExclusions.update(in: defaults) { exclusions in
            exclusions.excludedCategories = Set(CleanCategory.allCases
                .filter { $0 != .logsAndDiagnostics }.map(\.rawValue))
        }
        let cleaner = DiskCleaner(homeDirectory: home)
        let store = DiskCleanerStore(cleaner: cleaner, historyStore: CleanupHistoryStore(inMemory: true),
                                     exclusionsDefaults: defaults, manualScanOnly: true)

        store.scan()
        for _ in 0..<100 {
            if case .scanned = store.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .scanned = store.state else { return XCTFail("fixture scan did not finish") }
        store.selectAll()
        XCTAssertGreaterThan(store.totalSelectedItemsCount(), 0)

        CleanerExclusions.update(in: defaults) { $0.excludedPaths.append(logs.path) }
        store.cleanSelected(createSnapshot: false)
        XCTAssertEqual(store.state, .idle, "the stale scan must be invalidated before cleaning starts")
        XCTAssertNil(store.report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnExclusionEditDuringACleanStillDropsTheStaleReport() async throws {
        let suite = "hh174-mid-clean-edit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let logs = home.appendingPathComponent("Library/Logs/FixtureLogs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 1024).write(to: logs.appendingPathComponent("fixture.log"))
        defer { try? FileManager.default.removeItem(at: home) }
        CleanerExclusions.update(in: defaults) { exclusions in
            exclusions.excludedCategories = Set(CleanCategory.allCases
                .filter { $0 != .logsAndDiagnostics }.map(\.rawValue))
        }
        let store = DiskCleanerStore(cleaner: DiskCleaner(homeDirectory: home),
                                     historyStore: CleanupHistoryStore(inMemory: true),
                                     exclusionsDefaults: defaults, manualScanOnly: true)

        store.scan()
        for _ in 0..<100 {
            if case .scanned = store.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .scanned = store.state else { return XCTFail("fixture scan did not finish") }
        store.selectAll()
        XCTAssertGreaterThan(store.totalSelectedItemsCount(), 0)

        // `cleanSelected` moves the store to `.cleaning` before it returns, and
        // everything below runs on the MainActor without an await in between, so
        // the edit is guaranteed to land while the clean is still in flight.
        store.cleanSelected(createSnapshot: false)
        XCTAssertTrue(store.isCleaning)
        CleanerExclusions.update(in: defaults) { $0.excludedPaths.append(home.appendingPathComponent("from-phone").path) }
        store.reloadExclusions()
        XCTAssertNotNil(store.report, "a mid-clean edit must not blank the page mid-clean")

        for _ in 0..<600 {
            if !store.isCleaning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isCleaning, "the fixture clean did not finish")
        XCTAssertNil(store.report, "an edit during a clean must still invalidate the report afterwards")
        XCTAssertEqual(store.exclusions.excludedPaths, [home.appendingPathComponent("from-phone").path])
    }

    func testDashboardOptionsInvalidateReportWithoutStartingAnotherScan() async throws {
        let suite = "hh174-manual-cleaner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // An explicit scan is safe in this fixture: every category is excluded.
        CleanerExclusions.update(in: defaults) { exclusions in
            exclusions.excludedCategories = Set(CleanCategory.allCases.map(\.rawValue))
        }
        let store = DiskCleanerStore(historyStore: CleanupHistoryStore(inMemory: true),
                                     exclusionsDefaults: defaults, manualScanOnly: true)

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

        store.scan()
        for _ in 0..<100 {
            if case .scanned = store.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .scanned = store.state else {
            return XCTFail("the third explicit fixture scan did not finish")
        }
        CleanerExclusions.update(in: defaults) { $0.excludedPaths.append("/fixture/from-phone") }
        store.reloadExclusions()
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.report, "reactivating after an external edit must drop stale results")
        XCTAssertEqual(store.exclusions.excludedPaths, ["/fixture/keep", "/fixture/from-phone"])
    }
}
