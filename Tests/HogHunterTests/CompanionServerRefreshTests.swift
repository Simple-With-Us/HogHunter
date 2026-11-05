import XCTest

@testable import HogHunter

// The phone's server refresh and the Flagged Issue buttons (HH-218).
//
// No test here runs SSH.  The router tests count calls to an injected
// refresh handler, and the action test gives `VPSStatusStore` a counting
// fetcher, so the forced read is observed without leaving the process.

private final class Counter: @unchecked Sendable {
    private let stored = CompanionLocked<[String]>([])
    var calls: [String] { stored.value }
    func add(_ value: String) { stored.withLock { $0.append(value) } }
}

final class CompanionServerRefreshRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)
    private let tailnet = CompanionPeer(key: "100.100.1.2", isTrusted: true, arrivedOverTailscale: true)

    private func server(statusOn: Bool = true, counter: Counter) -> (CompanionServer, String) {
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteServerStatus = statusOn
        server.onRemoteServerRefresh = { device in counter.add(device) }
        server.syncOnQueue {}
        return (server, token)
    }

    private func send(_ server: CompanionServer, _ data: Data, from peer: CompanionPeer, at now: Date = Date()) -> (status: Int, raw: Data, response: CompanionServerRefreshResponse?)? {
        guard case .reply(let reply) = server.syncOnQueue({ server.disposition(for: data, peer: peer, now: now) }),
              let parsed = CompanionHTTP.parseResponse(reply) else { return nil }
        return (parsed.status, reply, try? JSONDecoder().decode(CompanionServerRefreshResponse.self, from: parsed.body))
    }

    func testAPhonesOwnTokenOnTheLocalNetworkStartsARefresh() {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        let answer = send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan)
        XCTAssertEqual(answer?.status, 200)
        XCTAssertEqual(answer?.response?.status, "started")
        XCTAssertEqual(counter.calls, ["Test iPhone"], "the refresh runs once, under the paired phone's name")
    }

    func testTailscaleIsAcceptedToo() {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: tailnet)?.status, 200)
        XCTAssertEqual(counter.calls.count, 1)
    }

    func testTheOptInOffIsAReadable403() {
        let counter = Counter()
        let (server, token) = server(statusOn: false, counter: counter)
        let answer = send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan)
        XCTAssertEqual(answer?.status, 403)
        XCTAssertEqual(answer?.response?.status, "forbidden")
        XCTAssertTrue(counter.calls.isEmpty)
    }

    func testTheOptInIsOffByDefault() {
        XCTAssertFalse(CompanionServer().allowRemoteServerStatus)
    }

    func testTheSharedCodeIsRefused() {
        let counter = Counter()
        let (server, _) = server(counter: counter)
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: code), from: lan)?.status, 403)
        XCTAssertTrue(counter.calls.isEmpty, "the shared pairing code never reaches the route")
    }

    func testAnOutsidePeerIsRefused() {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: wan)?.status, 403)
        XCTAssertTrue(counter.calls.isEmpty)
    }

    func testAWrongTokenIs401() {
        let counter = Counter()
        let (server, _) = server(counter: counter)
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: "hh1_wrong"), from: lan)?.status, 401)
        XCTAssertTrue(counter.calls.isEmpty)
    }

    func testASecondRefreshInsideTheIntervalIs429WithRetryAfter() throws {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        let start = Date()
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start)?.status, 200)
        let second = try XCTUnwrap(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start.addingTimeInterval(4)))
        XCTAssertEqual(second.status, 429)
        XCTAssertEqual(second.response?.status, "throttled")
        XCTAssertEqual(second.response?.retryAfter, 11)
        let head = String(data: second.raw, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(head.contains("\r\nRetry-After: 11\r\n"), head)
        XCTAssertEqual(counter.calls.count, 1, "a refused refresh does not run")
    }

    func testTheIntervalHoldsForEveryPhoneTogether() {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        let other = server.devices.issue(name: "Other iPhone").token
        let start = Date()
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start)?.status, 200)
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: other), from: tailnet, at: start.addingTimeInterval(1))?.status, 429)
        XCTAssertEqual(counter.calls.count, 1)
    }

    func testARefreshAfterTheIntervalIsAccepted() {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        let start = Date()
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start)?.status, 200)
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start.addingTimeInterval(CompanionServerRefresh.minimumInterval))?.status, 200)
        XCTAssertEqual(counter.calls.count, 2)
    }

    func testARefusedRefreshDoesNotStartTheInterval() {
        let counter = Counter()
        let (server, token) = server(statusOn: false, counter: counter)
        let start = Date()
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start)?.status, 403)
        server.allowRemoteServerStatus = true
        XCTAssertEqual(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan, at: start.addingTimeInterval(1))?.status, 200)
    }

    func testAGetABodyAndAQueryAreRefused() {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        let get = ["GET \(CompanionService.serverRefreshPath) HTTP/1.1", "Host: x", "Authorization: Bearer \(token)", "", ""]
        XCTAssertEqual(send(server, Data(get.joined(separator: "\r\n").utf8), from: lan)?.status, 405)
        let body = #"{"host":"elsewhere"}"#
        let withBody = ["POST \(CompanionService.serverRefreshPath) HTTP/1.1", "Host: x", "Authorization: Bearer \(token)", "Content-Length: \(body.utf8.count)", "", body]
        XCTAssertEqual(send(server, Data(withBody.joined(separator: "\r\n").utf8), from: lan)?.status, 400)
        let query = ["POST \(CompanionService.serverRefreshPath)?host=x HTTP/1.1", "Host: x", "Authorization: Bearer \(token)", "Content-Length: 0", "", ""]
        XCTAssertEqual(send(server, Data(query.joined(separator: "\r\n").utf8), from: lan)?.status, 400)
        XCTAssertTrue(counter.calls.isEmpty)
    }

    func testTheReplyNamesNoHostOrPath() throws {
        let counter = Counter()
        let (server, token) = server(counter: counter)
        let answer = try XCTUnwrap(send(server, CompanionHTTP.serverRefreshRequest(token: token), from: lan))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionHTTP.parseResponse(answer.raw)!.body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["status", "message"])
    }

    func testThePhoneReadsPlainRepliesByStatus() {
        XCTAssertEqual(CompanionServerRefreshResponse.answer(status: 404, body: Data()).status, "rejected")
        XCTAssertEqual(CompanionServerRefreshResponse.answer(status: 429, body: Data()).status, "throttled")
        XCTAssertFalse(CompanionServerRefreshResponse.answer(status: 500, body: Data()).isStarted)
    }
}

