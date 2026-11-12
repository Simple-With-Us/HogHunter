import XCTest
@testable import HogHunter

final class CpuMinuteHistoryTests: XCTestCase {
    func testMinuteMeansDoNotDependOnRefreshInterval() {
        var history = CpuMinuteHistory()
        let start = Date(timeIntervalSince1970: 1_800_000)
        history.record(percent: 20, at: start)
        history.record(percent: 80, at: start.addingTimeInterval(15))
        history.record(percent: 90, at: start.addingTimeInterval(60))
        let bars = history.bars(at: start.addingTimeInterval(60))
        XCTAssertEqual(bars.count, 30)
        XCTAssertEqual(bars[28], 50)
        XCTAssertEqual(bars[29], 90)
        XCTAssertNil(bars[27])
    }

    func testGapsAndOldDataDoNotPretendToBeRecent() {
        var history = CpuMinuteHistory()
        let start = Date(timeIntervalSince1970: 1_800_000)
        history.record(percent: 30, at: start)
        history.record(percent: .nan, at: start.addingTimeInterval(60))
        history.record(percent: 60, at: start.addingTimeInterval(120))
        history.record(percent: 100, at: start.addingTimeInterval(-60))
        let bars = history.bars(at: start.addingTimeInterval(120))
        XCTAssertEqual(bars[27], 30)
        XCTAssertNil(bars[28])
        XCTAssertEqual(bars[29], 60)
        XCTAssertTrue(history.bars(at: start.addingTimeInterval(3600)).allSatisfy { $0 == nil })
    }
}
