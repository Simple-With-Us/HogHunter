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
        XCTAssertTrue(runner.lastRun?.skippedReason?.contains("cleaned 1 item with 0 errors") == true,
                      "the record reports the actual clean outcome, not a blanket claim")
        XCTAssertEqual(defaults.object(forKey: key) as? Date, previous)
        // The retry backs off instead of re-walking the disk at the next
        // check:  not due now, due once the backoff has passed.  A scan
        // whose cause persists fails the same way minutes later, and every
        // retry holds the housekeeper lock against the Python ticks.
        XCTAssertNotNil(defaults.object(forKey: "hoghunter.cleaner.regimen.lastPartialRunAt"))
        XCTAssertFalse(runner.isDue(regimen: plan, lastRunAt: previous))
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(CleanRegimenRunner.partialRetryBackoff).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(runner.partialRetryDate?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(CleanRegimenRunner.partialRetryBackoff).timeIntervalSince1970, accuracy: 1)
        // A due check during the backoff starts nothing and says why.
        XCTAssertNil(runner.tick(regimen: plan))
        XCTAssertTrue(runner.waitingReason?.contains("incomplete") == true)
        XCTAssertFalse(runner.waitingReason?.contains("was cleaned") == true)
        XCTAssertEqual(runner.nextRunDate?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(CleanRegimenRunner.partialRetryBackoff).timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(runner.lastSummary?.contains("incomplete") == true)
    }

    func testPartialDiscoveryBackoffExpiresAndACompleteRunClearsTheHold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HHPartialBackoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HHPartialBackoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date()
        var current = start
        let key = "hoghunter.cleaner.regimen.lastRunAt"
        let partialKey = "hoghunter.cleaner.regimen.lastPartialRunAt"
        let item = CleanItem(category: .userCaches, title: "Fixture", subtitle: "Fixture",
            url: root.appendingPathComponent("never-clean"), bytes: 4096, fileCount: 1,
            lastModified: nil, isSelected: true)
        let partialReport = CleanScanReport(categories: [CleanCategoryReport(category: .userCaches,
            items: [item], totalBytes: 4096, selectedBytes: 4096, itemCount: 1)], totalBytes: 4096,
            totalSelectedBytes: 4096, scannedAt: start, isPartial: true, incompleteCategories: [.logsAndDiagnostics])
        let fullReport = CleanScanReport(categories: [CleanCategoryReport(category: .userCaches,
            items: [item], totalBytes: 4096, selectedBytes: 4096, itemCount: 1)], totalBytes: 4096,
            totalSelectedBytes: 4096, scannedAt: start)
        var usePartial = true
        var plan = CleanRegimen(isEnabled: true, intervalHours: 4, avoidDuringBuilds: false,
            enabledRules: ["app-caches", "logs"])
        plan.createSnapshotBeforeClean = false
        let runner = CleanRegimenRunner(now: { current }, defaults: defaults,
            lockProvider: { HousekeeperLock(path: root.appendingPathComponent("lock")) },
            scanProvider: { _ in usePartial ? partialReport : fullReport },
            exclusionsProvider: { CleanerExclusions() }, cleanProvider: { _, _, _ in
                CleanResult(bytesReclaimed: 4096, itemsRemoved: 1, errors: [], cleanedAt: current)
            })
        // With no completed run on the clock at all, only the partial
        // backoff can hold the retry back.
        await runner.runNow(regimen: plan)?.value
        XCTAssertNotNil(defaults.object(forKey: partialKey))
        XCTAssertFalse(runner.isDue(regimen: plan, lastRunAt: nil))
        current = current.addingTimeInterval(CleanRegimenRunner.partialRetryBackoff + 61)
        XCTAssertTrue(runner.isDue(regimen: plan, lastRunAt: nil))
        // A complete scan records the run and clears the partial hold.
        usePartial = false
        await runner.runNow(regimen: plan)?.value
        XCTAssertNil(defaults.object(forKey: partialKey))
        XCTAssertEqual(defaults.object(forKey: key) as? Date, current)
    }

    func testPartialDiscoveryCancelledRunDoesNotClaimTheSubsetWasCleaned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HHPartialCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HHPartialCancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let item = CleanItem(category: .userCaches, title: "Fixture", subtitle: "Fixture",
            url: root.appendingPathComponent("never-clean"), bytes: 4096, fileCount: 1,
            lastModified: nil, isSelected: true)
        let partialReport = CleanScanReport(categories: [CleanCategoryReport(category: .userCaches,
            items: [item], totalBytes: 4096, selectedBytes: 4096, itemCount: 1)], totalBytes: 4096,
            totalSelectedBytes: 4096, scannedAt: now, isPartial: true, incompleteCategories: [.logsAndDiagnostics])
        var plan = CleanRegimen(isEnabled: true, intervalHours: 4, avoidDuringBuilds: false,
            enabledRules: ["app-caches", "logs"])
        plan.createSnapshotBeforeClean = false
        var cleanCalls = 0
        let entered = expectation(description: "clean provider entered")
        let release = CleanRelease()
        let runner = CleanRegimenRunner(now: { now }, defaults: defaults,
            lockProvider: { HousekeeperLock(path: root.appendingPathComponent("lock")) },
            scanProvider: { _ in partialReport },
            exclusionsProvider: { CleanerExclusions() }, cleanProvider: { _, _, _ in
                cleanCalls += 1
                entered.fulfill()
                // Hold the clean open until the test has cancelled the run,
                // so cancellation provably lands while cleaning is in flight.
                await release.wait()
                return CleanResult(bytesReclaimed: 4096, itemsRemoved: 1, errors: [], cleanedAt: now)
            })
        let task = runner.runNow(regimen: plan)
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(cleanCalls, 1, "the clean provider was actually entered before cancellation")
        task?.cancel()
        release.release()
        await task?.value
        XCTAssertTrue(runner.lastRun?.cancelled == true)
        XCTAssertTrue(runner.lastRun?.skippedReason?.contains("incomplete") == true)
        XCTAssertTrue(runner.lastRun?.skippedReason?.contains("cancelled") == true,
                      "a cancelled run says it was cancelled")
        XCTAssertFalse(runner.lastRun?.skippedReason?.contains("cleaned") == true,
                       "a cancelled run claims no clean at all")
    }

    func testPartialDiscoveryReportsActualCleanOutcome() async throws {
        // A partial run whose clean removes nothing and fails must record
        // exactly that, not a blanket "cleaned" claim.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HHPartialOutcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HHPartialOutcome-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let item = CleanItem(category: .userCaches, title: "Fixture", subtitle: "Fixture",
            url: root.appendingPathComponent("never-clean"), bytes: 4096, fileCount: 1,
            lastModified: nil, isSelected: true)
        let partialReport = CleanScanReport(categories: [CleanCategoryReport(category: .userCaches,
            items: [item], totalBytes: 4096, selectedBytes: 4096, itemCount: 1)], totalBytes: 4096,
            totalSelectedBytes: 4096, scannedAt: now, isPartial: true, incompleteCategories: [.logsAndDiagnostics])
        var plan = CleanRegimen(isEnabled: true, intervalHours: 4, avoidDuringBuilds: false,
            enabledRules: ["app-caches", "logs"])
        plan.createSnapshotBeforeClean = false
        let runner = CleanRegimenRunner(now: { now }, defaults: defaults,
            lockProvider: { HousekeeperLock(path: root.appendingPathComponent("lock")) },
            scanProvider: { _ in partialReport },
            exclusionsProvider: { CleanerExclusions() }, cleanProvider: { _, _, _ in
                CleanResult(bytesReclaimed: 0, itemsRemoved: 0, errors: ["boom"], cleanedAt: now)
            })
        await runner.runNow(regimen: plan)?.value
        XCTAssertTrue(runner.lastRun?.skippedReason?.contains("incomplete") == true)
        XCTAssertTrue(runner.lastRun?.skippedReason?.contains("cleaned 0 items with 1 error") == true,
                      "a zero-item, all-error clean is recorded as exactly that")
    }

    func testEnabledRulesRestrictDiscoveryCategories() {
        XCTAssertEqual(CleanRegimenRunner.scanCategories(for: ["logs"]), [.logsAndDiagnostics])
        XCTAssertEqual(CleanRegimenRunner.scanCategories(for: ["tmp-files"]), [.tempFiles])
        XCTAssertTrue(CleanRegimenRunner.scanCategories(for: []).isEmpty)
    }
}

/// A one-shot test-to-provider release:  the clean provider waits on it so
/// the test can cancel the run while a clean is provably in flight, then
/// let the provider return.  Lock-based so it is safe from either side's
/// executor.
private final class CleanRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if released { lock.unlock(); cont.resume() } else { waiters.append(cont); lock.unlock() }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
