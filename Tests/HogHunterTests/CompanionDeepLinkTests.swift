import XCTest

/// The widget's Clean pill may open a confirmation.  It must not be able to
/// name a clean that runs on its own.
final class CompanionDeepLinkTests: XCTestCase {
    func testCleanLinkAsksForConfirmationOnly() {
        let link = CompanionDeepLink.classify(URL(string: "hoghunter://clean")!)
        XCTAssertEqual(link, .confirmClean)
        XCTAssertTrue(link.requestsCleanConfirmation)
    }

    func testOpenLinkDoesNotAskToClean() {
        let link = CompanionDeepLink.classify(URL(string: "hoghunter://open")!)
        XCTAssertEqual(link, .openApp)
        XCTAssertFalse(link.requestsCleanConfirmation)
    }

    func testOtherLinksAreIgnored() {
        XCTAssertEqual(CompanionDeepLink.classify(URL(string: "hoghunter://run")!), .ignore)
        XCTAssertEqual(CompanionDeepLink.classify(URL(string: "https://example.com/clean")!), .ignore)
        XCTAssertEqual(CompanionDeepLink.classify(URL(string: "hoghunter://clean")!).requestsCleanConfirmation, true)
        XCTAssertFalse(CompanionDeepLink.classify(URL(string: "HogHunter://OPEN")!).requestsCleanConfirmation)
        XCTAssertEqual(CompanionDeepLink.classify(URL(string: "HogHunter://CLEAN")!), .confirmClean)
    }

    func testCleanLinkDoesNotOfferConfirmationUnlessTheMacOptedIn() {
        XCTAssertTrue(CleanLinkPolicy.mayOfferCleanConfirmation(remoteCleanAllowed: true))
        XCTAssertFalse(CleanLinkPolicy.mayOfferCleanConfirmation(remoteCleanAllowed: false))
        XCTAssertFalse(CleanLinkPolicy.mayOfferCleanConfirmation(remoteCleanAllowed: nil))
    }

    func testWidgetReloadRequiresTheAppGroupContainer() {
        XCTAssertFalse(CleanLinkPolicy.shouldReloadWidget(
            appGroupContainerAvailable: false, snapshotEncoded: true, cleanKeysChanged: true, reloadDue: true))
        XCTAssertFalse(CleanLinkPolicy.shouldReloadWidget(
            appGroupContainerAvailable: true, snapshotEncoded: false, cleanKeysChanged: true, reloadDue: true))
        XCTAssertTrue(CleanLinkPolicy.shouldReloadWidget(
            appGroupContainerAvailable: true, snapshotEncoded: true, cleanKeysChanged: true, reloadDue: false))
        XCTAssertTrue(CleanLinkPolicy.shouldReloadWidget(
            appGroupContainerAvailable: true, snapshotEncoded: true, cleanKeysChanged: false, reloadDue: true))
        XCTAssertFalse(CleanLinkPolicy.shouldReloadWidget(
            appGroupContainerAvailable: true, snapshotEncoded: true, cleanKeysChanged: false, reloadDue: false))
    }

    func testCleanRequestExpiresAndClearsStaleFlags() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(CleanRequest.isFresh(pending: true, issuedAt: now.addingTimeInterval(-29), now: now))
        XCTAssertFalse(CleanRequest.isFresh(pending: true, issuedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(CleanRequest.isFresh(pending: false, issuedAt: now, now: now))
        XCTAssertFalse(CleanRequest.isFresh(pending: true, issuedAt: nil, now: now))
    }
}
