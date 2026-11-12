import XCTest
@testable import HogHunter

final class SnapshotProgressTests: XCTestCase {
    func testBothSnapshotMilestonesAreRecognized() {
        XCTAssertTrue(DiskCleaner.isSnapshotProgress("Saving a safety copy…"))
        XCTAssertTrue(DiskCleaner.isSnapshotProgress(DiskCleaner.thinningSnapshotsProgressTitle))
        XCTAssertFalse(DiskCleaner.isSafetyCopyProgress(DiskCleaner.thinningSnapshotsProgressTitle))
    }

    func testFileNamesContainingSnapshotAreNotMilestones() {
        XCTAssertFalse(DiskCleaner.isSnapshotProgress("snapshot.png"))
        XCTAssertFalse(DiskCleaner.isSnapshotProgress("my local snapshots backup.zip"))
        XCTAssertFalse(DiskCleaner.isSnapshotProgress("Thinning APFS local snapshots….txt"))
    }
}
