import Network
import XCTest

@testable import HogHunter

// Server controls on the phone, stage 2.
//
// No test here can run SSH.  `ServerControl` and `ServerMaintenanceControl` take
// an injected runner, every refusal asserts the runner was not called, and the
// default runners refuse to start under XCTest anyway.

private let rowName = "canary-worker"
private let workloadName = "canary-workload"
private let fortyHex = String(repeating: "a", count: 64)

private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func process(_ name: String = rowName, container: String? = nil, actions: [String]? = ["quit", "force-quit", "tame", "untame", "sample"], reason: String? = nil) -> VPSProcess {
    VPSProcess(pid: 4242, name: name, startTime: 987_654, owner: "app", container: container, cpuPercent: 12, memoryBytes: 100,
               bootID: "boot-1", nice: 0, allowedActions: actions, protectionReason: reason)
}

private func workload(_ name: String = workloadName, actions: [String]? = ["stop", "restart"], reason: String? = nil) -> VPSCoolifyResource {
    VPSCoolifyResource(uuid: "uuid-1", name: name, container: "container-1", type: "service", status: "running", cpuPercent: 1, memoryBytes: 1,
                       image: nil, startedAt: "2026-11-04T00:00:00Z", containerID: fortyHex, allowedActions: actions, protectionReason: reason)
}

private func reading(age: TimeInterval = 60, processes: [VPSProcess] = [process()], workloads: [VPSCoolifyResource] = [workload()]) -> VPSStatusSnapshot {
    VPSStatusSnapshot(generatedAt: stamp(Date().addingTimeInterval(-age)), host: "server-1", devices: [:], processes: processes, coolify: workloads)
}

private func processID(_ process: VPSProcess = process()) -> String { CompanionServerStatusBuilder.opaqueID(process.id) }
private func workloadID(_ resource: VPSCoolifyResource = workload()) -> String { CompanionServerStatusBuilder.opaqueID(resource.id) }

