import XCTest
@testable import HogHunter

final class VPSSizeGrowthTests: XCTestCase {
    func testLegacySnapshotLeavesToolsAbsent() throws {
        let data = Data(#"{"generated_at":"2026-01-01T00:00:00Z","host":"fixture","devices":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(VPSStatusSnapshot.self, from: data).toolStatuses)
    }

    func testToolStatesDecodeAndRoundTrip() throws {
        let data = Data(#"{"generated_at":"2026-01-01T00:00:00Z","host":"fixture","devices":{},"tool_statuses":[{"id":"codex","name":"Codex","state":"running","count":2},{"id":"muse","name":"Muse","state":"unknown","count":0}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: data)
        XCTAssertEqual(snapshot.toolStatuses?.first?.state, .running)
        XCTAssertEqual(snapshot.toolStatuses?.first?.count, 2)
        XCTAssertEqual(snapshot.toolStatuses?.last?.state, .unknown)
        XCTAssertEqual(try JSONDecoder().decode(VPSStatusSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    @MainActor
    func testHistoryUsesSourceTimestampAndHostScope() async throws {
        let now = Date()
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        let snapshot = VPSStatusSnapshot(generatedAt: ISO8601DateFormatter().string(from: now),
                                         host: "server", devices: [:], appDbs: ["app": 150],
                                         largestDirs: [VPSDirectory(path: "/fixture/Code", bytes: 200)],
                                         databaseSamples: [VPSSizeSample(path: "app", bytes: 100, sampledAt: now.addingTimeInterval(-86_400).timeIntervalSince1970)],
                                         directorySamples: [VPSSizeSample(path: "/fixture/Code", bytes: 100, sampledAt: now.addingTimeInterval(-86_400).timeIntervalSince1970)])
        let store = VPSStatusStore(initialHost: "fixture", fetcher: { _ in snapshot }, history: history)
        store.fetch(force: true)
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.databasePercentChange(key: "app"), 50)
        XCTAssertEqual(store.directoryPercentChange(path: "/fixture/Code"), 100)
        XCTAssertNil(history.latest(host: "other|server", metric: "database", path: "app"))
        XCTAssertEqual(history.latest(host: "fixture|server", metric: "database", path: "app")?.sampledAt,
                       snapshot.generatedAtDate)
    }
}
