import XCTest

@testable import HogHunter

/// Per-device tokens: each paired phone has its own credential, the Mac keeps
/// only a hash, and revoking one phone cuts off that phone alone.
final class CompanionDeviceRegistryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "hoghunter.tests.devices.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnIssuedTokenIsLongRandomAndRecognizableAsADeviceToken() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let first = registry.issue(name: "Jay's iPhone", now: t0).token
        let second = registry.issue(name: "Other iPhone", now: t0).token
        XCTAssertTrue(first.hasPrefix("hh1_"))
        XCTAssertEqual(first.count, 4 + 32)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(CompanionToken.isDeviceToken(first))
        XCTAssertFalse(CompanionToken.isDeviceToken("ABCD2345"), "the shared code is never mistaken for a device token")
        XCTAssertFalse(CompanionToken.isDeviceToken("hh1_"))
    }

    func testThePairedPhoneAuthenticatesAndNothingElseDoes() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let issued = registry.issue(name: "Jay's iPhone", now: t0)
        XCTAssertTrue(registry.authenticate(issued.token, now: t0))
        XCTAssertFalse(registry.authenticate(issued.token + "x", now: t0))
        XCTAssertFalse(registry.authenticate("hh1_" + String(repeating: "A", count: 32), now: t0))
        XCTAssertFalse(registry.authenticate("ABCD2345", now: t0))
        XCTAssertFalse(registry.authenticate("", now: t0))
    }

    func testTheMacKeepsOnlyAHashOfTheToken() throws {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let issued = registry.issue(name: "Jay's iPhone", now: t0)
        let stored = try XCTUnwrap(defaults.data(forKey: CompanionDeviceRegistry.defaultsKey))
        let text = String(decoding: stored, as: UTF8.self)
        XCTAssertFalse(text.contains(issued.token), "the token itself must never be written to disk")
        XCTAssertTrue(text.contains(CompanionDeviceRegistry.hash(issued.token)))
        XCTAssertEqual(issued.device.tokenHash.count, 64)
    }

    func testPairedPhonesSurviveARestart() {
        let first = CompanionDeviceRegistry(defaults: defaults)
        let issued = first.issue(name: "Jay's iPhone", now: t0)

        let second = CompanionDeviceRegistry(defaults: defaults)
        XCTAssertEqual(second.devices.map(\.name), ["Jay's iPhone"])
        XCTAssertTrue(second.authenticate(issued.token, now: t0))
    }

    func testRevokingOnePhoneLeavesTheOthers() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let mine = registry.issue(name: "Mine", now: t0)
        let lost = registry.issue(name: "Lost", now: t0.addingTimeInterval(1))

        XCTAssertTrue(registry.revoke(id: lost.device.id))

        XCTAssertFalse(registry.authenticate(lost.token, now: t0))
        XCTAssertTrue(registry.authenticate(mine.token, now: t0))
        XCTAssertFalse(registry.revoke(id: lost.device.id), "already gone")
        // And it stays revoked after a restart.
        XCTAssertFalse(CompanionDeviceRegistry(defaults: defaults).authenticate(lost.token, now: t0))
    }

    func testRevokeAllCutsOffEveryPhone() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let tokens = (0..<3).map { registry.issue(name: "Phone \($0)", now: t0).token }
        registry.revokeAll()
        XCTAssertTrue(registry.devices.isEmpty)
        for token in tokens { XCTAssertFalse(registry.authenticate(token, now: t0)) }
    }

    func testDevicesListNewestFirstWithSanitizedNames() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        _ = registry.issue(name: "Old", now: t0)
        _ = registry.issue(name: String(repeating: "N", count: 200) + "\u{0007}", now: t0.addingTimeInterval(10))
        _ = registry.issue(name: "   ", now: t0.addingTimeInterval(20))
        let names = registry.devices.map(\.name)
        XCTAssertEqual(names.first, "An iPhone", "a blank name becomes a generic one")
        XCTAssertEqual(names[1].count, CompanionHTTP.maxDeviceNameLength)
        XCTAssertFalse(names[1].contains("\u{0007}"))
        XCTAssertEqual(names.last, "Old")
    }

    func testLastSeenIsRecordedButWrittenToDiskAtMostOncePerMinute() throws {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let issued = registry.issue(name: "Jay's iPhone", now: t0)
        func storedSeen() throws -> Date? {
            let data = try XCTUnwrap(defaults.data(forKey: CompanionDeviceRegistry.defaultsKey))
            return try CompanionJSON.decoder().decode([CompanionDevice].self, from: data).first?.lastSeenAt
        }

        _ = registry.authenticate(issued.token, now: t0.addingTimeInterval(10))
        XCTAssertEqual(registry.devices.first?.lastSeenAt, t0.addingTimeInterval(10), "kept in memory at once")
        XCTAssertEqual(try storedSeen(), t0, "but not written for a poll 10 seconds after pairing")

        _ = registry.authenticate(issued.token, now: t0.addingTimeInterval(90))
        XCTAssertEqual(try storedSeen(), t0.addingTimeInterval(90))
    }

    func testTheListIsCappedAndDropsTheLeastRecentlySeen() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let stale = registry.issue(name: "Stale", now: t0)
        for index in 1..<CompanionDeviceRegistry.capacity {
            _ = registry.issue(name: "Phone \(index)", now: t0.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(registry.devices.count, CompanionDeviceRegistry.capacity)
        _ = registry.issue(name: "One more", now: t0.addingTimeInterval(1_000))
        XCTAssertEqual(registry.devices.count, CompanionDeviceRegistry.capacity)
        XCTAssertFalse(registry.authenticate(stale.token, now: t0.addingTimeInterval(1_000)))
    }

    func testOnlyChangesToTheListNotifyTheListener() {
        let registry = CompanionDeviceRegistry(defaults: defaults)
        let calls = CompanionLocked(0)
        registry.onChange { calls.value += 1 }

        let issued = registry.issue(name: "Jay's iPhone", now: t0)
        XCTAssertEqual(calls.value, 1)
        _ = registry.authenticate(issued.token, now: t0.addingTimeInterval(5))
        XCTAssertEqual(calls.value, 1, "a poll is not a change")
        registry.revoke(id: issued.device.id)
        XCTAssertEqual(calls.value, 2)
        registry.revokeAll()
        XCTAssertEqual(calls.value, 2, "nothing left to revoke")
    }
}