/// A maintenance answer `ServerMaintenanceResult.parse` accepts for a scan.
private func planned(_ strategies: [String]) -> String {
    let disk = #"{"free_bytes":100,"total_bytes":200,"used_percent":50}"#
    let rows = strategies.map { #"{"id":"\#($0)","status":"planned","candidate_count":0,"removed_count":0,"attempted_count":0,"inventory_complete":true}"# }.joined(separator: ",")
    return #"{"schema_version":1,"tool":"hoghunter-server-maintenance","mode":"scan","manual":true,"dry_run":false,"pressure":false,"status":"planned","before":\#(disk),"after":\#(disk),"reclaimed_bytes":0,"observed_free_delta_bytes":0,"removed_file_bytes":0,"candidate_count":0,"strategies":[\#(rows)],"lock":{"acquired":false},"cancellation":{"requested":false},"duration_seconds":1}"#
}

private final class Seam: @unchecked Sendable {
    private let calls = CompanionLocked<[[String]]>([])
    private let hosts = CompanionLocked<[String]>([])
    let output: String
    init(output: String = #"{"ok":true}"#) { self.output = output }
    var arguments: [[String]] { calls.value }
    var called: Bool { !calls.value.isEmpty }
    var host: String? { hosts.value.last }
    func note(_ host: String, _ arguments: [String]) {
        calls.withLock { $0.append(arguments) }
        hosts.withLock { $0.append(host) }
    }
}

private final class AuditSink: @unchecked Sendable {
    private let stored = CompanionLocked<[CompanionServerActions.AuditEntry]>([])
    var entries: [CompanionServerActions.AuditEntry] { stored.value }
    func add(_ entry: CompanionServerActions.AuditEntry) { stored.withLock { $0.append(entry) } }
}

// MARK: - Who counts as Tailscale

final class CompanionTailscalePeerTests: XCTestCase {
    private func endpoint(_ host: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: 24240) }
    private let tunnel: () -> Set<String> = { ["100.100.1.1"] }

    func testBothEndsOverTheTunnelIsTailscale() {
        let remote = endpoint("100.100.1.2")
        let peer = CompanionPeer.from(remote).provingTailscaleArrival(remote: remote, local: endpoint("100.100.1.1"), tunnelAddresses: tunnel)
        XCTAssertTrue(peer.arrivedOverTailscale)
    }

    func testTailscaleIPv6IsTailscale() {
        let remote = endpoint("fd7a:115c:a1e0::2")
        let local = endpoint("fd7a:115c:a1e0::1")
        let key = CompanionPeer.addressKey(local)!
        let peer = CompanionPeer.from(remote).provingTailscaleArrival(remote: remote, local: local, tunnelAddresses: { [key] })
        XCTAssertTrue(peer.arrivedOverTailscale)
    }

    func testAPeerBuiltFromAnAddressAloneIsNot() {
        XCTAssertFalse(CompanionPeer.from(endpoint("100.100.1.2")).arrivedOverTailscale)
        XCTAssertFalse(CompanionPeer.forwarded("100.100.1.2").arrivedOverTailscale)
    }

    func testALocalNetworkPeerIsNot() {
        let remote = endpoint("192.168.1.20")
        let peer = CompanionPeer.from(remote).provingTailscaleArrival(remote: remote, local: endpoint("192.168.1.5"), tunnelAddresses: tunnel)
        XCTAssertTrue(peer.isTrusted)
        XCTAssertFalse(peer.arrivedOverTailscale)
    }

    func testAnOtherFdPrefixIsNot() {
        let remote = endpoint("fd00::2")
        let peer = CompanionPeer.from(remote).provingTailscaleArrival(remote: remote, local: endpoint("fd7a:115c:a1e0::1"), tunnelAddresses: { [CompanionPeer.addressKey(self.endpoint("fd7a:115c:a1e0::1"))!] })
        XCTAssertFalse(peer.arrivedOverTailscale)
    }

    /// A carrier's 100.64 address on the Mac's Wi-Fi is in the right range and
    /// on the wrong interface.
    func testACarrierAddressNotOnTheTunnelIsNot() {
        let remote = endpoint("100.64.0.9")
        let peer = CompanionPeer.from(remote).provingTailscaleArrival(remote: remote, local: endpoint("100.64.0.8"), tunnelAddresses: tunnel)
        XCTAssertFalse(peer.arrivedOverTailscale)
    }

    func testAnUnreadableLocalAddressIsNot() {
        let remote = endpoint("100.100.1.2")
        XCTAssertFalse(CompanionPeer.from(remote).provingTailscaleArrival(remote: remote, local: nil, tunnelAddresses: tunnel).arrivedOverTailscale)
    }

    func testAForwardedHeaderCannotClaimTailscale() {
        let request = Data("POST /v1/server/process HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 100.100.1.2\r\nCF-Connecting-IP: 100.100.1.2\r\n\r\n".utf8)
        let loopback = CompanionPeer(key: "127.0.0.1", isTrusted: true)
        XCTAssertFalse(loopback.resolvingForwardedClient(in: request).arrivedOverTailscale)
    }

    func testThePhoneDoesNotOfferControlsOverBonjourOrALocalAddress() {
        XCTAssertFalse(CompanionPeer.isTailscaleEndpoint(.service(name: "Mac", type: "_hoghunter._tcp", domain: "local", interface: nil)))
        XCTAssertFalse(CompanionPeer.isTailscaleEndpoint(endpoint("192.168.1.5")))
        XCTAssertFalse(CompanionPeer.isTailscaleEndpoint(endpoint("studio.local")))
        XCTAssertTrue(CompanionPeer.isTailscaleEndpoint(endpoint("studio.tail1234.ts.net")))
        XCTAssertTrue(CompanionPeer.isTailscaleEndpoint(endpoint("100.100.1.1")))
    }

    /// The proof depends on an accepted connection having a readable local
    /// address by the time its request arrives.  Ask a real socket.
    func testAnAcceptedConnectionHasAReadableLocalAddress() throws {
        let queue = DispatchQueue(label: "hoghunter.tests.tailscale")
        let listener = try NWListener(using: .tcp, on: .any)
        let received = expectation(description: "request received")
        let seen = CompanionLocked<NWEndpoint?>(nil)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, _, _ in
                seen.value = connection.currentPath?.localEndpoint
                connection.cancel()
                received.fulfill()
            }
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        client.stateUpdateHandler = { if case .ready = $0 { client.send(content: Data("x".utf8), completion: .idempotent) } }
        client.start(queue: queue)
        defer { client.cancel() }
        wait(for: [received], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(seen.value).debugDescription.hasPrefix("127.0.0.1"), true)
    }
}

// MARK: - Reading a request

final class CompanionServerActionParsingTests: XCTestCase {
    private let path = CompanionService.serverProcessPath
    private let id = "0123456789abcdef"

    private func parse(_ json: String, path: String? = nil) -> CompanionServerActionRequest? {
        CompanionHTTP.parseServerAction(path: path ?? self.path, body: Data(json.utf8))
    }

