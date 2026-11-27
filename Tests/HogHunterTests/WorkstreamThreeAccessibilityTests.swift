import XCTest
@testable import HogHunter

/// Workstream 3: VoiceOver labels, Title Case badges and regimen history.
/// Pure helpers only, so these run without a sampler, a store or a disk scan.
final class WorkstreamThreeAccessibilityTests: XCTestCase {

    func testHogRowLabelCarriesNumbersAndStates() {
        let label = HogRowAccessibility.label(
            name: "Xcode", detail: "Developer Tools", cpuText: "120%", memoryText: "2.0 GB",
            isTamed: true, isSleepBlocker: true, quitBlockReason: "System process")
        XCTAssertTrue(label.contains("Xcode"), label)
        XCTAssertTrue(label.contains("CPU 120%"), label)
        XCTAssertTrue(label.contains("Memory 2.0 GB"), label)
        XCTAssertTrue(label.contains("Tamed"), label)
        XCTAssertTrue(label.contains("Keeping the Mac awake"), label)
        XCTAssertTrue(label.contains("Quit is unavailable: System process"), label)
    }

    func testHogRowLabelOmitsAbsentStates() {
        let label = HogRowAccessibility.label(
            name: "Safari", detail: "", cpuText: "3%", memoryText: "400 MB",
            isTamed: false, isSleepBlocker: false, quitBlockReason: nil)
        XCTAssertFalse(label.contains("Tamed"), label)
        XCTAssertFalse(label.contains("Quit is unavailable"), label)
        XCTAssertFalse(label.contains(", ,"), label)
    }

    func testStorageRowLabelNamesRunningAndFlagged() {
        let usage = StorageUsage(
            bundleId: "com.example.App", name: "Example", path: nil, isRunning: true,
            bundleBytes: 100_000_000, hiddenBytes: 600_000_000, slices: [], anyApproximate: false)
        let view = StorageRowView(usage: usage, isExpanded: false, onToggle: {})
        XCTAssertTrue(view.accessibilityLabel.contains("running now"), view.accessibilityLabel)
        XCTAssertTrue(view.accessibilityLabel.contains("flagged"), view.accessibilityLabel)
    }

    func testRegimenHistoryIsNewestFirstAndCapped() {
        let runs = (0..<12).map { RegimenRun(startedAt: Date(timeIntervalSince1970: Double($0))) }
        var history: [RegimenRun] = []
        for run in runs { history = CleanRegimenRunner.cappedHistory(run, into: history) }
        XCTAssertEqual(history.count, CleanRegimenRunner.recentRunsCap)
        XCTAssertEqual(history.first?.startedAt, runs.last?.startedAt)
    }

    func testTitleCaseBadges() {
        XCTAssertEqual(CleanTier.standard.badge, "Reversible")
        XCTAssertEqual(CleanTier.extreme.badge, "Review First")
        for priority in FlaggedPriority.allCases {
            let first = priority.badgeText.split(separator: " ").last.map(String.init) ?? ""
            XCTAssertEqual(first.first?.isUppercase, true, priority.badgeText)
        }
    }
}
