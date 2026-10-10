import XCTest

@testable import HogHunter

/// The Mac's error messages are shown verbatim on the iPhone, in a SwiftUI
/// `Text`, where two ASCII spaces collapse to one.  Several are written as raw
/// JSON text with a ` ` escape, which Swift does not touch and the phone's
/// JSON decoder turns into a non-breaking space.  These decode each body the way
/// the phone does and check the gap really arrives, with no stray backslash.
final class CompanionReplyTextTests: XCTestCase {
    private func message(of body: Data) throws -> String {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["error"] as? String)
    }

    private func assertGap(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains("\u{00A0}"), "no non-breaking gap in: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("\\"), "a literal backslash reached the screen: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains(".  "), "two ASCII spaces collapse on the phone: \(text)", file: file, line: line)
    }

    func testTheBusyCleanRefusalKeepsItsGap() throws {
        let refusal = try XCTUnwrap(HogStore.cleanRefusal(remoteInFlight: true, macIsCleaning: false))
        assertGap(try message(of: refusal.body))
    }

    func testTheNetworkRefusalKeepsItsGap() throws {
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.untrustedNetworkReply()))
        assertGap(try message(of: parsed.body))
    }

    func testTheSharedCodeRefusalKeepsItsGap() throws {
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.sharedCodeCannotControlReply()))
        assertGap(try message(of: parsed.body))
    }

    func testTheThrottledReplyKeepsItsGap() throws {
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.throttledReply(retryAfter: 30)))
        assertGap(try message(of: parsed.body))
    }

    func testTheEditRefusalKeepsItsGap() throws {
        assertGap(try message(of: CompanionServer.editRefusal.body))
    }

    func testTheCleanDisabledRefusalKeepsItsGap() throws {
        let server = CompanionServer()
        server.updateToken("ABCD2345")
        server.allowRemoteClean = false
        let token = server.devices.issue(name: "Test iPhone").token
        server.syncOnQueue {}
        let disposition = server.syncOnQueue {
            server.disposition(for: CompanionHTTP.cleanRequest(token: token), peer: CompanionPeer(key: "192.168.1.20", isTrusted: true))
        }
        guard case .reply(let data) = disposition else { return XCTFail("expected an inline refusal") }
        assertGap(try message(of: try XCTUnwrap(CompanionHTTP.parseResponse(data)).body))
    }

    func testTheVacuumRefusalNamesTheSettingAndKeepsItsGap() throws {
        let text = try message(of: CompanionServer.maintainRefusal.body)
        XCTAssertTrue(text.contains("Allow iPhone to Run Maintenance"), text)
        assertGap(text)
    }

    func testTheVacuumBusyReplyKeepsItsGap() throws {
        let busy = CompanionServer.maintainBusyReply
        XCTAssertEqual(busy.status, 409)
        assertGap(try message(of: busy.body))
    }

    func testTheVacuumBadKindReplyKeepsItsGap() throws {
        let server = CompanionServer()
        server.updateToken("ABCD2345")
        server.allowRemoteMaintain = true
        let token = server.devices.issue(name: "Test iPhone").token
        server.syncOnQueue {}
        let disposition = server.syncOnQueue {
            server.disposition(for: CompanionHTTP.maintainRunRequest(token: token, kind: "janitor"), peer: CompanionPeer(key: "192.168.1.20", isTrusted: true))
        }
        guard case .reply(let data) = disposition else { return XCTFail("expected an inline refusal") }
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(data))
        XCTAssertEqual(parsed.status, 400)
        assertGap(try message(of: parsed.body))
    }

    func testTheNetworkTabNoteKeepsItsGap() {
        // A missing lsof is the failure the note exists for.
        let scan = CompanionSnapshotBuilder.currentNetworkScan(scanner: NetworkScanner(binaryPath: "/nonexistent/lsof"))
        XCTAssertTrue(scan.rows.isEmpty)
        let note = scan.note ?? ""
        XCTAssertTrue(note.hasPrefix("The Mac could not list network connections."), note)
        XCTAssertTrue(note.contains("\u{00A0}"), "the gap between the two sentences must not collapse on the phone: \(note)")
        XCTAssertFalse(note.contains(".  "), note)
    }

    func testProcessMessagesKeepTheirGap() {
        XCTAssertTrue(CompanionTargets.unresolvedMessage(for: CompanionProcessRequest(rowId: "p-1-2", pid: 1)).contains("\u{00A0}"))
        XCTAssertTrue(ProcessControl.quit(members: [], fallbackName: "Gone", force: false).message?.contains("\u{00A0}") ?? false)
    }
}
