import XCTest

@testable import HogHunter

extension CompanionServer {
    /// Routes as a phone on the local Wi-Fi.  Tests that are not about the
    /// network use this.
    func disposition(for buffer: Data) -> Disposition {
        disposition(for: buffer, peer: CompanionPeer(key: "192.168.1.20", isTrusted: true))
    }
}

final class CompanionPeerTests: XCTestCase {
    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> CompanionPeer {
        CompanionPeer.make(ipv4: [a, b, c, d])
    }

    func testPrivateAndTailscaleIPv4AddressesAreTrusted() {
        XCTAssertTrue(v4(127, 0, 0, 1).isTrusted)
        XCTAssertTrue(v4(10, 1, 2, 3).isTrusted)
        XCTAssertTrue(v4(172, 16, 0, 9).isTrusted)
        XCTAssertTrue(v4(172, 31, 255, 1).isTrusted)
        XCTAssertTrue(v4(192, 168, 1, 20).isTrusted)
        XCTAssertTrue(v4(169, 254, 3, 4).isTrusted)
        XCTAssertTrue(v4(100, 64, 0, 1).isTrusted, "start of the Tailscale range")
        XCTAssertTrue(v4(100, 101, 7, 8).isTrusted)
        XCTAssertTrue(v4(100, 127, 255, 254).isTrusted, "end of the Tailscale range")
    }

    func testPublicIPv4AddressesAreNotTrusted() {
        XCTAssertFalse(v4(8, 8, 8, 8).isTrusted)
        XCTAssertFalse(v4(203, 0, 113, 9).isTrusted)
        XCTAssertFalse(v4(172, 15, 0, 1).isTrusted, "just below 172.16/12")
        XCTAssertFalse(v4(172, 32, 0, 1).isTrusted, "just above 172.16/12")
        XCTAssertFalse(v4(100, 63, 255, 255).isTrusted, "just below 100.64/10")
        XCTAssertFalse(v4(100, 128, 0, 1).isTrusted, "just above 100.64/10")
        XCTAssertFalse(v4(192, 169, 1, 1).isTrusted)
        XCTAssertFalse(v4(11, 0, 0, 1).isTrusted)
    }

    private func v6(_ prefix: [UInt8], last: UInt8 = 1) -> CompanionPeer {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in prefix.enumerated() { bytes[index] = byte }
        bytes[15] = last
        return CompanionPeer.make(ipv6: bytes)
    }

    func testIPv6LinkLocalUniqueLocalAndTailscaleAreTrusted() {
        // A phone found over Bonjour usually arrives as fe80::...%en0.
        XCTAssertTrue(v6([0xfe, 0x80]).isTrusted)
        XCTAssertTrue(v6([0xfe, 0xbf]).isTrusted, "fe80::/10 runs up to febf")
        XCTAssertTrue(v6([0xfd, 0x12, 0x34]).isTrusted, "unique-local")
        XCTAssertTrue(v6([0xfc, 0x00]).isTrusted)
        XCTAssertTrue(v6([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]).isTrusted, "Tailscale fd7a:115c:a1e0::/48")
        XCTAssertTrue(CompanionPeer.make(ipv6: [UInt8](repeating: 0, count: 15) + [1]).isTrusted, "::1")
    }

    func testPublicIPv6AddressesAreNotTrusted() {
        XCTAssertFalse(v6([0x20, 0x01, 0x0d, 0xb8]).isTrusted)
        XCTAssertFalse(v6([0x26, 0x00]).isTrusted)
        XCTAssertFalse(v6([0xfe, 0xc0]).isTrusted, "fec0 is deprecated site-local, outside fe80::/10")
        XCTAssertFalse(CompanionPeer.make(ipv6: [UInt8](repeating: 0, count: 16)).isTrusted, ":: is not a peer")
    }

