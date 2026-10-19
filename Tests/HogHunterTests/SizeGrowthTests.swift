import XCTest
@testable import HogHunter

final class SizeGrowthTests: XCTestCase {
    func testUsesDayBaselineAndIsolatesHostsAndSourceTimestamps() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        XCTAssertTrue(history.record(host: "a", metric: "db", path: "/db", bytes: 100, sampledAt: now.addingTimeInterval(-86400)))
        XCTAssertTrue(history.record(host: "b", metric: "db", path: "/db", bytes: 900, sampledAt: now.addingTimeInterval(-86400)))
        XCTAssertTrue(history.record(host: "a", metric: "db", path: "/db", bytes: 108, sampledAt: now))
        XCTAssertEqual(history.percentChange(host: "a", metric: "db", path: "/db")!, 8, accuracy: 0.001)
        XCTAssertNil(history.percentChange(host: "b", metric: "db", path: "/db"))
        XCTAssertFalse(history.record(host: "a", metric: "db", path: "/db", bytes: 999, sampledAt: now))
        XCTAssertFalse(history.record(host: "a", metric: "db", path: "/db", bytes: 999, sampledAt: now.addingTimeInterval(-60)))
        XCTAssertEqual(history.latest(host: "a", metric: "db", path: "/db")?.bytes, 108)
    }

    func testMissingShortAndZeroBaselinesStayUnknown() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        history.record(host: "a", metric: "size", path: "short", bytes: 100, sampledAt: now.addingTimeInterval(-3600))
        history.record(host: "a", metric: "size", path: "short", bytes: 200, sampledAt: now)
        history.record(host: "a", metric: "size", path: "zero", bytes: 0, sampledAt: now.addingTimeInterval(-86400))
        history.record(host: "a", metric: "size", path: "zero", bytes: 200, sampledAt: now)
        XCTAssertNil(history.percentChange(host: "a", metric: "size", path: "short"))
        XCTAssertNil(history.percentChange(host: "a", metric: "size", path: "zero"))
        XCTAssertNil(history.percentChange(host: "a", metric: "size", path: "missing"))
    }

    func testPersistencePrunesOldSamplesAndRejectsInvalidRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: url, now: { now })
        XCTAssertFalse(history.record(host: "a", metric: "size", path: "p", bytes: 8, sampledAt: now.addingTimeInterval(-49 * 3600)))
        history.record(host: "a", metric: "size", path: "p", bytes: 80, sampledAt: now)
        XCTAssertFalse(history.record(host: "a", metric: "size", path: "p", bytes: -1, sampledAt: now.addingTimeInterval(1)))
        XCTAssertEqual(SizeGrowthHistory(fileURL: url, now: { now }).latest(host: "a", metric: "size", path: "p")?.bytes, 80)
        XCTAssertNil(SizeGrowthHistory(fileURL: url, now: { now.addingTimeInterval(49 * 3600) }).latest(host: "a", metric: "size", path: "p"))
    }

    func testStaleAndDistantBaselinesDoNotProduceDelta() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        history.record(host: "a", metric: "size", path: "distant", bytes: 100, sampledAt: now.addingTimeInterval(-22 * 3600))
        history.record(host: "a", metric: "size", path: "distant", bytes: 120, sampledAt: now)
        history.record(host: "a", metric: "size", path: "stale", bytes: 100, sampledAt: now.addingTimeInterval(-26 * 3600))
        history.record(host: "a", metric: "size", path: "stale", bytes: 120, sampledAt: now.addingTimeInterval(-2 * 3600))
        XCTAssertNil(history.percentChange(host: "a", metric: "size", path: "distant"))
        XCTAssertNil(history.percentChange(host: "a", metric: "size", path: "stale"))
    }

    func testDefaultPersistenceIsDisabledUnderXCTest() {
        XCTAssertNil(SizeGrowthHistory.defaultURL)
        XCTAssertTrue(SizeGrowthHistory.shared === SizeGrowthHistory.shared)
    }

    func testPersistenceRetainsDifferentHostsAndMetrics() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: url, now: { now })
        history.record(host: "mac", metric: "directory", path: "/code", bytes: 123, sampledAt: now)
        history.record(host: "remote", metric: "database", path: "/db", bytes: 456, sampledAt: now)
        let restored = SizeGrowthHistory(fileURL: url, now: { now })
        XCTAssertEqual(restored.latest(host: "mac", metric: "directory", path: "/code")?.bytes, 123)
        XCTAssertEqual(restored.latest(host: "remote", metric: "database", path: "/db")?.bytes, 456)
    }

    func testBatchBackfillsDayBaselineWithoutReplacingLatestAndIsIdempotent() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        history.record(host: "remote", metric: "db", path: "/db", bytes: 120, sampledAt: now)
        XCTAssertNil(history.percentChange(host: "remote", metric: "db", path: "/db"))
        let baselineTime = now.addingTimeInterval(-86400)
        let samples = [SizeGrowthSample(bytes: 100, sampledAt: baselineTime),
                       SizeGrowthSample(bytes: 999, sampledAt: now),
                       SizeGrowthSample(bytes: 90, sampledAt: baselineTime.addingTimeInterval(-1)),
                       SizeGrowthSample(bytes: -1, sampledAt: now.addingTimeInterval(1))]
        XCTAssertTrue(history.importSamples(host: "remote", metric: "db", path: "/db", samples: samples))
        XCTAssertEqual(history.latest(host: "remote", metric: "db", path: "/db")?.bytes, 120)
        XCTAssertEqual(history.percentChange(host: "remote", metric: "db", path: "/db")!, 20, accuracy: 0.001)
        XCTAssertFalse(history.importSamples(host: "remote", metric: "db", path: "/db", samples: samples))
        XCTAssertNil(history.latest(host: "other", metric: "db", path: "/db"))
        XCTAssertTrue(history.importSamples(host: "other", metric: "db", path: "/db", samples: [SizeGrowthSample(bytes: 700, sampledAt: now)]))
        XCTAssertEqual(history.latest(host: "remote", metric: "db", path: "/db")?.bytes, 120)
    }

    func testGrowthFormatting() {
        XCTAssertEqual(SizeGrowthFormat.delta(8.4), "↑8%")
        XCTAssertEqual(SizeGrowthFormat.delta(-8.4), "↓-8%")
        XCTAssertEqual(SizeGrowthFormat.delta(0.8), "↑0.8%")
        XCTAssertEqual(SizeGrowthFormat.delta(0.99), "↑1%")
        XCTAssertEqual(SizeGrowthFormat.delta(-0.99), "↓-1%")
        XCTAssertEqual(SizeGrowthFormat.delta(9.9), "↑10%")
        XCTAssertEqual(SizeGrowthFormat.delta(12), "↑12%")
        XCTAssertEqual(SizeGrowthFormat.delta(123), "↑120%")
        XCTAssertEqual(SizeGrowthFormat.delta(-0.09), "~0%")
        XCTAssertNil(SizeGrowthFormat.delta(nil))
    }

    @MainActor
    func testFailedDirectoryReadPreservesSizeAndMarksUnavailable() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        history.record(host: "test", metric: "directory", path: "/example", bytes: 123, sampledAt: now)
        let store = DirectoryUsageStore(history: history, candidates: [("Example", "/example")], host: "test", now: { now }, probe: { _ in nil })
        await store.refreshIfNeeded()
        XCTAssertEqual(store.rows.first?.bytes, 123)
        XCTAssertEqual(store.rows.first?.isUnavailable, true)
        XCTAssertNil(store.rows.first?.percentChange)
    }
}
