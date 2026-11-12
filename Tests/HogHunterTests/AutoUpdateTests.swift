import XCTest

@testable import HogHunter

/// The gate in front of Sparkle.  A build that fails it must never start the
/// updater, because Sparkle answers a missing feed or key with a modal alert
/// at launch — the wrong thing for a development build to show.
final class AutoUpdateAvailabilityTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Users/someone/Applications/Hog Hunter.app")
    private let feed = "https://github.com/Simple-With-Us/HogHunter/releases/latest/download/appcast.xml"
    // 32 zero bytes, base64: the right shape for an EdDSA public key.
    private let key = Data(count: 32).base64EncodedString()

    private func evaluate(_ info: [String: Any]?, bundle: URL? = nil) -> AutoUpdateAvailability {
        AutoUpdateAvailability.evaluate(info: info, bundleURL: bundle ?? appURL)
    }

    func testReleaseBuildWithFeedAndKeyIsEnabled() {
        let result = evaluate(["SUFeedURL": feed, "SUPublicEDKey": key])
        XCTAssertEqual(result, .enabled(feed: URL(string: feed)!))
        XCTAssertTrue(result.isEnabled)
        XCTAssertEqual(result.summary, "On")
    }

    func testSurroundingWhitespaceIsIgnored() {
        let result = evaluate(["SUFeedURL": "  \(feed)\n", "SUPublicEDKey": " \(key) "])
        XCTAssertEqual(result, .enabled(feed: URL(string: feed)!))
    }

    func testSwiftRunOrTestHostIsDisabled() {
        let binary = URL(fileURLWithPath: "/tmp/checkout/.build/debug/HogHunter")
        let result = evaluate(["SUFeedURL": feed, "SUPublicEDKey": key], bundle: binary)
        XCTAssertFalse(result.isEnabled)
    }

    func testDevBuildWithoutFeedIsDisabled() {
        XCTAssertEqual(evaluate(["SUPublicEDKey": key]),
                       .disabled(reason: "This build has no update feed."))
        XCTAssertEqual(evaluate(nil),
                       .disabled(reason: "This build has no update feed."))
        XCTAssertFalse(evaluate(["SUFeedURL": "", "SUPublicEDKey": key]).isEnabled)
    }

    func testMissingOrMalformedKeyIsDisabled() {
        let expected = AutoUpdateAvailability.disabled(reason: "This build has no update signing key.")
        XCTAssertEqual(evaluate(["SUFeedURL": feed]), expected)
        XCTAssertEqual(evaluate(["SUFeedURL": feed, "SUPublicEDKey": "not base64"]), expected)
        XCTAssertEqual(evaluate(["SUFeedURL": feed, "SUPublicEDKey": Data(count: 16).base64EncodedString()]), expected)
    }

    func testPlainHTTPIsAllowedOnlyForThisMac() {
        XCTAssertEqual(evaluate(["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]),
                       .disabled(reason: "The update feed is not HTTPS."))
        XCTAssertTrue(evaluate(["SUFeedURL": "http://127.0.0.1:8765/appcast.xml", "SUPublicEDKey": key]).isEnabled)
        XCTAssertTrue(evaluate(["SUFeedURL": "http://localhost:8765/appcast.xml", "SUPublicEDKey": key]).isEnabled)
    }

    func testDisabledSummaryCarriesTheReason() {
        XCTAssertEqual(AutoUpdateAvailability.disabled(reason: "This build has no update feed.").summary,
                       "Off · This build has no update feed.")
    }
}