    func testIPv4MappedIPv6IsJudgedByTheEmbeddedAddress() {
        func mapped(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> CompanionPeer {
            CompanionPeer.make(ipv6: [UInt8](repeating: 0, count: 10) + [0xff, 0xff, a, b, c, d])
        }
        XCTAssertTrue(mapped(192, 168, 1, 7).isTrusted)
        XCTAssertFalse(mapped(8, 8, 4, 4).isTrusted)
        // The same client must be one throttle bucket however the socket shows it.
        XCTAssertEqual(mapped(192, 168, 1, 7).key, v4(192, 168, 1, 7).key)
    }

    func testMalformedAddressesAreNeverTrusted() {
        XCTAssertFalse(CompanionPeer.make(ipv4: [10, 0, 0]).isTrusted)
        XCTAssertFalse(CompanionPeer.make(ipv6: [0xfe, 0x80]).isTrusted)
        XCTAssertFalse(CompanionPeer.from(nil).isTrusted)
        XCTAssertFalse(CompanionPeer.unknown.isTrusted)
    }
}

final class CompanionAuthThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFewMissesAreFree() {
        var throttle = CompanionAuthThrottle()
        for step in 0..<4 {
            throttle.recordFailure(peer: "a", now: t0.addingTimeInterval(Double(step)))
            XCTAssertNil(throttle.retryAfter(for: "a", now: t0.addingTimeInterval(Double(step))))
        }
    }

    func testTheFifthMissStartsALockoutThatDoublesAndIsCapped() {
        var throttle = CompanionAuthThrottle()
        var waits: [Int] = []
        for _ in 0..<5 { throttle.recordFailure(peer: "a", now: t0) }
        waits.append(throttle.retryAfter(for: "a", now: t0) ?? 0)
        for _ in 0..<3 {
            throttle.recordFailure(peer: "a", now: t0)
            waits.append(throttle.retryAfter(for: "a", now: t0) ?? 0)
        }
        XCTAssertEqual(waits, [2, 4, 8, 16])

        for _ in 0..<40 { throttle.recordFailure(peer: "a", now: t0) }
        XCTAssertEqual(throttle.retryAfter(for: "a", now: t0), 900, "capped at 15 minutes")
    }

    func testTheLockoutEndsWhenItsTimeIsUp() {
        var throttle = CompanionAuthThrottle()
        for _ in 0..<5 { throttle.recordFailure(peer: "a", now: t0) }
        XCTAssertNotNil(throttle.retryAfter(for: "a", now: t0.addingTimeInterval(1)))
        XCTAssertNil(throttle.retryAfter(for: "a", now: t0.addingTimeInterval(2.1)))
    }

    func testOneClientsMissesDoNotLockAnother() {
        var throttle = CompanionAuthThrottle()
        for _ in 0..<8 { throttle.recordFailure(peer: "attacker", now: t0) }
        XCTAssertNotNil(throttle.retryAfter(for: "attacker", now: t0))
        XCTAssertNil(throttle.retryAfter(for: "phone", now: t0))
    }

    func testASuccessClearsTheSlate() {
        var throttle = CompanionAuthThrottle()
        for _ in 0..<4 { throttle.recordFailure(peer: "a", now: t0) }
        throttle.recordSuccess(peer: "a")
        throttle.recordFailure(peer: "a", now: t0)
        XCTAssertNil(throttle.retryAfter(for: "a", now: t0), "the count started over")
    }

    func testAQuietClientIsForgiven() {
        var throttle = CompanionAuthThrottle()
        for _ in 0..<6 { throttle.recordFailure(peer: "a", now: t0) }
        let later = t0.addingTimeInterval(16 * 60)
        XCTAssertNil(throttle.retryAfter(for: "a", now: later))
        throttle.recordFailure(peer: "a", now: later)
        XCTAssertNil(throttle.retryAfter(for: "a", now: later), "one miss after a long quiet is just one miss")
    }

    func testMemoryIsCapped() {
        var throttle = CompanionAuthThrottle()
        throttle.policy.capacity = 10
        for index in 0..<50 {
            throttle.recordFailure(peer: "peer-\(index)", now: t0.addingTimeInterval(Double(index)))
        }
        XCTAssertLessThanOrEqual(throttle.trackedPeerCount, 10)
        // The newest survive.
        for _ in 0..<5 { throttle.recordFailure(peer: "peer-49", now: t0.addingTimeInterval(60)) }
        XCTAssertNotNil(throttle.retryAfter(for: "peer-49", now: t0.addingTimeInterval(60)))
    }

