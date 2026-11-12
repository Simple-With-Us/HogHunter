import XCTest
@testable import HogHunter

@MainActor
final class CleanRegimenPartialScanTests: XCTestCase {
    func testPartialDiscoveryCleansKnownItemsWithoutAdvancingCompletedClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HHPartialRegimen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HHPartialRegimen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let previous = now.addingTimeInterval(-5 * 3600)
        let key = "hoghunter.cleaner.regimen.lastRunAt"
        defaults.set(previous, forKey: key)
        let item = CleanItem(category: .userCaches, title: "Fixture", subtitle: "Fixture",
            url: root.appendingPathComponent("never-clean"), bytes: 4096, fileCount: 1,
            lastModified: nil, isSelected: true)
        let report = CleanScanReport(categories: [CleanCategoryReport(category: .userCaches,
            items: [item], totalBytes: 4096, selectedBytes: 4096, itemCount: 1)], totalBytes: 4096,
            totalSelectedBytes: 4096, scannedAt: now, isPartial: true, incompleteCategories: [.logsAndDiagnostics])
        var plan = CleanRegimen(isEnabled: true, intervalHours: 4, avoidDuringBuilds: false,
            enabledRules: ["app-caches", "logs"])
        plan.createSnapshotBeforeClean = false
        var cleanCalls = 0
        let runner = CleanRegimenRunner(now: { now }, defaults: defaults,
            lockProvider: { HousekeeperLock(path: root.appendingPathComponent("lock")) },
            scanProvider: { exclusions in
                XCTAssertFalse(exclusions.isCategoryExcluded(.userCaches))
                XCTAssertFalse(exclusions.isCategoryExcluded(.logsAndDiagnostics))
                XCTAssertTrue(exclusions.isCategoryExcluded(.developer))
                XCTAssertTrue(exclusions.isCategoryExcluded(.apfsSnapshots))
                return report
            }, exclusionsProvider: { CleanerExclusions() }, cleanProvider: { items, _, _ in
                cleanCalls += 1
                XCTAssertEqual(items.map(\.id), [item.id])
                return CleanResult(bytesReclaimed: 4096, itemsRemoved: 1, errors: [], cleanedAt: now)
            })
        await runner.runNow(regimen: plan)?.value
        XCTAssertEqual(cleanCalls, 1)
        XCTAssertEqual(runner.lastRun?.itemsRemoved, 1)
        XCTAssertTrue(runner.lastRun?.skippedReason?.contains("incomplete") == true)
        XCTAssertEqual(defaults.object(forKey: key) as? Date, previous)
        XCTAssertTrue(runner.isDue(regimen: plan, lastRunAt: previous))
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(runner.lastSummary?.contains("incomplete") == true)
    }

    func testEnabledRulesRestrictDiscoveryCategories() {
        XCTAssertEqual(CleanRegimenRunner.scanCategories(for: ["logs"]), [.logsAndDiagnostics])
        XCTAssertEqual(CleanRegimenRunner.scanCategories(for: ["tmp-files"]), [.tempFiles])
        XCTAssertTrue(CleanRegimenRunner.scanCategories(for: []).isEmpty)
    }
}