final class CompanionDeviceRoutingTests: XCTestCase {
    private let code = "ABCD2345"
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeServer() -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        server.allowRemoteQuit = true
        server.allowRemoteClean = true
        server.allowRemoteEdit = true
        let row = HogRow(id: "p-100-11", keys: [ProcessKey(pid: 100, startTime: 11)], name: "tool", detail: "", cpuPercent: 0, memoryBytes: 0, peakMemoryBytes: nil, presence: nil, icon: nil, path: nil, isApp: false, isGroup: false, canQuit: true, quitBlockReason: nil)
        server.update(snapshot: CompanionServerRoutingTests.minimalSnapshot(), targets: CompanionTargets.index([row]))
        server.onRemoteQuit = { _, _ in (200, Data("{}".utf8)) }
        server.onRemoteTame = { _, _ in (200, Data("{}".utf8)) }
        server.onRemoteExclusionsUpdate = { _ in (200, Data("{}".utf8)) }
        server.onRemoteViewUpdate = { _ in (200, Data("{}".utf8)) }
        server.onRemoteClean = { _, _ in }
        server.syncOnQueue {}
        return server
    }

    private func status(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer? = nil, at now: Date? = nil) -> Int? {
        let disposition = server.syncOnQueue { server.disposition(for: request, peer: peer ?? lan, now: now ?? t0) }
        switch disposition {
        case .reply(let data): return CompanionHTTP.parseResponse(data)?.status
        case .startClean, .startCleanScan, .startCleanReport, .startSample: return 202
        }
    }

    private func controlRequests(_ token: String) -> [Data] {
        [
            CompanionHTTP.quitRequest(token: token, pid: 100, rowId: "p-100-11"),
            CompanionHTTP.tameRequest(token: token, pid: 100, rowId: "p-100-11"),
            CompanionHTTP.cleanRequest(token: token),
            CompanionHTTP.exclusionsRequest(token: token, toggleCategory: "trash"),
            CompanionHTTP.viewRequest(token: token, window: "Now"),
        ]
    }

    func testThePairingCodeCanReadButCannotControl() throws {
        let server = makeServer()
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code)), 200, "an older phone still reads")
        for request in controlRequests(code) {
            XCTAssertEqual(status(server, request), 403)
        }
        guard case .reply(let data) = server.syncOnQueue({ server.disposition(for: CompanionHTTP.quitRequest(token: code, pid: 100), peer: lan, now: t0) }) else {
            return XCTFail("expected an inline refusal")
        }
        let body = try XCTUnwrap(CompanionHTTP.parseResponse(data)?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertTrue(json["error"]?.contains("shared code") ?? false)
    }

    func testAPairedPhoneCanReadAndControl() {
        let server = makeServer()
        let token = server.devices.issue(name: "Jay's iPhone", now: t0).token
        XCTAssertEqual(status(server, CompanionHTTP.request(token: token)), 200)
        let expected = [200, 200, 202, 200, 200]
        XCTAssertEqual(controlRequests(token).map { status(server, $0) }, expected)
    }

    func testARevokedPhoneIsTurnedAwayAtOnce() {
        let server = makeServer()
        let issued = server.devices.issue(name: "Lost iPhone", now: t0)
        XCTAssertEqual(status(server, CompanionHTTP.request(token: issued.token)), 200)

        server.devices.revoke(id: issued.device.id)

        XCTAssertEqual(status(server, CompanionHTTP.request(token: issued.token)), 401)
        // A different client address each time, so this checks revocation
        // and not the throttle, which a revoked phone that keeps asking meets.
        let requests = controlRequests(issued.token)
        for (index, request) in requests.enumerated() {
            let peer = CompanionPeer(key: "192.168.1.\(100 + index)", isTrusted: true)
            XCTAssertEqual(status(server, request, from: peer), 401)
        }
    }

    func testARevokedPhoneThatKeepsAskingIsThrottled() {
        let server = makeServer()
        let issued = server.devices.issue(name: "Lost iPhone", now: t0)
        server.devices.revoke(id: issued.device.id)
        for _ in 0..<5 { XCTAssertEqual(status(server, CompanionHTTP.request(token: issued.token)), 401) }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: issued.token)), 429)
    }

    func testOnePhonesRevocationDoesNotAffectAnother() {
        let server = makeServer()
        let kept = server.devices.issue(name: "Kept", now: t0).token
        let lost = server.devices.issue(name: "Lost", now: t0)
        server.devices.revoke(id: lost.device.id)
        XCTAssertEqual(status(server, CompanionHTTP.request(token: kept)), 200)
    }

    func testAGuessedDeviceTokenCountsAsAWrongCredential() {
        let server = makeServer()
        let guess = "hh1_" + String(repeating: "Z", count: 32)
        for _ in 0..<5 { XCTAssertEqual(status(server, CompanionHTTP.request(token: guess)), 401) }
        XCTAssertEqual(status(server, CompanionHTTP.request(token: guess)), 429)
    }

    // MARK: Trading the code for a token

    func testEnrollRequestRoundTrips() throws {
        let request = CompanionHTTP.enrollRequest(code: "ABCD2345", deviceName: "Jay's iPhone & Co")
        let parsed = try XCTUnwrap(CompanionHTTP.enrollParams(in: request))
        XCTAssertEqual(parsed.code, "ABCD2345")
        XCTAssertEqual(parsed.deviceName, "Jay's iPhone & Co")
        XCTAssertNil(CompanionHTTP.enrollParams(in: CompanionHTTP.request(token: code)))
        XCTAssertNil(CompanionHTTP.enrollParams(in: Data("GET /v1/enroll?code=ABCD2345 HTTP/1.1\r\n\r\n".utf8)), "only POST enrolls")
        XCTAssertEqual(CompanionHTTP.enrollParams(in: Data("POST /v1/enroll HTTP/1.1\r\n\r\n".utf8))?.deviceName, "An iPhone")
    }

    func testTheRightCodeIsTradedForATokenThatThenWorks() throws {
        let server = makeServer()
        let reply = server.syncOnQueue { server.enroll(code: code, deviceName: "Jay's iPhone", peer: lan, now: t0) }
        let parsed = try XCTUnwrap(CompanionHTTP.parseResponse(reply))
        XCTAssertEqual(parsed.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.body) as? [String: String])
        let token = try XCTUnwrap(json["token"])
        XCTAssertTrue(CompanionToken.isDeviceToken(token))
        XCTAssertEqual(server.devices.devices.map(\.name), ["Jay's iPhone"])
        XCTAssertEqual(json["deviceId"], server.devices.devices.first?.id)

        XCTAssertEqual(status(server, CompanionHTTP.request(token: token)), 200)
        XCTAssertEqual(status(server, CompanionHTTP.quitRequest(token: token, pid: 100, rowId: "p-100-11")), 200)
    }

    func testAWrongCodeEnrollsNothingAndCountsAgainstTheThrottle() {
        let server = makeServer()
        for _ in 0..<5 {
            let reply = server.syncOnQueue { server.enroll(code: "WRONG234", deviceName: "Intruder", peer: lan, now: t0) }
            XCTAssertEqual(CompanionHTTP.statusCode(of: reply), 401)
        }
        XCTAssertTrue(server.devices.devices.isEmpty)
        // Locked: even the right code waits.
        let locked = server.syncOnQueue { server.enroll(code: code, deviceName: "Jay's iPhone", peer: lan, now: t0) }
        XCTAssertEqual(CompanionHTTP.statusCode(of: locked), 429)
        XCTAssertTrue(server.devices.devices.isEmpty)
    }

    func testEnrollIsRefusedFromAPublicAddressEvenWithTheRightCode() {
        let server = makeServer()
        let reply = server.syncOnQueue { server.enroll(code: code, deviceName: "Jay's iPhone", peer: wan, now: t0) }
        XCTAssertEqual(CompanionHTTP.statusCode(of: reply), 403)
        XCTAssertTrue(server.devices.devices.isEmpty)
    }

    func testEnrollResponseCarriesTheTokenOnlyOnSuccess() throws {
        let ok = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.enrollResponse(token: "hh1_abc", deviceId: "id-1")))
        XCTAssertEqual(ok.status, 200)
        let bad = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.enrollRejectedReply()))
        XCTAssertEqual(bad.status, 401)
        XCTAssertFalse(String(decoding: bad.body, as: UTF8.self).contains("hh1_"))
    }

    func testRegeneratingTheCodeLeavesPairedPhonesConnected() {
        let server = makeServer()
        let token = server.devices.issue(name: "Jay's iPhone", now: t0).token
        server.updateToken("NEWCODE22")
        server.syncOnQueue {}
        XCTAssertEqual(status(server, CompanionHTTP.request(token: token)), 200)
        XCTAssertEqual(status(server, CompanionHTTP.request(token: code)), 401, "the old shared code no longer reads")
    }
}

@MainActor
final class StoreDeviceListTests: XCTestCase {
    func testRevokingFromTheStoreCutsOffThePhoneAndUpdatesTheList() {
        let suite = "hoghunter.tests.storedevices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults)

        let issued = store.companionDevices.issue(name: "Jay's iPhone")
        store.refreshPairedDevices()
        XCTAssertEqual(store.pairedDevices.map(\.name), ["Jay's iPhone"])

        store.revokeCompanionDevice(id: issued.device.id)
        XCTAssertTrue(store.pairedDevices.isEmpty)
        XCTAssertFalse(store.companionDevices.authenticate(issued.token))
    }

    func testRevokeAllEmptiesTheList() {
        let suite = "hoghunter.tests.storedevices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults)
        _ = store.companionDevices.issue(name: "A")
        _ = store.companionDevices.issue(name: "B")
        store.refreshPairedDevices()
        XCTAssertEqual(store.pairedDevices.count, 2)
        store.revokeAllCompanionDevices()
        XCTAssertTrue(store.pairedDevices.isEmpty)
    }
}
