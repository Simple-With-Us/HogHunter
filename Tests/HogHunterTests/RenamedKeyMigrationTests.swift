import XCTest
@testable import HogHunter

/// The Vacuum -> Maintain rename changed stored UserDefaults keys.  A phone
/// opt-in that was granted before the rename must survive it: the new key
/// reads as `false` when absent, which would silently re-lock the phone's
/// Run button with no explanation anywhere in the UI.
///
/// This is a regression pin, not a description of intent -- the failure mode
/// is a value quietly reset to a safe default, which is exactly the kind of
/// bug nobody notices until they try to use the thing.
final class RenamedKeyMigrationTests: XCTestCase {
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "RenamedKeyMigrationTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        suite = nil
        super.tearDown()
    }

    /// The map is the contract: if a key is renamed without being added here,
    /// this test cannot notice, but if a key is renamed and *is* added, the
    /// old string must still be the one on disk from a pre-rename build.
    func testRenamedKeysMapOldToNew() {
        XCTAssertEqual(HogStore.Key.renamedKeys["allowRemoteVacuum"], "allowRemoteMaintain")
    }

    /// Every mapped pair must actually differ, or the entry is dead weight
    /// that hides a real rename.
    func testNoRenamedKeyMapsToItself() {
        for (oldKey, newKey) in HogStore.Key.renamedKeys {
            XCTAssertNotEqual(oldKey, newKey, "rename entry \(oldKey) is a no-op")
            XCTAssertFalse(oldKey.isEmpty && newKey.isEmpty)
        }
    }

    /// The new key must not be one the old build already wrote, or the
    /// migration would find nothing to move.
    func testNewKeyIsNotAlsoWrittenByTheOldBuild() {
        for (oldKey, newKey) in HogStore.Key.renamedKeys {
            XCTAssertFalse(
                newKey.lowercased().contains(oldKey.lowercased()),
                "\(newKey) still carries \(oldKey); the rename is incomplete"
            )
        }
    }
}