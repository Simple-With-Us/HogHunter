import Combine
import XCTest
@testable import HogHunter

@MainActor
final class DiskCleanerStoreScanAuthorityTests: XCTestCase {
    func testLeavingViewDiscardsProvisionalReportBeforeSelectAllAndClean() async throws {
        let suite = "hh202-provisional-cancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = CleanItem(category: .userCaches, title: "Provisional", subtitle: "Fixture",
            url: URL(fileURLWithPath: "/fixture/never-clean"), bytes: 4096, fileCount: 1,
            lastModified: nil, isSelected: true, isExternal: false, volumeName: "Fixture", isSymlink: false)
        let report = CleanScanReport(categories: [CleanCategoryReport(category: .userCaches,
            items: [item], totalBytes: 4096, selectedBytes: 4096, itemCount: 1)],
            totalBytes: 4096, totalSelectedBytes: 4096, scannedAt: Date(), isPartial: true)
        let published = expectation(description: "provisional report published")
        let hold = AsyncStream<Void> { _ in }
        let cleaner = DiskCleaner(freeBytesProvider: { XCTFail("A cancelled scan cannot start cleaning"); return nil },
            moveToTrash: { _ in XCTFail("No filesystem mutation is permitted") },
            makeSnapshot: { XCTFail("No snapshot is permitted"); return (false, nil) })
        let store = DiskCleanerStore(cleaner: cleaner, historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults, manualScanOnly: true, scanOperation: { _, _, _, partial, _ in
                partial(report)
                for await _ in hold { break }
                return report
            })
        let observer = store.$report.compactMap { $0 }.first().sink { _ in published.fulfill() }
        defer { observer.cancel(); store.cancelAll() }
        store.scan()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertNotNil(store.report)
        store.selectAll()
        XCTAssertFalse(store.selectedItemIds.isEmpty)
        store.showConfirmation = true

        // DiskCleanerView.onDisappear calls this same cancellation path.
        store.cancelScan()
        XCTAssertNil(store.report)
        XCTAssertTrue(store.selectedItemIds.isEmpty)
        XCTAssertFalse(store.showConfirmation)
        store.selectAll()
        store.cleanSelected()
        XCTAssertEqual(store.state, .idle)
        XCTAssertFalse(store.isCleaning)
        XCTAssertTrue(store.selectedItemIds.isEmpty)
        await Task.yield()
        XCTAssertNil(store.report, "A late callback cannot restore provisional authority")
    }
}