    func testRotatingOutsideAddressesStillHitTheGlobalCap() {
        var throttle = CompanionAuthThrottle()
        throttle.policy.globalLimit = 20
        for index in 0..<20 {
            throttle.recordFailure(peer: "fresh-\(index)", now: t0)
        }
        XCTAssertNotNil(throttle.retryAfter(for: "someone-new", now: t0), "every outside client waits once the Mac is under attack")
        XCTAssertNil(throttle.retryAfter(for: "someone-new", now: t0.addingTimeInterval(61)))
    }

    func testTheGlobalCapNeverLocksOutAPhoneOnTheLocalNetwork() {
        var throttle = CompanionAuthThrottle()
        throttle.policy.globalLimit = 20
        for index in 0..<40 {
            throttle.recordFailure(peer: "stranger-\(index)", now: t0)
        }
        XCTAssertNotNil(throttle.retryAfter(for: "stranger-new", now: t0))
        XCTAssertNil(throttle.retryAfter(for: "192.168.1.20", now: t0, appliesGlobal: false), "strangers guessing through a forwarded port must not shut out the home phone")
    }

    func testMissesFromTheLocalNetworkDoNotFeedTheGlobalCap() {
        var throttle = CompanionAuthThrottle()
        throttle.policy.globalLimit = 5
        for index in 0..<30 {
            throttle.recordFailure(peer: "192.168.1.\(index)", now: t0, countsTowardGlobal: false)
        }
        XCTAssertNil(throttle.retryAfter(for: "outsider", now: t0), "a noisy LAN client must not lock the outside world's counter")
    }
}

final class CompanionServerHardeningTests: XCTestCase {
    private let code = "ABCD2345"
    /// The paired phone's own token, issued by whichever server a test builds.
    private var deviceToken = ""
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let tailnet = CompanionPeer(key: "100.101.7.8", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeServer() -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteQuit = true
        server.allowRemoteClean = true
        server.allowRemoteEdit = true
        let row = HogRow(id: "p-100-11", keys: [ProcessKey(pid: 100, startTime: 11)], name: "tool", detail: "", cpuPercent: 0, memoryBytes: 0, peakMemoryBytes: nil, presence: nil, icon: nil, path: nil, isApp: false, isGroup: false, canQuit: true, quitBlockReason: nil)
        server.update(snapshot: CompanionServerRoutingTests.minimalSnapshot(), targets: CompanionTargets.index([row]))
        server.syncOnQueue {}
        return server
    }

    private func status(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer, at now: Date? = nil) -> Int? {
        let disposition = server.syncOnQueue { server.disposition(for: request, peer: peer, now: now ?? t0) }
        switch disposition {
        case .reply(let data): return CompanionHTTP.parseResponse(data)?.status
        case .startClean: return 202
        }
    }

    // MARK: Network gating

    func testControlsAreAcceptedFromTheLocalNetworkAndTailscale() {
        let server = makeServer()
        server.onRemoteQuit = { _, _ in (200, Data("{}".utf8)) }
        server.onRemoteTame = { _, _ in (200, Data("{}".utf8)) }
        server.onRemoteExclusionsUpdate = { _ in (200, Data("{}".utf8)) }
        server.onRemoteViewUpdate = { _ in (200, Data("{}".utf8)) }
        server.onRemoteClean = { _ in }
        for peer in [lan, tailnet] {
            XCTAssertEqual(status(server, CompanionHTTP.quitRequest(token: deviceToken, pid: 100, rowId: "p-100-11"), from: peer), 200)
            XCTAssertEqual(status(server, CompanionHTTP.tameRequest(token: deviceToken, pid: 100, rowId: "p-100-11"), from: peer), 200)
            XCTAssertEqual(status(server, CompanionHTTP.exclusionsRequest(token: deviceToken, toggleCategory: "trash"), from: peer), 200)
            XCTAssertEqual(status(server, CompanionHTTP.viewRequest(token: deviceToken, window: "Now"), from: peer), 200)
            XCTAssertEqual(status(server, CompanionHTTP.cleanRequest(token: deviceToken), from: peer), 202)
        }
    }

