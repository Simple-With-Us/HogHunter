import XCTest
@testable import HogHunter

/// Owner 2026-10-03: the App Storage pane drew red outlines and a red triangle
/// with no explanation a person could see.  These pin the wording that now
/// appears in the row, because a guard that renders "flagged" with no reason is
/// the same defect as the one being fixed.
final class HiddenHeavyReasonTests: XCTestCase {

    private func usage(bundle: UInt64, hidden: UInt64) -> StorageUsage {
        StorageUsage(
            bundleId: "com.example.app",
            name: "Example",
            path: "/Applications/Example.app",
            isRunning: false,
            bundleBytes: bundle,
            hiddenBytes: hidden,
            slices: [],
            anyApproximate: false
        )
    }

    func testNoReasonWhenNotFlagged() {
        // 100 MB hidden against a 1 GB bundle: well under the 5x rule.
        XCTAssertNil(usage(bundle: 1_000_000_000, hidden: 100_000_000).hiddenHeavyReason)
    }

    func testReasonStatesTheRatioWhenBundleExists() {
        let u = usage(bundle: 100_000_000, hidden: 600_000_000)
        XCTAssertTrue(u.isHiddenHeavy)
        let reason = try? XCTUnwrap(u.hiddenHeavyReason)
        XCTAssertNotNil(reason)
        // Must carry the actual multiple, not just "it is flagged".
        XCTAssertTrue(reason?.contains("6.0") == true, "expected the 6x ratio in: \(reason ?? "nil")")
    }

    func testReasonHandlesMissingBundle() {
        // No bundle at all but a large hidden footprint is still flagged, and
        // the wording must not divide by zero or imply a ratio.
        let u = usage(bundle: 0, hidden: 300_000_000)
        XCTAssertTrue(u.isHiddenHeavy)
        let reason = u.hiddenHeavyReason
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("no .app bundle") == true, "got: \(reason ?? "nil")")
    }

    func testThresholdStillRequires200MB() {
        // 5x but tiny: not flagged, so no reason.  Pins the guard itself.
        let u = usage(bundle: 10_000_000, hidden: 60_000_000)
        XCTAssertFalse(u.isHiddenHeavy)
        XCTAssertNil(u.hiddenHeavyReason)
    }
}