final class CompanionServerRefreshActionTests: XCTestCase {
    @MainActor
    func testARefreshForcesARead() async throws {
        let counter = Counter()
        let reading = VPSStatusSnapshot(generatedAt: ISO8601DateFormatter().string(from: Date()), host: "server-1", devices: [:])
        let vps = VPSStatusStore(fetcher: { host in
            counter.add(host)
            return reading
        }, history: SizeGrowthHistory(fileURL: nil))
        addTeardownBlock { await MainActor.run { vps.stopPolling() } }
        vps.setHost("server.tailnet")
        for _ in 0..<200 where vps.lastFetchDate == nil || vps.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let before = counter.calls.count
        XCTAssertGreaterThan(before, 0)
        // An ordinary fetch inside the minute is skipped, which is why the
        // phone's refresh must force one.
        vps.fetch()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.calls.count, before)

        let sink = CompanionLocked<[CompanionServerActions.AuditEntry]>([])
        let actions = CompanionServerActions(
            vps: vps,
            control: ServerControl(runner: { _, _ in XCTFail("no server action runs"); return "{}" }),
            maintenance: ServerMaintenanceControl(runner: { _, _ in XCTFail("no maintenance runs"); return ServerMaintenanceResponse(exitCode: 0, output: "{}") }),
            audit: { entry in sink.withLock { $0.append(entry) } }
        )
        XCTAssertTrue(actions.refresh(device: "Test iPhone"))
        for _ in 0..<200 where counter.calls.count == before {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(counter.calls.count, before + 1)
        XCTAssertEqual(counter.calls.last, "server.tailnet")
        XCTAssertEqual(sink.value, [.init(device: "Test iPhone", action: "refresh", row: "", outcome: "started")])
    }