    func testControlsFromAPublicAddressAreRefusedBeforeAnyHandlerRuns() {
        let server = makeServer()
        server.onRemoteQuit = { _, _ in XCTFail("quit must not run"); return (200, Data()) }
        server.onRemoteTame = { _, _ in XCTFail("tame must not run"); return (200, Data()) }
        server.onRemoteExclusionsUpdate = { _ in XCTFail("exclusions must not run"); return (200, Data()) }
        server.onRemoteViewUpdate = { _ in XCTFail("view must not run"); return (200, Data()) }
        server.onRemoteClean = { _ in XCTFail("clean must not run") }
        XCTAssertEqual(status(server, CompanionHTTP.quitRequest(token: deviceToken, pid: 100, rowId: "p-100-11"), from: wan), 403)
        XCTAssertEqual(status(server, CompanionHTTP.tameRequest(token: deviceToken, pid: 100, rowId: "p-100-11"), from: wan), 403)
        XCTAssertEqual(status(server, CompanionHTTP.exclusionsRequest(token: deviceToken, toggleCategory: "trash"), from: wan), 403)
        XCTAssertEqual(status(server, CompanionHTTP.viewRequest(token: deviceToken, window: "Now"), from: wan), 403)
        XCTAssertEqual(status(server, CompanionHTTP.cleanRequest(token: deviceToken), from: wan), 403)
    }

    func testReadingTheSnapshotStillWorksFromAnywhereWithAValidToken() {
        let server = makeServer()
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code), from: wan), 200)
    }

    func testTheRefusalNamesTheNetworkRule() throws {
        let reply = CompanionHTTP.untrustedNetworkReply()
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(reply))
        XCTAssertEqual(parsed.status, 403)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: String])
        XCTAssertTrue(json["error"]?.contains("local network or Tailscale") ?? false)
        // The phone keys off this, not the wording, to keep read-only access.
        XCTAssertEqual(json["reason"], "untrusted-network")
    }

    func testAnOutsideClientGuessingIsLockedPerAddressAndTheLocalPhoneIsNotAffected() {
        let server = makeServer()
        for index in 0..<200 {
            let stranger = CompanionPeer(key: "203.0.113.\(index % 250)", isTrusted: false)
            _ = status(server, CompanionHTTP.request(token: "WRONG234"), from: stranger)
        }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: deviceToken), from: lan), 200)
    }

    // MARK: Throttle

    func testRepeatedWrongCodesAreMetWithAWaitEvenForTheRightCode() throws {
        let server = makeServer()
        for _ in 0..<5 {
            XCTAssertEqual(status(server, CompanionHTTP.request(token: "WRONG234"), from: lan), 401)
        }
        // Now locked: the right code is not even looked at.
        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: code), peer: lan, now: t0) }
        guard case .reply(let data) = disposition else { return XCTFail("expected an inline reply") }
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(data))
        XCTAssertEqual(parsed.status, 429)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: Any])
        XCTAssertEqual(json["retryAfter"] as? Int, 2)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Retry-After: 2"))

        // After the wait the right code works again.
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code), from: lan, at: t0.addingTimeInterval(3)), 200)
    }

    func testAnotherPhoneIsNotLockedOutByTheFirst() {
        let server = makeServer()
        for _ in 0..<6 { _ = status(server, CompanionHTTP.request(token: "WRONG234"), from: wan) }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code), from: lan), 200)
    }

    func testAGoodRequestClearsTheMissCount() {
        let server = makeServer()
        for _ in 0..<4 { _ = status(server, CompanionHTTP.request(token: "WRONG234"), from: lan) }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code), from: lan), 200)
        for _ in 0..<4 { XCTAssertEqual(status(server, CompanionHTTP.request(token: "WRONG234"), from: lan), 401) }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code), from: lan), 200, "four misses after a success are still free")
    }

    func testAnUnknownPathNeverCountsAsAWrongCode() {
        let server = makeServer()
        for _ in 0..<10 {
            let probe = Data("GET /nothing HTTP/1.1\r\n\r\n".utf8)
            XCTAssertEqual(status(server, probe, from: lan), 404)
        }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code), from: lan), 200)
    }

    func testThrottledReplyShape() throws {
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.throttledReply(retryAfter: 30)))
        XCTAssertEqual(parsed.status, 429)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: Any])
        XCTAssertEqual(json["retryAfter"] as? Int, 30)
        XCTAssertEqual(CompanionHTTP.statusCode(of: CompanionHTTP.throttledReply(retryAfter: 30)), 429)
    }
}
