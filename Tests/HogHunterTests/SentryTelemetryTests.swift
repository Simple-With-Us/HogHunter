import XCTest

@testable import HogHunter

/// Covers the testable half of `SentryTelemetry`: DSN gating, the release
/// string, URL redaction, and the CI-hook skip list.  `start()` itself is
/// deliberately untested -- it boots the real SDK, which must never run
/// under XCTest.
final class SentryTelemetryTests: XCTestCase {

    /// A throwaway bundle directory whose Info.plist carries the given keys.
    private func bundle(info: [String: Any]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryTelemetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        guard let bundle = Bundle(path: dir.path) else {
            throw NSError(domain: "SentryTelemetryTests", code: 1)
        }
        return bundle
    }

    func testMissingDSNIsANoOp() throws {
        XCTAssertNil(SentryTelemetry.configuration(bundle: try bundle(info: [:])))
    }

    func testEmptyDSNIsANoOp() throws {
        XCTAssertNil(SentryTelemetry.configuration(bundle: try bundle(info: ["SentryDSN": ""])))
    }

    func testUnexpandedBuildSettingIsANoOp() throws {
        XCTAssertNil(SentryTelemetry.configuration(
            bundle: try bundle(info: ["SentryDSN": "$(SENTRY_DSN)"])))
    }

    func testNonHTTPSDSNIsANoOp() throws {
        XCTAssertNil(SentryTelemetry.configuration(
            bundle: try bundle(info: ["SentryDSN": "http://public@example.test/1"])))
    }

    func testValidDSNBuildsConfiguration() throws {
        let dsn = "https://public@example.test/1"
        let bundle = try bundle(info: [
            "SentryDSN": "  \(dsn)  ",
            "CFBundleShortVersionString": "1.0.6",
            "CFBundleVersion": "202610060122",
        ])
        let config = try XCTUnwrap(SentryTelemetry.configuration(bundle: bundle))
        XCTAssertEqual(config.dsn, dsn)
        XCTAssertEqual(config.release, "1.0.6+202610060122")
        XCTAssertEqual(config.environment, "production")
        XCTAssertEqual(config.tracesSampleRate, 0.2, accuracy: 0.0001)
        XCTAssertEqual(config.profilesSessionSampleRate, 0.1, accuracy: 0.0001)
    }

    func testReleaseFallsBackWhenVersionKeysAreMissing() throws {
        XCTAssertEqual(SentryTelemetry.releaseName(bundle: try bundle(info: [:])), "0+0")
    }

    func testSmokeAndScreenshotFlagsKeepSentryOff() {
        XCTAssertFalse(SentryTelemetry.shouldStart(arguments: ["HogHunter", "-HogHunterUISmoke"]))
        XCTAssertFalse(SentryTelemetry.shouldStart(arguments: ["HogHunter", "-HogHunterScreenshot"]))
        XCTAssertTrue(SentryTelemetry.shouldStart(arguments: ["HogHunter"]))
    }

    func testRedactSensitiveURLStripsPairingSecrets() {
        let raw = "http://mac.local:8787/v1/snapshot?token=hh1_secret&other=ok&password=x"
        let redacted = SentryTelemetry.redactSensitiveURL(raw)
        XCTAssertFalse(redacted.contains("hh1_secret"))
        XCTAssertFalse(redacted.contains("password=x"))
        XCTAssertTrue(redacted.contains("token=[REDACTED]"))
        XCTAssertTrue(redacted.contains("password=[REDACTED]"))
        XCTAssertTrue(redacted.contains("other=ok"))
    }
}