    func testTheShapesThatAreAccepted() {
        for action in CompanionServerControl.processActions {
            XCTAssertEqual(parse(#"{"rowId":"\#(id)","action":"\#(action)"}"#), .process(rowId: id, action: action))
        }
        for action in CompanionServerControl.workloadActions {
            XCTAssertEqual(parse(#"{"rowId":"\#(id)","action":"\#(action)"}"#, path: CompanionService.serverWorkloadPath), .workload(rowId: id, action: action))
        }
        XCTAssertEqual(parse(#"{"mode":"scan","strategies":["package-cache"]}"#, path: CompanionService.serverMaintainPath),
                       .maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false))
    }

    func testEveryBadRequestIsNil() {
        let bad = [
            "", "[]", "null", "not json",
            #"{}"#,
            #"{"rowId":"\#(id)"}"#,
            #"{"action":"quit"}"#,
            #"{"rowId":"\#(id)","action":"reboot"}"#,
            #"{"rowId":"\#(id)","action":"stop"}"#,
            #"{"rowId":"\#(id)","action":"Quit"}"#,
            #"{"rowId":"\#(id)","action":1}"#,
            #"{"rowId":4242,"action":"quit"}"#,
            #"{"rowId":"4242","action":"quit"}"#,
            #"{"rowId":"0123456789ABCDEF","action":"quit"}"#,
            #"{"rowId":"; rm -rf /;      ","action":"quit"}"#,
            #"{"rowId":"\#(id)","action":"quit","host":"evil"}"#,
            #"{"rowId":"\#(id)","action":"quit","pid":1}"#,
            #"{"rowId":"\#(id)","action":"quit","command":"x"}"#,
            #"{"rowId":"\#(id)","action":"quit","action":"forceQuit"}"#,
            #"{"rowId":"\#(id)","rowId":"\#(id)","action":"quit"}"#,
            #"{"rowId":"\#(id)","action":"quit","action":"quit"}"#,
            #"{"rowId":"\#(id)","action":"quit"} trailing"#,
        ]
        for json in bad {
            XCTAssertNil(parse(json), json)
        }
    }

    func testBadMaintenanceRequestsAreNil() {
        let bad = [
            #"{"mode":"scan"}"#,
            #"{"strategies":["package-cache"]}"#,
            #"{"mode":"nuke","strategies":["package-cache"]}"#,
            #"{"mode":"scan","strategies":[]}"#,
            #"{"mode":"scan","strategies":"package-cache"}"#,
            #"{"mode":"scan","strategies":["/etc"]}"#,
            #"{"mode":"scan","strategies":["package-cache","package-cache"]}"#,
            #"{"mode":"scan","mode":"run","strategies":["package-cache"]}"#,
            #"{"mode":"scan","strategies":["package-cache"],"host":"evil"}"#,
            #"{"mode":"scan","strategies":["package-cache"],"acknowledgeImageRemoval":true}"#,
            #"{"mode":"run","strategies":["package-cache"],"acknowledgeImageRemoval":true}"#,
        ]
        for json in bad {
            XCTAssertNil(parse(json, path: CompanionService.serverMaintainPath), json)
        }
    }

    func testRemovingImagesNeedsALiteralTrue() {
        let path = CompanionService.serverMaintainPath
        XCTAssertNil(parse(#"{"mode":"run","strategies":["docker-images"]}"#, path: path))
        XCTAssertNil(parse(#"{"mode":"run","strategies":["docker-images"],"acknowledgeImageRemoval":false}"#, path: path))
        XCTAssertNil(parse(#"{"mode":"run","strategies":["docker-images"],"acknowledgeImageRemoval":1}"#, path: path))
        XCTAssertNil(parse(#"{"mode":"run","strategies":["docker-images"],"acknowledgeImageRemoval":"true"}"#, path: path))
        XCTAssertEqual(parse(#"{"mode":"run","strategies":["docker-images"],"acknowledgeImageRemoval":true}"#, path: path),
                       .maintain(mode: "run", strategies: ["docker-images"], imageRemovalAcknowledged: true))
        XCTAssertEqual(parse(#"{"mode":"scan","strategies":["docker-images"]}"#, path: path),
                       .maintain(mode: "scan", strategies: ["docker-images"], imageRemovalAcknowledged: false), "a scan changes nothing")
    }

    func testWhatThePhoneSendsIsWhatTheMacReads() {
        let requests: [CompanionServerActionRequest] = [
            .process(rowId: id, action: "forceQuit"),
            .workload(rowId: id, action: "restart"),
            .maintain(mode: "scan", strategies: ["docker-images", "package-cache"], imageRemovalAcknowledged: false),
            .maintain(mode: "run", strategies: ["docker-images"], imageRemovalAcknowledged: true),
        ]
        for request in requests {
            XCTAssertEqual(CompanionHTTP.parseServerAction(path: request.path, body: request.body), request)
        }
    }
}

// MARK: - The routes

final class CompanionServerControlRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)
    private let tailnet = CompanionPeer(key: "100.100.1.2", isTrusted: true, arrivedOverTailscale: true)
    /// The address is right and nothing proved it, which is how a forwarded
    /// client or a carrier's address looks.
    private let unprovenTailnet = CompanionPeer(key: "100.100.1.2", isTrusted: true)
    private let loopback = CompanionPeer(key: "127.0.0.1", isTrusted: true)
    private let id = "0123456789abcdef"

    private func server(on: Bool = true) -> (CompanionServer, String, CompanionLocked<Int>) {
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteServerControl = on
        let calls = CompanionLocked(0)
        server.onRemoteServerAction = { _, _, completion in
            calls.withLock { $0 += 1 }
            completion((200, Data("{}".utf8)))
        }
        server.syncOnQueue {}
        return (server, token, calls)
    }

    private func request(_ action: CompanionServerActionRequest? = nil, token: String) -> Data {
        CompanionHTTP.serverActionRequest(token: token, action: action ?? .process(rowId: id, action: "quit"))
    }

    private func raw(path: String, body: String, token: String) -> Data {
        let lines = ["POST \(path) HTTP/1.1", "Host: x", "Authorization: Bearer \(token)", "Content-Length: \(body.utf8.count)", "", body]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func reply(_ server: CompanionServer, _ data: Data, from peer: CompanionPeer) -> (status: Int, response: CompanionServerActionResponse?)? {
        guard case .reply(let reply) = server.syncOnQueue({ server.disposition(for: data, peer: peer) }),
              let parsed = CompanionHTTP.parseResponse(reply) else { return nil }
        return (parsed.status, try? JSONDecoder().decode(CompanionServerActionResponse.self, from: parsed.body))
    }

    func testAPhonesOwnTokenOverTailscaleIsAccepted() {
        let (server, token, _) = server()
        let disposition = server.syncOnQueue { server.disposition(for: request(token: token), peer: tailnet) }
        XCTAssertEqual(disposition, .startServerAction(.process(rowId: id, action: "quit"), device: "Test iPhone"))
    }

    func testEveryRouteGoesThroughTheSameGate() {
        let actions: [CompanionServerActionRequest] = [
            .process(rowId: id, action: "quit"),
            .workload(rowId: id, action: "stop"),
            .maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false),
        ]
        for action in actions {
            let (off, token, offCalls) = server(on: false)
            XCTAssertEqual(reply(off, request(action, token: token), from: tailnet)?.status, 403)
            XCTAssertEqual(offCalls.value, 0)
            let (on, onToken, _) = server()
            let refused = reply(on, request(action, token: onToken), from: lan)
            XCTAssertEqual(refused?.status, 403)
            XCTAssertEqual(refused?.response?.status, "tailscaleRequired")
        }
    }

    func testOffIsAReadable403() {
        let (server, token, calls) = server(on: false)
        let refused = reply(server, request(token: token), from: tailnet)
        XCTAssertEqual(refused?.status, 403)
        XCTAssertEqual(refused?.response?.status, "forbidden")
        XCTAssertEqual(refused?.response?.error, CompanionServerControl.optInNote)
        XCTAssertEqual(calls.value, 0)
    }

    func testALocalNetworkPeerIsToldToUseTailscale() {
        let (server, token, calls) = server()
        let refused = reply(server, request(token: token), from: lan)
        XCTAssertEqual(refused?.status, 403)
        XCTAssertEqual(refused?.response?.error, CompanionServerControl.tailscaleOnlyNote)
        XCTAssertTrue(refused?.response?.error?.contains("Tailscale address") == true)
        XCTAssertEqual(calls.value, 0)
    }

    func testAnUnprovenTailscaleAddressAndLoopbackAreRefused() {
        let (server, token, calls) = server()
        XCTAssertEqual(reply(server, request(token: token), from: unprovenTailnet)?.response?.status, "tailscaleRequired")
        XCTAssertEqual(reply(server, request(token: token), from: loopback)?.response?.status, "tailscaleRequired")
        XCTAssertEqual(calls.value, 0)
    }

    func testAForwardedClientNamingATailscaleAddressIsRefused() {
        let (server, token, calls) = server()
        let lines = ["POST \(CompanionService.serverProcessPath) HTTP/1.1", "Host: x", "Authorization: Bearer \(token)", "X-Forwarded-For: 100.100.1.2", "", ""]
        let data = Data(lines.joined(separator: "\r\n").utf8)
        let peer = loopback.resolvingForwardedClient(in: data)
        XCTAssertEqual(reply(server, data, from: peer)?.status, 403)
        XCTAssertEqual(calls.value, 0)
    }

    func testAnOutsidePeerIsRefused() {
        let (server, token, calls) = server()
        XCTAssertEqual(reply(server, request(token: token), from: wan)?.status, 403)
        XCTAssertEqual(calls.value, 0)
    }

    func testTheSharedCodeIsRefusedEvenOverTailscale() {
        let (server, _, calls) = server()
        XCTAssertEqual(reply(server, request(token: code), from: tailnet)?.status, 403)
        XCTAssertEqual(calls.value, 0)
    }

    func testAWrongCredentialIs401AndCountsAgainstTheThrottle() {
        let (server, _, calls) = server()
        var statuses: [Int] = []
        for _ in 0..<12 {
            if let status = reply(server, request(token: "hh1_wrong"), from: tailnet)?.status { statuses.append(status) }
        }
        XCTAssertEqual(statuses.first, 401)
        XCTAssertEqual(statuses.last, 429, "the existing throttle answers once it has seen enough")
        XCTAssertEqual(calls.value, 0)
    }

    func testAGetIsRefused() {
        let (server, token, calls) = server()
        let lines = ["GET \(CompanionService.serverProcessPath) HTTP/1.1", "Host: x", "Authorization: Bearer \(token)", "", ""]
        XCTAssertEqual(reply(server, Data(lines.joined(separator: "\r\n").utf8), from: tailnet)?.status, 405)
        XCTAssertEqual(calls.value, 0)
    }

    func testABadBodyIs400AndAQueryIsRefused() {
        let (server, token, calls) = server()
        let path = CompanionService.serverProcessPath
        for body in [#"{"rowId":"\#(id)","action":"reboot"}"#, #"{"rowId":"\#(id)","action":"quit","host":"evil"}"#, #"{"rowId":"\#(id)","action":"quit","action":"sample"}"#, ""] {
            let refused = reply(server, raw(path: path, body: body, token: token), from: tailnet)
            XCTAssertEqual(refused?.status, 400, body)
            XCTAssertEqual(refused?.response?.status, "rejected")
        }
        let query = raw(path: path + "?host=evil", body: #"{"rowId":"\#(id)","action":"quit"}"#, token: token)
        XCTAssertEqual(reply(server, query, from: tailnet)?.status, 400)
        XCTAssertEqual(calls.value, 0)
    }

    func testAnImageRunWithoutTheAcknowledgementDoesNothing() {
        let (server, token, calls) = server()
        let body = #"{"mode":"run","strategies":["docker-images"]}"#
        XCTAssertEqual(reply(server, raw(path: CompanionService.serverMaintainPath, body: body, token: token), from: tailnet)?.status, 400)
        XCTAssertEqual(calls.value, 0)
    }

    func testOneActionAtATime() {
        let (server, token, _) = server()
        let first = server.syncOnQueue { server.disposition(for: request(token: token), peer: tailnet) }
        guard case .startServerAction(let accepted, let device) = first else { return XCTFail("the first is accepted") }
        let second = reply(server, request(token: token), from: tailnet)
        XCTAssertEqual(second?.status, 409)
        XCTAssertEqual(second?.response?.status, "busy")
        // A different route waits too: there is one slot.
        XCTAssertEqual(reply(server, request(.workload(rowId: id, action: "stop"), token: token), from: tailnet)?.status, 409)

        let finished = expectation(description: "finished")
        server.runServerAction(accepted, device: device) { _ in finished.fulfill() }
        wait(for: [finished], timeout: 2)
        guard case .startServerAction = server.syncOnQueue({ server.disposition(for: request(token: token), peer: tailnet) }) else {
            return XCTFail("the slot is free again")
        }
    }

    func testTheSlotIsNotFreedUntilTheActionEnds() {
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteServerControl = true
        let held = CompanionLocked<(@Sendable (CompanionServer.Reply) -> Void)?>(nil)
        server.onRemoteServerAction = { _, _, completion in held.value = completion }
        server.syncOnQueue {}
        guard case .startServerAction(let accepted, let device) = server.syncOnQueue({ server.disposition(for: request(token: token), peer: tailnet) }) else {
            return XCTFail("accepted")
        }
        server.runServerAction(accepted, device: device) { _ in }
        XCTAssertEqual(reply(server, request(token: token), from: tailnet)?.status, 409, "still running, whatever the phone's connection did")
        held.value?((200, Data()))
        guard case .startServerAction = server.syncOnQueue({ server.disposition(for: request(token: token), peer: tailnet) }) else {
            return XCTFail("free once it ends")
        }
    }

    func testServerMaintenanceWaitsForAMaintainRun() {
        let (server, token, calls) = server()
        server.maintainRunning = true
        let action = CompanionServerActionRequest.maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false)
        XCTAssertEqual(reply(server, request(action, token: token), from: tailnet)?.status, 409)
        XCTAssertEqual(calls.value, 0)
    }

    func testARefusalAtTheGateIsLoggedWithoutTheToken() {
        let (server, token, _) = server()
        let heard = CompanionLocked<[String]>([])
        server.onServerControlRefused = { device, path, outcome in heard.withLock { $0.append("\(device)|\(path)|\(outcome)") } }
        _ = reply(server, request(token: token), from: lan)
        XCTAssertEqual(heard.value, ["Test iPhone|\(CompanionService.serverProcessPath)|refused: not on Tailscale"])
    }

    func testTheOtherRoutesStillAcceptTheLocalNetwork() {
        let (server, token, _) = server()
        server.update(snapshot: CompanionTestSnapshots.plain())
        server.syncOnQueue {}
        guard case .reply(let data) = server.syncOnQueue({ server.disposition(for: CompanionHTTP.request(token: token), peer: lan) }) else { return XCTFail("reply") }
        XCTAssertEqual(CompanionHTTP.parseResponse(data)?.status, 200)
    }
}

// MARK: - What the Mac does with a request

@MainActor
final class CompanionServerActionsTests: XCTestCase {
    private func make(
        reading snapshot: VPSStatusSnapshot?,
        host: String = "server.tailnet",
        control seam: Seam = Seam(),
        maintenance maintenanceOutput: String? = nil,
        maintainRunning: Bool = false
    ) async throws -> (actions: CompanionServerActions, control: Seam, maintenance: Seam, audit: AuditSink, vps: VPSStatusStore) {
        let vps = VPSStatusStore(fetcher: { _ in
            guard let snapshot else { throw NSError(domain: "test", code: 1, userInfo: nil) }
            return snapshot
        }, history: SizeGrowthHistory(fileURL: nil))
        addTeardownBlock { await MainActor.run { vps.stopPolling() } }
        if !host.isEmpty {
            vps.setHost(host)
            for _ in 0..<200 where snapshot != nil && vps.snapshot == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let maintenanceSeam = Seam(output: maintenanceOutput ?? "{}")
        let control = ServerControl(runner: { host, arguments in
            seam.note(host, arguments)
            return seam.output
        })
        let maintenance = ServerMaintenanceControl(runner: { host, arguments in
            maintenanceSeam.note(host, arguments)
            return ServerMaintenanceResponse(exitCode: 0, output: maintenanceSeam.output)
        })
        let sink = AuditSink()
        let actions = CompanionServerActions(vps: vps, control: control, maintenance: maintenance,
                                             isMaintainRunning: { maintainRunning }, audit: { sink.add($0) })
        return (actions, seam, maintenanceSeam, sink, vps)
    }

    private func decode(_ reply: CompanionServer.Reply) throws -> CompanionServerActionResponse {
        try JSONDecoder().decode(CompanionServerActionResponse.self, from: reply.body)
    }

    // The arguments are the Mac's own.

    func testTheMacBuildsEveryArgumentFromItsOwnReading() async throws {
        let setup = try await make(reading: reading())
        let reply = await setup.actions.perform(.process(rowId: processID(), action: "forceQuit"), device: "Test iPhone")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(setup.control.host, "server.tailnet")
        XCTAssertEqual(setup.control.arguments.first, ["sudo", "-n", "/usr/local/sbin/hoghunter-control", "stop-process", "--pid", "4242", "--start-time", "987654", "--boot-id", "boot-1", "--confirm", "--force"])
        XCTAssertEqual(try decode(reply).status, "acted")
    }

    func testEachProcessActionReachesItsVerb() async throws {
        let expected = ["quit": "stop-process", "tame": "tame-process", "untame": "untame-process"]
        for (action, verb) in expected {
            let setup = try await make(reading: reading())
            let reply = await setup.actions.perform(.process(rowId: processID(), action: action), device: "d")
            XCTAssertEqual(reply.status, 200, action)
            XCTAssertTrue(setup.control.arguments.first?.contains(verb) == true, action)
        }
    }

    func testAProcessInAWorkloadAddsTheInterruptionFlagTheMacWould() async throws {
        let row = process(container: "orders-db")
        let setup = try await make(reading: reading(processes: [row]))
        _ = await setup.actions.perform(.process(rowId: processID(row), action: "quit"), device: "d")
        XCTAssertTrue(setup.control.arguments.first?.contains("--allow-workload-interruption") == true)
    }

    func testASampleComesBackOnlyInTheReply() async throws {
        let output = #"{"ok":true,"action":"sample","sample":{"pid":4242,"duration_seconds":3,"state":"canary-internal"}}"#
        let setup = try await make(reading: reading(), control: Seam(output: output))
        let reply = await setup.actions.perform(.process(rowId: processID(), action: "sample"), device: "d")
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(try decode(reply).sampleText?.contains("canary-internal") == true)
        XCTAssertFalse(setup.audit.entries.description.contains("canary-internal"), "the log says what was done, not what it found")
    }

    func testEachWorkloadActionReachesItsVerb() async throws {
        for action in CompanionServerControl.workloadActions {
            let setup = try await make(reading: reading())
            let reply = await setup.actions.perform(.workload(rowId: workloadID(), action: action), device: "d")
            XCTAssertEqual(reply.status, 200, action)
            XCTAssertEqual(setup.control.arguments.first, ["sudo", "-n", "/usr/local/sbin/hoghunter-control", action + "-container", "--name", "container-1", "--container-id", fortyHex, "--started-at", "2026-11-04T00:00:00Z", "--confirm", "--allow-workload-interruption"])
        }
    }

    // Refusals do nothing.

    func testAnUnknownRowDoesNothing() async throws {
        let setup = try await make(reading: reading())
        let reply = await setup.actions.perform(.process(rowId: "ffffffffffffffff", action: "quit"), device: "d")
        XCTAssertEqual(reply.status, 409)
        XCTAssertEqual(try decode(reply).status, "changed")
        XCTAssertFalse(setup.control.called)
        let workloadReply = await setup.actions.perform(.workload(rowId: "ffffffffffffffff", action: "stop"), device: "d")
        XCTAssertEqual(try decode(workloadReply).status, "changed")
        XCTAssertFalse(setup.control.called)
    }

    func testARowFromTheOtherKindDoesNothing() async throws {
        let setup = try await make(reading: reading())
        let reply = await setup.actions.perform(.workload(rowId: processID(), action: "stop"), device: "d")
        XCTAssertEqual(try decode(reply).status, "changed")
        XCTAssertFalse(setup.control.called)
    }

    func testARowThePhoneCouldNotSeeDoesNothing() async throws {
        let many = (0..<20).map { index in
            VPSProcess(pid: 100 + index, name: "p\(index)", startTime: 5, owner: nil, container: nil, cpuPercent: 1, memoryBytes: 1, bootID: "b", allowedActions: ["quit"])
        }
        let setup = try await make(reading: reading(processes: many))
        let hidden = processID(many[CompanionServerStatusBuilder.processLimit])
        let reply = await setup.actions.perform(.process(rowId: hidden, action: "quit"), device: "d")
        XCTAssertEqual(try decode(reply).status, "changed")
        XCTAssertFalse(setup.control.called)
    }

    func testAStaleReadingDoesNothing() async throws {
        let setup = try await make(reading: reading(age: CompanionServerStatus.staleAfter + 60))
        for request: CompanionServerActionRequest in [
            .process(rowId: processID(), action: "quit"),
            .workload(rowId: workloadID(), action: "stop"),
            .maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false),
        ] {
            let reply = await setup.actions.perform(request, device: "d")
            XCTAssertEqual(reply.status, 409)
            XCTAssertEqual(try decode(reply).status, "stale")
        }
        XCTAssertFalse(setup.control.called)
        XCTAssertFalse(setup.maintenance.called)
    }

    func testNoReadingAndNoServerDoNothing() async throws {
        let waiting = try await make(reading: nil)
        let noReading = await waiting.actions.perform(.process(rowId: processID(), action: "quit"), device: "d")
        XCTAssertEqual(try decode(noReading).status, "stale")
        XCTAssertFalse(waiting.control.called)
        let none = try await make(reading: nil, host: "")
        let noServer = await none.actions.perform(.maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false), device: "d")
        XCTAssertEqual(try decode(noServer).status, "stale")
        XCTAssertFalse(none.maintenance.called)
    }

    func testAProtectedProcessIsRefusedOnTheMac() async throws {
        let row = process(actions: [], reason: "Host infrastructure")
        let setup = try await make(reading: reading(processes: [row]))
        let reply = await setup.actions.perform(.process(rowId: processID(row), action: "quit"), device: "d")
        XCTAssertEqual(reply.status, 403)
        let response = try decode(reply)
        XCTAssertEqual(response.status, "protected")
        XCTAssertEqual(response.error, "Host infrastructure")
        XCTAssertFalse(setup.control.called)
    }

    func testAnActionTheRowDoesNotAllowIsRefusedEvenIfOthersAre() async throws {
        let row = process(actions: ["sample"])
        let setup = try await make(reading: reading(processes: [row]))
        let reply = await setup.actions.perform(.process(rowId: processID(row), action: "forceQuit"), device: "d")
        XCTAssertEqual(reply.status, 403)
        XCTAssertFalse(setup.control.called)
    }

    func testAProtectedWorkloadIsRefusedOnTheMac() async throws {
        let row = workload(actions: [], reason: "Protected database")
        let setup = try await make(reading: reading(workloads: [row]))
        let reply = await setup.actions.perform(.workload(rowId: workloadID(row), action: "stop"), device: "d")
        XCTAssertEqual(reply.status, 403)
        XCTAssertEqual(try decode(reply).error, "Protected database")
        XCTAssertFalse(setup.control.called)
    }

    func testARowWithNoCurrentIdentityIsRefused() async throws {
        let row = VPSProcess(pid: 1, name: "old", startTime: nil, owner: nil, container: nil, cpuPercent: 1, memoryBytes: 1, allowedActions: ["quit"])
        let setup = try await make(reading: reading(processes: [row]))
        let reply = await setup.actions.perform(.process(rowId: processID(row), action: "quit"), device: "d")
        XCTAssertEqual(reply.status, 403)
        XCTAssertFalse(setup.control.called)
    }

    func testTheServersOwnRefusalIsPassedOn() async throws {
        let setup = try await make(reading: reading(), control: Seam(output: #"{"ok":false,"reason":"The process changed."}"#))
        let reply = await setup.actions.perform(.process(rowId: processID(), action: "quit"), device: "d")
        XCTAssertEqual(reply.status, 409)
        XCTAssertEqual(try decode(reply).error, "The process changed.")
    }

    // Maintenance.

    func testAScanRunsWithoutConfirmAndChangesNothing() async throws {
        let setup = try await make(reading: reading(), maintenance: planned(["package-cache"]))
        let reply = await setup.actions.perform(.maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false), device: "d")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(setup.maintenance.arguments.first, ["sudo", "-n", "/usr/local/sbin/hoghunter-maintain", "scan", "--manual", "--strategy", "package-cache"])
        XCTAssertEqual(try decode(reply).maintenance?.status, "planned")
    }

    func testARunWithImagesAndNoAcknowledgementDoesNothing() async throws {
        let setup = try await make(reading: reading())
        let reply = await setup.actions.perform(.maintain(mode: "run", strategies: ["docker-images"], imageRemovalAcknowledged: false), device: "d")
        XCTAssertEqual(reply.status, 400)
        XCTAssertFalse(setup.maintenance.called)
    }

    func testARunWithTheAcknowledgementReachesTheServerWithConfirm() async throws {
        let setup = try await make(reading: reading())
        _ = await setup.actions.perform(.maintain(mode: "run", strategies: ["docker-images"], imageRemovalAcknowledged: true), device: "d")
        XCTAssertEqual(setup.maintenance.arguments.first, ["sudo", "-n", "/usr/local/sbin/hoghunter-maintain", "run", "--manual", "--strategy", "docker-images", "--confirm"])
    }

    func testAnUnreadableMaintenanceAnswerIsUnconfirmedNotDone() async throws {
        let setup = try await make(reading: reading(), maintenance: "not json")
        let reply = await setup.actions.perform(.maintain(mode: "run", strategies: ["package-cache"], imageRemovalAcknowledged: false), device: "d")
        XCTAssertEqual(reply.status, 502)
        XCTAssertEqual(try decode(reply).status, "failed")
    }

    func testAMaintainRunOnTheMacBlocksServerMaintenance() async throws {
        let setup = try await make(reading: reading(), maintainRunning: true)
        let reply = await setup.actions.perform(.maintain(mode: "scan", strategies: ["package-cache"], imageRemovalAcknowledged: false), device: "d")
        XCTAssertEqual(reply.status, 409)
        XCTAssertFalse(setup.maintenance.called)
    }

    // The log.

    func testEachActionIsLoggedWithDeviceActionRowAndOutcome() async throws {
        let setup = try await make(reading: reading())
        _ = await setup.actions.perform(.process(rowId: processID(), action: "quit"), device: "Test iPhone")
        _ = await setup.actions.perform(.process(rowId: "ffffffffffffffff", action: "tame"), device: "Test iPhone")
        XCTAssertEqual(setup.audit.entries, [
            .init(device: "Test iPhone", action: "process quit", row: rowName, outcome: "acted"),
            .init(device: "Test iPhone", action: "process tame", row: "", outcome: "unknown row"),
        ])
    }

    // The block the phone reads.

    func testTheBlockOffersOnlyWhatTheMacWouldAccept() {
        let status = CompanionServerStatusBuilder.make(
            configuredHost: "h",
            snapshot: reading(processes: [process(actions: ["quit", "force-quit"]), process("guarded", actions: [], reason: "Host infrastructure")],
                              workloads: [workload(actions: ["restart"])]),
            error: nil, fetchedAt: nil, cpuHistory: [],
            databaseChange: { _ in nil }, directoryChange: { _ in nil }
        )
        XCTAssertEqual(status.processes?.first?.actions, ["quit", "forceQuit"], "in the phone's words")
        XCTAssertEqual(status.processes?.last?.actions, [])
        XCTAssertEqual(status.workloads?.first?.actions, ["restart"])
    }
}

// MARK: - The opt-in, from the store

@MainActor
final class CompanionServerControlOptInTests: XCTestCase {
    private func store(defaults: UserDefaults) throws -> HogStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-server-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let maintain = MaintainStore(supportDirectory: directory, repoRoot: directory, launcher: { _ in
            XCTFail("a test must not launch the script")
            return true
        }, infisical: IsolatedInfisical.make(), vpsFetcher: { _ in throw NSError(domain: "test", code: 1, userInfo: nil) })
        let failing: ServerControl.Runner = { _, _ in
            XCTFail("a test must not reach the server")
            return ""
        }
        return HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), maintain: maintain,
                        startImmediately: false, serverControl: ServerControl(runner: failing))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "hoghunter-server-control-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testItIsOffByDefault() throws {
        let store = try store(defaults: defaults())
        XCTAssertFalse(store.allowRemoteServerControl)
        XCTAssertFalse(store.serverControlAllowedOnRouter)
        XCTAssertEqual(store.companionSnapshots().plain.remoteServerControlAllowed, false)
    }

    func testItNeedsServerStatusToo() throws {
        let store = try store(defaults: defaults())
        store.allowRemoteServerControl = true
        XCTAssertFalse(store.serverControlAllowedOnRouter, "a phone that cannot see a row cannot address it")
        XCTAssertEqual(store.companionSnapshots().plain.remoteServerControlAllowed, false)

        store.allowRemoteServerStatus = true
        XCTAssertTrue(store.serverControlAllowedOnRouter)
        XCTAssertEqual(store.companionSnapshots().plain.remoteServerControlAllowed, true)

        store.allowRemoteServerStatus = false
        XCTAssertFalse(store.serverControlAllowedOnRouter, "turning status off takes control with it")
    }

    func testItIsOnWithStatusAloneNever() throws {
        let store = try store(defaults: defaults())
        store.allowRemoteServerStatus = true
        XCTAssertFalse(store.serverControlAllowedOnRouter)
    }

    func testItSurvivesARestart() throws {
        let shared = try defaults()
        let first = try store(defaults: shared)
        first.allowRemoteServerStatus = true
        first.allowRemoteServerControl = true
        let second = try store(defaults: shared)
        XCTAssertTrue(second.serverControlAllowedOnRouter)
    }
}