    @MainActor
    func testNoServerMeansNoRead() {
        let counter = Counter()
        let vps = VPSStatusStore(fetcher: { host in
            counter.add(host)
            throw NSError(domain: "test", code: 1)
        }, history: SizeGrowthHistory(fileURL: nil))
        let actions = CompanionServerActions(
            vps: vps,
            control: ServerControl(runner: { _, _ in "{}" }),
            maintenance: ServerMaintenanceControl(runner: { _, _ in ServerMaintenanceResponse(exitCode: 0, output: "{}") }),
            audit: { _ in }
        )
        XCTAssertFalse(actions.refresh(device: "Test iPhone"))
        XCTAssertTrue(counter.calls.isEmpty)
    }
}

final class CompanionIssueActionTests: XCTestCase {
    private let all = CompanionServerStatusBuilder.IssueActionsAllowed(quit: true, clean: true, refresh: true)

    private func issue(_ id: String, host: IssueHost, action: String?) -> FlaggedIssue {
        FlaggedIssue(id: id, title: "T", message: "M", priority: .high, host: host, category: .disk, actionTitle: action)
    }

    private var macIssues: [FlaggedIssue] {
        [
            issue("mac.disk.low", host: .mac, action: "Clean"),
            issue(CompanionFlaggedIssue.quitIssueID(forRow: "a-chrome"), host: .mac, action: "Quit"),
            issue("server.unreachable", host: .server, action: "Retry"),
            issue("mac.memory.warning", host: .mac, action: nil),
        ]
    }

    func testEachKindMapsWhenItsOptInIsOn() {
        let actions = CompanionServerStatusBuilder.issues(macIssues, allowed: all).map(\.actionKind)
        XCTAssertEqual(actions, [.clean, .quit, .retry, nil])
    }

    func testNothingMapsByDefault() {
        let actions = CompanionServerStatusBuilder.issues(macIssues).map(\.action)
        XCTAssertEqual(actions, [nil, nil, nil, nil])
    }

    func testEachKindIsAbsentWhenOnlyItsOwnOptInIsOff() {
        var noQuit = all
        noQuit.quit = false
        XCTAssertEqual(CompanionServerStatusBuilder.issues(macIssues, allowed: noQuit).map(\.actionKind), [.clean, nil, .retry, nil])
        var noClean = all
        noClean.clean = false
        XCTAssertEqual(CompanionServerStatusBuilder.issues(macIssues, allowed: noClean).map(\.actionKind), [nil, .quit, .retry, nil])
        var noRefresh = all
        noRefresh.refresh = false
        XCTAssertEqual(CompanionServerStatusBuilder.issues(macIssues, allowed: noRefresh).map(\.actionKind), [.clean, .quit, nil, nil])
    }

    func testAButtonOnTheWrongHostDoesNotMap() {
        let wrong = [issue("server.x", host: .server, action: "Clean"), issue("mac.x", host: .mac, action: "Retry"), issue("mac.y", host: .mac, action: "Reboot")]
        XCTAssertEqual(CompanionServerStatusBuilder.issues(wrong, allowed: all).map(\.action), [nil, nil, nil])
    }

    func testTheQuitIssueIdIsTheOneTheEvaluatorUses() {
        XCTAssertEqual(CompanionFlaggedIssue.quitIssueID(forRow: "p-42-7"), "mac.cpu.hog.p-42-7")
    }

    func testAnOlderPhoneStillDecodesAndAnUnknownKindShowsNothing() throws {
        let issue = CompanionFlaggedIssue(id: "x", title: "T", message: "M", priority: 1, priorityText: "High", host: "Mac", action: "reboot")
        let decoded = try JSONDecoder().decode(CompanionFlaggedIssue.self, from: JSONEncoder().encode(issue))
        XCTAssertEqual(decoded.action, "reboot")
        XCTAssertNil(decoded.actionKind)
        let old = #"{"id":"x","title":"T","message":"M","priority":1,"priorityText":"High","host":"Mac"}"#
        XCTAssertNil(try JSONDecoder().decode(CompanionFlaggedIssue.self, from: Data(old.utf8)).action)
    }

    func testTheWireCarriesOnlyTheKind() throws {
        let encoded = try JSONEncoder().encode(CompanionServerStatusBuilder.issues([issue("server.unreachable", host: .server, action: "Retry")], allowed: all))
        let object = try XCTUnwrap((JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])?.first)
        XCTAssertEqual(object["action"] as? String, "retry")
        XCTAssertEqual(Set(object.keys), ["id", "title", "message", "priority", "priorityText", "host", "category", "action"])
    }
}
