import XCTest
@testable import HogHunter

/// Covers the parts of the server snapshot that describe what the server is
/// doing right now: the processes it is running, the Coolify workloads it
/// runs them for, and the tool states with their reasons.
final class VPSActivityTests: XCTestCase {
    private let sampleJSON = """
    {
      "generated_at": "2026-10-26T17:10:37Z",
      "host": "fleet-hetzner-nbg1",
      "devices": {
        "root": {"mount": "/", "free_bytes": 71433809920}
      },
      "cpu": {"pct": 18.3, "load1": 5.25, "cores": 16, "source": "proc-stat tick delta 1s"},
      "memory": {"total_bytes": 32853925888, "used_bytes": 19687982080, "available_bytes": 13165943808},
      "swap": {"total_bytes": 35554012160, "used_bytes": 21024030720, "free_bytes": 14529981440},
      "tool_statuses": [
        {"id": "claude", "name": "Claude Code", "state": "unknown", "count": 0,
         "reason": "runs under an interpreter; not provable from process identity"},
        {"id": "minimax", "name": "MiniMax Code", "state": "running", "count": 1, "reason": "1 process"},
        {"id": "recall", "name": "Fleet Recall", "state": "running", "count": 1, "reason": "1 container"}
      ],
      "processes": [
        {"pid": 1535073, "name": "next-server", "start_time": 197114309, "owner": "root",
         "container": "yagelvqux9e8l1kztif7bf2o", "cpu_percent": 125.39, "memory_bytes": 1186484715},
        {"pid": 4242, "name": "claude", "start_time": 99887766, "owner": "jay",
         "container": null, "cpu_percent": 3.5, "memory_bytes": null}
      ],
      "coolify": [
        {"uuid": "yagelvqux9e8l1kztif7bf2o", "name": "fleet-infra / um-appworker", "type": "application",
         "status": "running", "cpu_percent": 0.72, "memory_bytes": 566860185,
         "image": "yagelvqux9e8l1kztif7bf2o:5cbd", "started_at": "2026-10-26T06:11:38Z"},
        {"uuid": "qdrant-ookh0qmlgrbxlwbbe6lolx6g", "name": "trading-analytics-fleet / qdrant-st",
         "type": "service", "status": "unhealthy", "cpu_percent": 158.34, "memory_bytes": 3826815860,
         "image": "qdrant/qdrant:v1.19.0", "started_at": "2026-10-03T00:00:00Z"}
      ]
    }
    """.data(using: .utf8)!

    private func decode() throws -> VPSStatusSnapshot {
        try JSONDecoder().decode(VPSStatusSnapshot.self, from: sampleJSON)
    }

    func testProcessListDecodesWithIdentityAndOwners() throws {
        let snapshot = try decode()
        let processes = try XCTUnwrap(snapshot.processes)
        XCTAssertEqual(processes.count, 2)

        let server = processes[0]
        XCTAssertEqual(server.pid, 1535073)
        XCTAssertEqual(server.name, "next-server")
        XCTAssertEqual(server.startTime, 197114309)
        XCTAssertEqual(server.owner, "root")
        XCTAssertEqual(server.container, "yagelvqux9e8l1kztif7bf2o")
        XCTAssertEqual(server.cpuPercent, 125.39)
        XCTAssertEqual(server.memoryBytes, 1186484715)
        // A workload the process belongs to is the group the owner thinks in.
        XCTAssertEqual(server.group, "yagelvqux9e8l1kztif7bf2o")

        let seat = processes[1]
        XCTAssertNil(seat.container)
        XCTAssertEqual(seat.group, "jay")
        XCTAssertNil(seat.memoryBytes)
    }

    func testCoolifyResourcesDecodeWithTheirHealth() throws {
        let snapshot = try decode()
        let workloads = try XCTUnwrap(snapshot.coolify)
        XCTAssertEqual(workloads.count, 2)

        let healthy = workloads[0]
        XCTAssertEqual(healthy.name, "fleet-infra / um-appworker")
        XCTAssertEqual(healthy.type, "application")
        XCTAssertTrue(healthy.isHealthy)
        XCTAssertEqual(healthy.cpuPercent, 0.72)
        XCTAssertEqual(healthy.memoryBytes, 566860185)

        let unhealthy = workloads[1]
        XCTAssertEqual(unhealthy.type, "service")
        XCTAssertFalse(unhealthy.isHealthy)
    }

    func testToolStatesCarryTheirReason() throws {
        let snapshot = try decode()
        let tools = try XCTUnwrap(snapshot.toolStatuses)
        XCTAssertEqual(tools.count, 3)

        let unknown = tools[0]
        XCTAssertEqual(unknown.state, .unknown)
        // An unknown state without a reason is a dot nobody can act on.
        XCTAssertEqual(unknown.reason, "runs under an interpreter; not provable from process identity")

        XCTAssertEqual(tools[1].state, .running)
        XCTAssertEqual(tools[1].count, 1)
        XCTAssertEqual(tools[2].reason, "1 container")
    }

    func testASnapshotWithoutTheNewSectionsStillDecodes() throws {
        /// An older server snapshot carries none of the new readings, and the
        /// app must keep working against it.
        let oldJSON = """
        {"generated_at": "2026-10-18T19:15:03Z", "host": "fleet-hetzner-nbg1", "devices": {}}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: oldJSON)
        XCTAssertNil(snapshot.processes)
        XCTAssertNil(snapshot.coolify)
        XCTAssertNil(snapshot.toolStatuses)
    }
}
