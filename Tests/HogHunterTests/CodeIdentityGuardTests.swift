import XCTest

/// macOS asks about a removable volume when an ad hoc Debug build runs from one,
/// and the answer does not survive the next build.  See
/// docs/rollouts/2026-11-04-tcc-prompts-and-code-identity.md.
final class CodeIdentityGuardTests: XCTestCase {
    func testTheTestHostDoesNotRunFromAnExternalVolume() {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        XCTAssertFalse(path.hasPrefix("/Volumes/"),
                       "The test host ran from \(path), which raises a permission prompt on every build.  Run xcodegen generate and drop any -derivedDataPath on an external volume.")
    }
}
