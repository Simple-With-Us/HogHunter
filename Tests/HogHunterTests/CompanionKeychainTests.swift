import XCTest

/// The phone's pairing token lives in the Keychain, namespaced per Mac by
/// peer ID, never in UserDefaults.  The helper takes a `service` suffix so a
/// test run stores under `…keychain.tests`, never beside a real token.
final class CompanionKeychainTests: XCTestCase {
    private let service = "tests"
    private let peerID = "test-peer-\(UUID().uuidString)"

    override func tearDown() {
        CompanionKeychain.deleteToken(peerID: peerID, service: service)
        super.tearDown()
    }

    func testRoundTrip() {
        XCTAssertTrue(CompanionKeychain.writeToken("hh1_test", peerID: peerID, service: service))
        XCTAssertEqual(CompanionKeychain.readToken(peerID: peerID, service: service), "hh1_test")
    }

    func testUpdateOverwrites() {
        XCTAssertTrue(CompanionKeychain.writeToken("hh1_old", peerID: peerID, service: service))
        XCTAssertTrue(CompanionKeychain.writeToken("hh1_new", peerID: peerID, service: service))
        XCTAssertEqual(CompanionKeychain.readToken(peerID: peerID, service: service), "hh1_new")
    }

    func testDeleteRemoves() {
        XCTAssertTrue(CompanionKeychain.writeToken("hh1_gone", peerID: peerID, service: service))
        CompanionKeychain.deleteToken(peerID: peerID, service: service)
        XCTAssertNil(CompanionKeychain.readToken(peerID: peerID, service: service))
    }

    func testUnknownPeerReadsNil() {
        XCTAssertNil(CompanionKeychain.readToken(peerID: "no-such-peer", service: service))
    }

    /// Test data must never land under the production service.  The base
    /// service ends `…keychain`; the test suffix rides after it, so a read
    /// without the suffix (the app's shape) finds nothing.
    func testNamespacedAwayFromProductionService() {
        XCTAssertTrue(CompanionKeychain.writeToken("hh1_test", peerID: peerID, service: service))
        XCTAssertNil(CompanionKeychain.readToken(peerID: peerID))
    }

    /// Peer IDs namespace entries: one Mac's token never answers another's.
    func testPeerIDsAreIsolated() {
        XCTAssertTrue(CompanionKeychain.writeToken("hh1_mine", peerID: peerID, service: service))
        XCTAssertNil(CompanionKeychain.readToken(peerID: "another-peer", service: service))
    }
}
