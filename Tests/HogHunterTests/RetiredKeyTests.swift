import XCTest
@testable import HogHunter

/// A setting that no longer exists must not be left on disk.
///
/// The menu bar window is the only quick view now, so the attach/detach
/// preference is gone.  A stored value for it would be read by nobody, and it
/// would look like a saved setting the app had quietly forgotten.
final class RetiredKeyTests: XCTestCase {

    /// The key is on the retired list, so the loader knows to clear it.
    func testTheRetiredKeyIsListed() {
        XCTAssertTrue(HogStore.Key.retiredKeys.contains("dockedToMenuBar"))
    }

    /// A stored value for a retired key is cleared when the store loads, so
    /// it is not left behind for a build that will never read it.
    @MainActor
    func testAStoredRetiredKeyIsClearedOnLoad() throws {
        let suite = "RetiredKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "dockedToMenuBar")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let maintain = MaintainStore(supportDirectory: directory, repoRoot: directory) { _ in true }
        _ = HogStore(defaults: defaults, infisical: IsolatedInfisical.make(),
                     maintain: maintain, startImmediately: false)

        XCTAssertNil(defaults.object(forKey: "dockedToMenuBar"),
                     "a retired key must not be left on disk")
    }
}
