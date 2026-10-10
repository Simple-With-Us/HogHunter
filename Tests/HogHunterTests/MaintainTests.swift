import XCTest
@testable import HogHunter

final class MaintainTests: XCTestCase {
    func testDecodeStatus() throws {
        let json = """
        {
          "health": "healthy",
          "launchd_loaded": true,
          "next_run_at": { "full": 2000.0 },
          "last_runs": { "full": 1100.0, "watch": 1050.0 },
          "intervals_seconds": { "full": 14400 },
          "last_run": {
            "run_id": "abc",
            "trigger": "full",
            "started_at": 1000,
            "ended_at": 1100,
            "bytes_freed": 1024,
            "exit_code": 0,
            "steps": []
          },
          "step_last_results": {},
          "history_count": 1
        }
        """.data(using: .utf8)!
        let status = try JSONDecoder().decode(MaintainStatus.self, from: json)
        XCTAssertEqual(status.health, "healthy")
        XCTAssertEqual(status.displayHealth, "On schedule")
        XCTAssertTrue(status.launchdLoaded)
        XCTAssertEqual(status.lastRunAt?["full"], 1100.0)
    }
}
