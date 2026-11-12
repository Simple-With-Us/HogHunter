import XCTest

@testable import HogHunter

final class CompanionServerTests: XCTestCase {
    func testServiceNameLeavesShortASCIIUnchanged() {
        let host = String(repeating: "a", count: 63)
        XCTAssertEqual(CompanionServer.serviceName(from: host), host)
    }

    func testServiceNameTruncatesLongASCIITo63Bytes() {
        let host = String(repeating: "a", count: 100)
        let result = CompanionServer.serviceName(from: host)
        XCTAssertEqual(result.utf8.count, 63)
        XCTAssertEqual(result, String(repeating: "a", count: 63))
    }

    func testServiceNameTruncatesMultibyteByBytesNotCharacters() {
        // 40 x U+00E9 is 40 characters but 80 UTF-8 bytes.
        let host = String(repeating: "\u{00E9}", count: 40)
        let result = CompanionServer.serviceName(from: host)
        XCTAssertLessThanOrEqual(result.utf8.count, 63)
        XCTAssertTrue(host.hasPrefix(result))
        // 31 x 2 bytes = 62, the longest whole-character prefix within 63 bytes.
        XCTAssertEqual(result, String(repeating: "\u{00E9}", count: 31))
    }

    func testServiceNameTruncatesEmojiWithoutSplitting() {
        // 20 x U+1F600 is 20 characters but 80 UTF-8 bytes.
        let host = String(repeating: "\u{1F600}", count: 20)
        let result = CompanionServer.serviceName(from: host)
        XCTAssertLessThanOrEqual(result.utf8.count, 63)
        XCTAssertTrue(host.hasPrefix(result))
        XCTAssertEqual(result, String(repeating: "\u{1F600}", count: 15))
    }
}
