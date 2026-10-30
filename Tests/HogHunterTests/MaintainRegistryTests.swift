import XCTest
@testable import HogHunter

final class MaintainRegistryTests: XCTestCase {
    private func entry(_ id: String, path: String = "/repo/scripts/maintain.py") -> MaintainScriptEntry {
        MaintainScriptEntry(id: id, path: path, mode: "owned", scope: "local", owner: id, argv: nil)
    }

    func testSchedulerAndManualEntryAppearOnceWithoutChangingCustomEntries() {
        let scheduler = entry("maintain_scheduler")
        let manual = entry("maintain_cli")
        let custom = entry("custom")
        let rows = MaintainRegistryStore.presentationEntries([scheduler, manual, custom])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].displayName, "Hog Hunter Maintenance")
        XCTAssertTrue(rows[0].owner.contains("launchd"))
        XCTAssertTrue(rows[0].owner.contains("CLI"))
        XCTAssertEqual(rows[1], custom)
        XCTAssertEqual(scheduler.id, "maintain_scheduler")
        XCTAssertEqual(manual.id, "maintain_cli")
    }

    func testDifferentPathsOrClassificationsRemainSeparate() {
        let scheduled = entry("maintain_scheduler")
        let movedManual = entry("maintain_cli", path: "/other/maintain.py")
        XCTAssertEqual(MaintainRegistryStore.presentationEntries([scheduled, movedManual]).count, 2)
        var observed = entry("maintain_cli")
        observed.mode = "observed"
        XCTAssertEqual(MaintainRegistryStore.presentationEntries([scheduled, observed]).count, 2)
    }
}
