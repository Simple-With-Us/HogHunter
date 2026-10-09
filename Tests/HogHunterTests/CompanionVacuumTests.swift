import XCTest

@testable import HogHunter

// Phone parity, batch 2, PR C: Robotic Vacuum status and Run Now.
//
// Nothing here runs the real script.  Every store is built with a stub
// launcher, and the default launcher refuses to start inside XCTest, so a test
// that forgot a stub would fail instead of cleaning this Mac.

/// A throwaway history database, so a store built in a test never opens the
/// owner's real one.
func isolatedHistoryURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-test-history-\(UUID().uuidString).sqlite")
}

// MARK: - The route

final class CompanionVacuumRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private var deviceToken = ""
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)

    private func server(vacuum: Bool, running: Bool = false) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteVacuum = vacuum
        server.vacuumRunning = running
        server.syncOnQueue {}
        return server
    }

    private func reply(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer? = nil) -> (status: Int, body: Data)? {
        let disposition = server.syncOnQueue { server.disposition(for: request, peer: peer ?? lan) }
        guard case .reply(let data) = disposition else { return nil }
        return CompanionHTTP.parseResponse(data)
    }

    private func status(_ server: CompanionServer, _ request: Data, from peer: CompanionPeer? = nil) -> Int? {
        reply(server, request, from: peer)?.status
    }

    private func errorText(_ body: Data) throws -> String {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["error"] as? String)
    }

    /// A request with a hand-written query, so a test can send what a real
    /// request builder would never produce.
    private func rawRequest(query: String, token: String? = nil, method: String = "POST") -> Data {
        let lines = [
            "\(method) \(CompanionService.vacuumRunPath)\(query) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token ?? deviceToken)",
            "Connection: close",
            "",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    func testTheRunIsRefusedUntilTheOwnerAllowsIt() throws {
        let server = server(vacuum: false)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        let parsed = try XCTUnwrap(reply(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)))
        XCTAssertEqual(parsed.status, 403)
        let message = try errorText(parsed.body)
        XCTAssertTrue(message.contains("Allow iPhone to Run Robotic Vacuum"), message)
        XCTAssertTrue(message.contains("\u{00A0}"), "the gap between the sentences must not collapse on the phone: \(message)")
        XCTAssertFalse(server.vacuumRunning, "a refused request must not mark a run as going")
    }

    func testTheOtherOptInsDoNotOpenIt() {
        let server = server(vacuum: false)
        server.allowRemoteQuit = true
        server.allowRemoteClean = true
        server.allowRemoteEdit = true
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 403)
    }

    func testTheRunIsRefusedFromAnUntrustedAddress() {
        let server = server(vacuum: true)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken), from: wan), 403)
    }

    func testTheRunIsRefusedWithTheSharedCode() {
        let server = server(vacuum: true)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: code)), 403)
    }

    func testTheRunIsRefusedWithAWrongToken() {
        let server = server(vacuum: true)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: "hh1_wrong")), 401)
    }

    func testOnlyPostStartsARun() {
        let server = server(vacuum: true)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        XCTAssertEqual(status(server, rawRequest(query: "?kind=full", method: "GET")), 405)
        XCTAssertEqual(status(server, rawRequest(query: "?kind=full", method: "DELETE")), 405)
    }

    func testOnlyTheFullRunCanBeAskedFor() {
        let server = server(vacuum: true)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        // The script accepts janitor, watch and pressure too.  None is on offer.
        for query in ["?kind=janitor", "?kind=watch", "?kind=pressure", "?kind=Full", "?kind=FULL", "?kind=", "?kind", "?kind=full%20", "?kind=full&kind=janitor", "?kind=janitor&kind=full", "?kind=../full"] {
            XCTAssertEqual(status(server, rawRequest(query: query)), 400, query)
        }
        XCTAssertFalse(server.vacuumRunning)
    }

    func testABadKindIsRefusedWithAReasonAndTheGap() throws {
        let server = server(vacuum: true)
        let parsed = try XCTUnwrap(reply(server, rawRequest(query: "?kind=janitor")))
        XCTAssertEqual(parsed.status, 400)
        let message = try errorText(parsed.body)
        XCTAssertTrue(message.contains("\u{00A0}"), message)
        XCTAssertFalse(message.contains(".  "), message)
    }

    func testAnAbsentKindMeansFull() {
        let server = server(vacuum: true)
        let kind = CompanionLocked<String?>(nil)
        server.onRemoteVacuumRun = { kind.value = $0; return (202, Data("{}".utf8)) }
        XCTAssertEqual(status(server, rawRequest(query: "")), 202)
        XCTAssertEqual(kind.value, "full")
    }

    func testABareQuestionMarkMeansFullAndDoesNotTrap() {
        let server = server(vacuum: true)
        let kind = CompanionLocked<String?>(nil)
        server.onRemoteVacuumRun = { kind.value = $0; return (202, Data("{}".utf8)) }
        for query in ["?", "?&", "?other=1"] {
            kind.value = nil
            server.vacuumRunning = false   // the router marks a run going when it accepts one
            XCTAssertEqual(status(server, rawRequest(query: query)), 202, query)
            XCTAssertEqual(kind.value, "full", query)
        }
    }

    func testAnEncodedFullIsStillFull() {
        let server = server(vacuum: true)
        let kind = CompanionLocked<String?>(nil)
        server.onRemoteVacuumRun = { kind.value = $0; return (202, Data("{}".utf8)) }
        XCTAssertEqual(status(server, rawRequest(query: "?kind=fu%6Cl")), 202)
        XCTAssertEqual(kind.value, "full")
    }

    func testTheRequestBuilderAsksForTheFullRun() {
        let text = String(data: CompanionHTTP.vacuumRunRequest(token: "hh1_x"), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("POST /v1/vacuum/run?kind=full HTTP/1.1\r\n"), text)
        XCTAssertTrue(text.contains("Authorization: Bearer hh1_x\r\n"))
    }

    func testTheRunReachesTheHandlerOnceAllowed() throws {
        let server = server(vacuum: true)
        let kinds = CompanionLocked<[String]>([])
        server.onRemoteVacuumRun = { kind in
            kinds.value.append(kind)
            return (202, Data(#"{"status":"started"}"#.utf8))
        }
        let parsed = try XCTUnwrap(reply(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)))
        XCTAssertEqual(parsed.status, 202)
        XCTAssertEqual(try JSONDecoder().decode(CompanionVacuumRunResponse.self, from: parsed.body).status, "started")
        XCTAssertEqual(kinds.value, ["full"])
        XCTAssertTrue(server.vacuumRunning, "the router marks the run as going when it accepts it")
    }

    func testARunThatIsGoingAnswersBusyWithoutReachingTheHandler() throws {
        let server = server(vacuum: true, running: true)
        server.onRemoteVacuumRun = { _ in XCTFail("must not reach the handler"); return (202, Data()) }
        let parsed = try XCTUnwrap(reply(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)))
        XCTAssertEqual(parsed.status, 409)
        let busy = try JSONDecoder().decode(CompanionVacuumRunResponse.self, from: parsed.body)
        XCTAssertEqual(busy.status, "busy")
        XCTAssertTrue(busy.error?.contains("\u{00A0}") ?? false, busy.error ?? "")
    }

    func testTwoQuickTapsStartOneRun() {
        let server = server(vacuum: true)
        let calls = CompanionLocked(0)
        server.onRemoteVacuumRun = { _ in calls.value += 1; return (202, Data(#"{"status":"started"}"#.utf8)) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 202)
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 409)
        XCTAssertEqual(calls.value, 1)
    }

    func testARunStartsAgainOnceTheHostSaysItFinished() {
        let server = server(vacuum: true)
        let calls = CompanionLocked(0)
        server.onRemoteVacuumRun = { _ in calls.value += 1; return (202, Data("{}".utf8)) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 202)
        server.vacuumRunning = false
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 202)
        XCTAssertEqual(calls.value, 2)
    }

    func testAHandlerThatFailsDoesNotLeaveTheRunMarkedAsGoing() {
        let server = server(vacuum: true)
        server.onRemoteVacuumRun = { _ in (500, Data(#"{"error":"Store unavailable"}"#.utf8)) }
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 500)
        XCTAssertFalse(server.vacuumRunning)
    }

    func testMissingHandlerIsNotImplementedAndLeavesNothingRunning() {
        let server = server(vacuum: true)
        XCTAssertEqual(status(server, CompanionHTTP.vacuumRunRequest(token: deviceToken)), 501)
        XCTAssertFalse(server.vacuumRunning)
    }

    func testTheOptInIsAConsentToggleThatDefaultsOff() {
        XCTAssertFalse(CompanionServer().allowRemoteVacuum)
        XCTAssertFalse(CompanionServer().vacuumRunning)
    }
}

// MARK: - The opt-in on the Mac

final class CompanionVacuumOptInTests: XCTestCase {
    @MainActor
    private func vacuumStore(_ directory: URL, launcher: RoboticVacuumStore.Launcher? = nil) -> RoboticVacuumStore {
        RoboticVacuumStore(supportDirectory: directory, repoRoot: directory, launcher: launcher ?? { _ in
            XCTFail("a test must not launch the script")
            return true
        })
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-vacuum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testTheOptInDefaultsOffAndSurvivesARestart() throws {
        let suite = "hoghunter.tests.remotevacuum.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try temporaryDirectory()

        let first = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuumStore(directory), startImmediately: false)
        XCTAssertFalse(first.allowRemoteVacuum, "off until the owner turns it on")
        first.allowRemoteVacuum = true
        XCTAssertEqual(defaults.bool(forKey: "allowRemoteVacuum"), true)

        let second = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuumStore(directory), startImmediately: false)
        XCTAssertTrue(second.allowRemoteVacuum)
    }

    @MainActor
    func testTheOptInIsIndependentOfTheOtherThree() throws {
        let suite = "hoghunter.tests.remotevacuum.independent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuumStore(try temporaryDirectory()), startImmediately: false)
        store.allowRemoteQuit = true
        store.allowRemoteClean = true
        store.allowRemoteEdit = true
        XCTAssertFalse(store.allowRemoteVacuum, "the three existing opt-ins must not grant the fourth")
        XCTAssertEqual(defaults.bool(forKey: "allowRemoteVacuum"), false)
    }

    @MainActor
    func testAChangeMadeThroughDefaultsReachesTheStore() async throws {
        let suite = "hoghunter.tests.remotevacuum.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuumStore(try temporaryDirectory()), startImmediately: false)
        // Settings edits the same keys through @AppStorage in places.
        defaults.set(true, forKey: "allowRemoteVacuum")
        try await Self.wait { store.allowRemoteVacuum }
        XCTAssertTrue(store.allowRemoteVacuum)
    }

    @MainActor
    func testTheStepsTravelOnlyWithTheOptIn() async throws {
        let suite = "hoghunter.tests.remotevacuum.steps.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try temporaryDirectory()
        try CompanionVacuumFixtures.statusJSON.write(to: directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuumStore(directory), startImmediately: false)

        // The plain snapshot never carries steps, whatever the setting says.
        XCTAssertNil(try XCTUnwrap(store.vacuumStatusForPhone()).steps)
        let coarse = try XCTUnwrap(store.vacuumStatusForPhone(detailed: true))
        XCTAssertEqual(coarse.health, "healthy")
        XCTAssertNil(coarse.steps, "step reasons can name folders and servers: not without the opt-in")

        store.allowRemoteVacuum = true
        XCTAssertNil(try XCTUnwrap(store.vacuumStatusForPhone()).steps, "the plain snapshot still has none")
        XCTAssertEqual(try XCTUnwrap(store.vacuumStatusForPhone(detailed: true)).steps?.count, 3)

        store.allowRemoteVacuum = false
        XCTAssertNil(try XCTUnwrap(store.vacuumStatusForPhone(detailed: true)).steps, "turning it off takes the detail back out")
    }

    /// The engine writes history oldest first and the store hands it over
    /// newest first.  A phone sees the last run that cleaned, not the watch
    /// tick the status file names as the last record.
    @MainActor
    func testTheRecentRunsAndTheLastRunComeFromTheHistoryFile() async throws {
        let suite = "hoghunter.tests.remotevacuum.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try temporaryDirectory()
        try CompanionVacuumFixtures.statusJSON.write(to: directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        func record(_ id: String, _ trigger: String, ended: Int, freed: Int, step: String) -> String {
            """
            {"run_id": "\(id)", "trigger": "\(trigger)", "started_at": \(ended - 30), "ended_at": \(ended), "band": "cheap",
             "pressure": false, "exit_code": 0, "bytes_freed": \(freed), "summary": "",
             "steps": [{"step_id": "\(step)", "title": "", "status": "ran", "reason": "Done.", "bytes_freed": \(freed), "duration_ms": 5}]}
            """
        }
        let history = "[" + [
            record("f1", "full", ended: 1_760_000_100, freed: 6_000, step: "npm_cache"),
            record("j1", "janitor", ended: 1_760_000_700, freed: 5_000, step: "pm2_logs"),
            record("w1", "watch", ended: 1_760_001_000, freed: 0, step: "resource_sample"),
        ].joined(separator: ",") + "]"
        try history.write(to: directory.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        let store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuumStore(directory), startImmediately: false)
        store.allowRemoteVacuum = true

        let plain = try XCTUnwrap(store.vacuumStatusForPhone())
        XCTAssertEqual(plain.recentRuns?.map(\.runId), ["w1", "j1", "f1"])
        XCTAssertEqual(plain.lastRunTrigger, "janitor")
        XCTAssertEqual(plain.lastRunBytesFreed, 5_000)
        XCTAssertNil(plain.steps)

        let detailed = try XCTUnwrap(store.vacuumStatusForPhone(detailed: true))
        XCTAssertEqual(detailed.steps?.map(\.stepId), ["pm2_logs"], "the janitor run's step, not the watch tick's")
    }

    /// The handler answers at once and the run proceeds on the main actor,
    /// exactly once however many times a phone asks.
    @MainActor
    func testThePhoneStartsOneRunAndTheHandlerDoesNotWaitForIt() async throws {
        let suite = "hoghunter.tests.remotevacuum.run.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try temporaryDirectory()
        let gate = AsyncGate()
        let launches = CompanionLocked<[[String]]>([])
        let vacuum = vacuumStore(directory) { arguments in
            launches.value.append(arguments)
            await gate.wait()
            return true
        }
        let store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuum, startImmediately: false)

        let started = store.performRemoteVacuumRun(kind: "full")
        XCTAssertEqual(started.status, 202, "the handler answers before the run is over")
        let body = try JSONDecoder().decode(CompanionVacuumRunResponse.self, from: started.body)
        XCTAssertEqual(body.status, "started")
        XCTAssertTrue(body.message?.contains("\u{00A0}") ?? false)

        try await Self.wait { vacuum.isRunningNow && !launches.value.isEmpty }
        XCTAssertEqual(launches.value, [["--run-now", "full"]])
        XCTAssertTrue(try XCTUnwrap(store.vacuumStatusForPhone()).isRunning, "the phone sees the run in the snapshot")

        // A second request while the run is going starts nothing.
        _ = store.performRemoteVacuumRun(kind: "full")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(launches.value.count, 1)

        gate.open()
        try await Self.wait { !vacuum.isRunningNow }
        XCTAssertNil(vacuum.lastError)
    }

    @MainActor
    private static func wait(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for a condition")
                throw WaitTimedOut()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

struct WaitTimedOut: Error {}

/// Holds an async stub until the test lets it go.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                next.resume()
            } else {
                continuation = next
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

// MARK: - The store

@MainActor
final class RoboticVacuumStoreInjectionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-vacuum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheDefaultLauncherRefusesToRunInsideATest() async throws {
        XCTAssertTrue(RoboticVacuumStore.isRunningUnderTest)
        // No launcher given: the store would start the real script.  Under a
        // test it must refuse instead.
        let store = RoboticVacuumStore(supportDirectory: try temporaryDirectory(), repoRoot: try temporaryDirectory())
        let task = try XCTUnwrap(store.runNow("full"))
        await task.value
        XCTAssertFalse(store.isRunningNow)
        XCTAssertEqual(store.lastError, RoboticVacuumStore.LauncherRefused().errorDescription)
    }

    func testTheDefaultLauncherAlsoRefusesToChangeAStep() async throws {
        let store = RoboticVacuumStore(supportDirectory: try temporaryDirectory(), repoRoot: try temporaryDirectory())
        store.setStepEnabled("npm_cache", enabled: false)
        for _ in 0..<200 where store.lastError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.lastError, RoboticVacuumStore.LauncherRefused().errorDescription)
    }

    func testRunNowHandsTheLauncherTheFullRunAndOnlyOnce() async throws {
        let gate = AsyncGate()
        let launches = CompanionLocked<[[String]]>([])
        let store = RoboticVacuumStore(supportDirectory: try temporaryDirectory(), repoRoot: try temporaryDirectory()) { arguments in
            launches.value.append(arguments)
            await gate.wait()
            return true
        }
        let task = try XCTUnwrap(store.runNow("full"))
        XCTAssertTrue(store.isRunningNow)
        XCTAssertNil(store.runNow("full"), "a run that is going is not started twice")
        gate.open()
        await task.value
        XCTAssertFalse(store.isRunningNow)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(launches.value, [["--run-now", "full"]])
    }

    func testAFailedRunSaysSoWithTheGapAndFreesTheStore() async throws {
        let store = RoboticVacuumStore(supportDirectory: try temporaryDirectory(), repoRoot: try temporaryDirectory()) { _ in false }
        let task = try XCTUnwrap(store.runNow("full"))
        await task.value
        XCTAssertFalse(store.isRunningNow)
        let message = try XCTUnwrap(store.lastError)
        XCTAssertTrue(message.contains("did not finish cleanly"), message)
        XCTAssertTrue(message.contains("\u{00A0}"), message)
        XCTAssertFalse(message.contains(".  "), message)
    }

    func testARunThatCannotStartReportsWhyAndFreesTheStore() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let store = RoboticVacuumStore(supportDirectory: try temporaryDirectory(), repoRoot: try temporaryDirectory()) { _ in throw Boom() }
        let task = try XCTUnwrap(store.runNow("full"))
        await task.value
        XCTAssertFalse(store.isRunningNow)
        XCTAssertEqual(store.lastError, "boom")
        XCTAssertNotNil(store.runNow("full"), "the store is free to run again")
    }

    func testStepTogglesGoThroughTheLauncher() async throws {
        let launches = CompanionLocked<[[String]]>([])
        let store = RoboticVacuumStore(supportDirectory: try temporaryDirectory(), repoRoot: try temporaryDirectory()) { arguments in
            launches.value.append(arguments)
            return true
        }
        store.setStepEnabled("coolify_remote", enabled: false)
        for _ in 0..<200 where launches.value.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(launches.value, [["--set-step", "coolify_remote", "off"]])
    }

    func testTheFilesAreReadAtMostEveryThirtySecondsForAPhone() throws {
        let directory = try temporaryDirectory()
        let statusURL = directory.appendingPathComponent("status.json")
        let store = RoboticVacuumStore(supportDirectory: directory, repoRoot: directory) { _ in true }
        XCTAssertNil(store.status, "no file yet")

        try CompanionVacuumFixtures.statusJSON.write(to: statusURL, atomically: true, encoding: .utf8)
        // Just read, so a phone polling now does not read again.
        store.refreshIfStale(maxAge: 30, now: store.lastRefreshAt.addingTimeInterval(29))
        XCTAssertNil(store.status)
        // Thirty seconds on, the next poll reads.
        store.refreshIfStale(maxAge: 30, now: store.lastRefreshAt.addingTimeInterval(30))
        XCTAssertEqual(store.status?.health, "healthy")
    }
}

// MARK: - The status the phone gets

final class CompanionVacuumStatusTests: XCTestCase {
    private func decode(_ json: String = CompanionVacuumFixtures.statusJSON) throws -> RoboticVacuumStatus {
        try JSONDecoder().decode(RoboticVacuumStatus.self, from: Data(json.utf8))
    }

    func testNothingToSayWithoutAStatusOrARun() {
        XCTAssertNil(CompanionVacuum.status(from: nil, history: [], isRunning: false, includeSteps: true))
    }

    func testAFirstRunBeforeAnyStatusStillShowsRunning() throws {
        let status = try XCTUnwrap(CompanionVacuum.status(from: nil, history: [], isRunning: true, includeSteps: true))
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.health, "unknown")
        XCTAssertEqual(status.displayHealth, "Waiting for first run")
        XCTAssertNil(status.steps)
        XCTAssertNil(status.lastFullRunAt)
    }

    func testHealthWordsMatchTheMacCard() throws {
        let expected = ["healthy": "On schedule", "overdue": "Overdue", "failed": "Needs attention", "unloaded": "Not running in background", "weird": "Weird"]
        for (raw, shown) in expected {
            let json = CompanionVacuumFixtures.statusJSON.replacingOccurrences(of: #""health": "healthy""#, with: #""health": "\#(raw)""#)
            let built = try XCTUnwrap(CompanionVacuum.status(from: decode(json), history: [], isRunning: false, includeSteps: false))
            XCTAssertEqual(built.health, raw)
            XCTAssertEqual(built.displayHealth, shown)
        }
    }

    func testTheCoarseFieldsComeFromTheStatus() throws {
        let built = try XCTUnwrap(CompanionVacuum.status(from: decode(), history: [], isRunning: true, includeSteps: false))
        XCTAssertTrue(built.launchdLoaded)
        XCTAssertTrue(built.isRunning)
        XCTAssertEqual(built.lastFullRunAt, Date(timeIntervalSince1970: 1_760_000_100))
        XCTAssertEqual(built.nextFullRunAt, Date(timeIntervalSince1970: 1_760_014_400))
        XCTAssertEqual(built.lastRunBytesFreed, 5_000)
        XCTAssertEqual(built.lastRunEndedAt, Date(timeIntervalSince1970: 1_760_000_100))
        XCTAssertNil(built.steps)
    }

    func testNeverRanAndNotScheduledAreNotDates() throws {
        let json = CompanionVacuumFixtures.statusJSON
            .replacingOccurrences(of: #""next_run_at": { "full": 1760014400.0 }"#, with: #""next_run_at": { "full": 0 }"#)
            .replacingOccurrences(of: #""last_runs": { "full": 1760000100.0 }"#, with: #""last_runs": { "full": -1 }"#)
        let built = try XCTUnwrap(CompanionVacuum.status(from: decode(json), history: [], isRunning: false, includeSteps: false))
        XCTAssertNil(built.nextFullRunAt)
        XCTAssertNil(built.lastFullRunAt)
    }

    func testTheLastRunFallsBackToTheHistory() throws {
        let json = CompanionVacuumFixtures.statusJSON.replacingOccurrences(of: "\"last_run\"", with: "\"last_run_unused\"")
        let status = try decode(json)
        XCTAssertNil(status.lastRun)
        let run = RoboticVacuumRun(runId: "old", trigger: "full", startedAt: 1_759_000_000, endedAt: 1_759_000_050, bytesFreed: 777, exitCode: 0, steps: [])
        let built = try XCTUnwrap(CompanionVacuum.status(from: status, history: [run], isRunning: false, includeSteps: false))
        XCTAssertEqual(built.lastRunBytesFreed, 777)
        XCTAssertEqual(built.lastRunEndedAt, Date(timeIntervalSince1970: 1_759_000_050))
    }

    func testStepsAppearOnlyWithTheOptInAndInTheMacsOrder() throws {
        let off = try XCTUnwrap(CompanionVacuum.status(from: decode(), history: [], isRunning: false, includeSteps: false))
        XCTAssertNil(off.steps)

        let on = try XCTUnwrap(CompanionVacuum.status(from: decode(), history: [], isRunning: false, includeSteps: true))
        let steps = try XCTUnwrap(on.steps)
        // Catalog order, then a step this build does not know, by id.
        XCTAssertEqual(steps.map(\.stepId), ["resource_sample", "janitor_worktree_retire", "zz_new_step"])
        XCTAssertEqual(steps.map(\.statusLabel), ["Done", "Skipped", "Failed"])
        XCTAssertEqual(steps[0].title, "Check disk and memory")
        XCTAssertEqual(steps[2].title, "zz_new_step", "a step with no title falls back to its id")
        XCTAssertEqual(steps[0].bytesFreed, 0)
    }

    func testAReasonIsCappedAtOneHundredTwentyCharactersAndOneLine() throws {
        let long = String(repeating: "word ", count: 60)
        let capped = CompanionVacuum.cappedReason(long)
        XCTAssertEqual(capped.count, CompanionVacuum.maxReasonLength)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertEqual(CompanionVacuum.cappedReason(String(repeating: "a", count: 120)).count, 120, "exactly the cap is kept whole")
        XCTAssertEqual(CompanionVacuum.cappedReason(String(repeating: "a", count: 121)).count, 120)
        XCTAssertEqual(CompanionVacuum.cappedReason("Retired two\nworktrees.   Kept one."), "Retired two worktrees. Kept one.")
        XCTAssertEqual(CompanionVacuum.cappedReason(""), "")
        XCTAssertEqual(CompanionVacuum.cappedReason("Retired two.\u{00A0} Kept one."), "Retired two.\u{00A0} Kept one.", "the gap between sentences survives")
    }

    func testBytesNeverGoNegative() throws {
        let json = CompanionVacuumFixtures.statusJSON.replacingOccurrences(of: #""bytes_freed": 5000"#, with: #""bytes_freed": -5"#)
        let built = try XCTUnwrap(CompanionVacuum.status(from: decode(json), history: [], isRunning: false, includeSteps: true))
        XCTAssertEqual(built.lastRunBytesFreed, 0)
    }
}

// MARK: - The last run and the recent runs

/// Builders for the history tests: a run, a step and a status whose last run is a watch tick.
enum CompanionVacuumRunFixtures {
    static func step(_ id: String, _ status: String = "ran", reason: String = "", freed: Int = 0) -> RoboticVacuumStepResult {
        RoboticVacuumStepResult(stepId: id, title: "", status: status, reason: reason, bytesFreed: freed, durationMs: 1)
    }

    static func run(
        _ id: String, _ trigger: String, ended: Double, freed: Int = 0, exit: Int = 0, took: Double = 10,
        steps: [RoboticVacuumStepResult] = []
    ) -> RoboticVacuumRun {
        RoboticVacuumRun(runId: id, trigger: trigger, startedAt: ended - took, endedAt: ended, bytesFreed: freed, exitCode: exit, steps: steps)
    }

    /// The fixture status with `lastRun` set, the way the engine publishes it: whatever ran last.
    static func status(lastRun: RoboticVacuumRun?) throws -> RoboticVacuumStatus {
        var status = try JSONDecoder().decode(RoboticVacuumStatus.self, from: Data(CompanionVacuumFixtures.statusJSON.utf8))
        status.lastRun = lastRun
        return status
    }

    static func statusWithRecentRuns() throws -> CompanionVacuumStatus {
        try XCTUnwrap(CompanionVacuum.status(
            from: status(lastRun: nil),
            history: [run("j1", "janitor", ended: 1_760_000_600)],
            isRunning: false,
            includeSteps: false
        ))
    }
}

/// The engine ticks every five minutes, so the last run on record is nearly
/// always a watch tick.  The phone leads with the last run that cleaned.
final class CompanionVacuumLastRunTests: XCTestCase {
    private typealias F = CompanionVacuumRunFixtures

    func testTheHeadlineRunSkipsWatchTicks() throws {
        let watch = F.run("w1", "watch", ended: 1_760_001_000, steps: [F.step("resource_sample", reason: "Disk 41% used.")])
        let janitor = F.run("j1", "janitor", ended: 1_760_000_700, freed: 5_000, steps: [
            F.step("pm2_logs", reason: "No log is over the limit."),
            F.step("janitor_worktree_retire", "skipped", reason: "Kept lane-claude-secret-project."),
            F.step("zz_new_step", "failed", reason: "Could not reach the server.", freed: 0),
        ])
        let full = F.run("f1", "full", ended: 1_759_990_000, freed: 9_000_000)
        let built = try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: watch), history: [watch, janitor, full], isRunning: false, includeSteps: true
        ))
        XCTAssertEqual(built.lastRunTrigger, "janitor")
        XCTAssertEqual(built.lastRunBytesFreed, 5_000, "not the watch tick's, and not the older full run's")
        XCTAssertEqual(built.lastRunEndedAt, Date(timeIntervalSince1970: 1_760_000_700))
        // The janitor run's own steps, in the Mac's order, and none of the watch tick's.
        XCTAssertEqual(built.steps?.map(\.stepId), ["janitor_worktree_retire", "pm2_logs", "zz_new_step"])
        XCTAssertEqual(built.steps?.map(\.statusLabel), ["Skipped", "Done", "Failed"])
    }

    func testEveryKindOfRunButAWatchTickCanBeTheHeadline() throws {
        for trigger in ["janitor", "full", "manual", "pressure"] {
            let watch = F.run("w1", "watch", ended: 1_760_001_000)
            let run = F.run("r1", trigger, ended: 1_760_000_500, freed: 77)
            let built = try XCTUnwrap(CompanionVacuum.status(
                from: F.status(lastRun: watch), history: [watch, run], isRunning: false, includeSteps: false
            ))
            XCTAssertEqual(built.lastRunTrigger, trigger)
            XCTAssertEqual(built.lastRunBytesFreed, 77)
        }
    }

    func testWhenEveryRunIsAWatchTickTheNewestOneIsTheLastRun() throws {
        let newest = F.run("w2", "watch", ended: 1_760_001_000, freed: 3, steps: [F.step("resource_sample")])
        let older = F.run("w1", "watch", ended: 1_760_000_700, freed: 9)
        let built = try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: newest), history: [newest, older], isRunning: false, includeSteps: true
        ))
        XCTAssertEqual(built.lastRunTrigger, "watch")
        XCTAssertEqual(built.lastRunBytesFreed, 3)
        XCTAssertEqual(built.steps?.map(\.stepId), ["resource_sample"])
    }

    func testWithoutAnyHistoryTheStatusLastRunIsUsed() throws {
        let full = F.run("f1", "full", ended: 1_760_000_100, freed: 5_000)
        let built = try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: full), history: [], isRunning: false, includeSteps: false
        ))
        XCTAssertEqual(built.lastRunTrigger, "full")
        XCTAssertEqual(built.lastRunBytesFreed, 5_000)
        XCTAssertEqual(built.recentRuns, [], "empty, not unknown: this Mac does send the list")
    }

    func testNoRunAtAllLeavesTheLastRunOut() throws {
        let built = try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: nil), history: [], isRunning: false, includeSteps: false
        ))
        XCTAssertNil(built.lastRunTrigger)
        XCTAssertNil(built.lastRunBytesFreed)
        XCTAssertNil(built.lastRunEndedAt)
    }

    func testAFirstRunBeforeAnyStatusStillListsTheRunsOnRecord() throws {
        let built = try XCTUnwrap(CompanionVacuum.status(
            from: nil, history: [F.run("w1", "watch", ended: 1_760_000_100)], isRunning: true, includeSteps: true
        ))
        XCTAssertEqual(built.recentRuns?.map(\.runId), ["w1"])
        XCTAssertNil(built.lastRunTrigger)
    }
}

final class CompanionVacuumRecentRunsTests: XCTestCase {
    private typealias F = CompanionVacuumRunFixtures

    private func built(_ history: [RoboticVacuumRun], includeSteps: Bool = false) throws -> CompanionVacuumStatus {
        try XCTUnwrap(CompanionVacuum.status(
            from: F.status(lastRun: history.first), history: history, isRunning: false, includeSteps: includeSteps
        ))
    }

    func testRunsAreListedNewestFirstWithWatchTicksIncluded() throws {
        let history = [
            F.run("w1", "watch", ended: 1_760_001_000),
            F.run("j1", "janitor", ended: 1_760_000_700, freed: 5_000),
            F.run("f1", "full", ended: 1_760_000_100, freed: 6_000),
        ]
        let runs = try XCTUnwrap(built(history).recentRuns)
        XCTAssertEqual(runs.map(\.runId), ["w1", "j1", "f1"], "the Mac lists every run, newest first")
        XCTAssertEqual(runs.map(\.trigger), ["watch", "janitor", "full"])
        XCTAssertEqual(runs.map(\.bytesFreed), [0, 5_000, 6_000])
    }

    func testTheListIsCappedAtTwentyAndKeepsTheNewest() throws {
        let history = (0..<25).map { F.run("r\($0)", "watch", ended: 1_760_100_000 - Double($0) * 300) }
        let runs = try XCTUnwrap(built(history).recentRuns)
        XCTAssertEqual(runs.count, CompanionVacuum.maxRecentRuns)
        XCTAssertEqual(CompanionVacuum.maxRecentRuns, 20)
        XCTAssertEqual(runs.first?.runId, "r0")
        XCTAssertEqual(runs.last?.runId, "r19")
    }

    func testEachRunCarriesItsEndExitStatusAndDuration() throws {
        let ok = F.run("ok", "full", ended: 1_760_000_600, exit: 0, took: 412.4)
        let failed = F.run("bad", "janitor", ended: 1_760_000_100, exit: 1, took: 95.6)
        let runs = try XCTUnwrap(built([ok, failed]).recentRuns)
        XCTAssertEqual(runs[0].endedAt, Date(timeIntervalSince1970: 1_760_000_600))
        XCTAssertEqual(runs[0].durationSeconds, 412)
        XCTAssertTrue(runs[0].succeeded)
        XCTAssertEqual(runs[1].durationSeconds, 96)
        XCTAssertEqual(runs[1].exitCode, 1)
        XCTAssertFalse(runs[1].succeeded)
    }

    func testBadTimesAndBytesNeverReachThePhone() throws {
        var odd = F.run("odd", "janitor", ended: 0, freed: -9)
        odd.startedAt = 1_760_000_000
        var backwards = F.run("back", "watch", ended: 1_760_000_000)
        backwards.startedAt = 1_760_000_050
        let runs = try XCTUnwrap(built([odd, backwards]).recentRuns)
        XCTAssertNil(runs[0].endedAt, "an end time of 0 is not a date")
        XCTAssertEqual(runs[0].bytesFreed, 0)
        XCTAssertEqual(runs[0].durationSeconds, 0)
        XCTAssertEqual(runs[1].durationSeconds, 0, "a clock that ran backwards is not a negative duration")
    }

    /// A run in the list says nothing a folder or a server could hide in, so
    /// it travels in the plain snapshot, which the shared code can read.
    func testRecentRunsCarryNoStepTextAndNeedNoOptIn() throws {
        let janitor = F.run("j1", "janitor", ended: 1_760_000_700, steps: [
            F.step("janitor_worktree_retire", "skipped", reason: "Kept lane-claude-secret-project because it has unpushed work."),
        ])
        let plain = try built([janitor], includeSteps: false)
        XCTAssertNil(plain.steps)
        XCTAssertEqual(plain.recentRuns?.count, 1, "the list is not behind the opt-in")
        let wire = String(decoding: try CompanionJSON.encoder().encode(plain), as: UTF8.self)
        XCTAssertTrue(wire.contains("recentRuns"))
        XCTAssertFalse(wire.contains("lane-"), "a reason that names a folder must not leak")
        XCTAssertFalse(wire.contains("janitor_worktree_retire"))

        // Even with the detail on, the list itself stays free of step text.
        let detailed = try built([janitor], includeSteps: true)
        XCTAssertEqual(detailed.steps?.count, 1)
        let listOnly = String(decoding: try CompanionJSON.encoder().encode(detailed.recentRuns), as: UTF8.self)
        XCTAssertFalse(listOnly.contains("lane-"))
    }
}

// MARK: - The snapshot

final class CompanionVacuumSnapshotTests: XCTestCase {
    private func snapshot(allowed: Bool?, vacuum: CompanionVacuumStatus?) -> CompanionSnapshot {
        CompanionSnapshotBuilder.make(
            hostName: "test", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .perCore, pulse: MachinePulse.empty, rows: [],
            remoteVacuumAllowed: allowed, vacuum: vacuum
        )
    }

    private func status(steps: Bool) throws -> CompanionVacuumStatus {
        let parsed = try JSONDecoder().decode(RoboticVacuumStatus.self, from: Data(CompanionVacuumFixtures.statusJSON.utf8))
        return try XCTUnwrap(CompanionVacuum.status(from: parsed, history: [], isRunning: false, includeSteps: steps))
    }

    func testTheOptInAndTheStatusSurviveTheWire() throws {
        let built = snapshot(allowed: true, vacuum: try status(steps: true))
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(built))
        XCTAssertEqual(decoded.remoteVacuumAllowed, true)
        XCTAssertEqual(decoded.vacuum, built.vacuum)
        XCTAssertEqual(decoded.vacuum?.steps?.count, 3)
    }

    func testTheStepsAreAbsentFromTheWireWithoutTheOptIn() throws {
        let built = snapshot(allowed: false, vacuum: try status(steps: false))
        let data = try CompanionJSON.encode(built)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vacuum = try XCTUnwrap(object["vacuum"] as? [String: Any])
        XCTAssertNil(vacuum["steps"], "the snapshot is readable with the shared code, so no step detail without the opt-in")
        XCTAssertEqual(vacuum["health"] as? String, "healthy")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("janitor_worktree_retire"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("lane-"), "a reason that names a folder must not leak")
    }

    func testAnOlderMacsSnapshotStillDecodes() throws {
        let built = snapshot(allowed: true, vacuum: try status(steps: true))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionJSON.encode(built)) as? [String: Any])
        object.removeValue(forKey: "remoteVacuumAllowed")
        object.removeValue(forKey: "vacuum")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try CompanionJSON.decode(legacy)
        XCTAssertNil(decoded.remoteVacuumAllowed, "unknown, not off")
        XCTAssertNil(decoded.vacuum)
    }

    func testAStatusWithoutOptionalFieldsDecodes() throws {
        let minimal = Data(#"{"health":"healthy","displayHealth":"On schedule","launchdLoaded":true,"isRunning":false}"#.utf8)
        let decoded = try CompanionJSON.decoder().decode(CompanionVacuumStatus.self, from: minimal)
        XCTAssertNil(decoded.steps)
        XCTAssertNil(decoded.lastFullRunAt)
        XCTAssertNil(decoded.lastRunBytesFreed)
        XCTAssertNil(decoded.lastRunTrigger, "an older Mac does not say what kind of run it was")
        XCTAssertNil(decoded.recentRuns, "an older Mac sends no recent runs: unknown, not empty")
    }

    func testTheRecentRunsAndTheirTriggerSurviveTheWire() throws {
        let status = try XCTUnwrap(CompanionVacuum.status(
            from: JSONDecoder().decode(RoboticVacuumStatus.self, from: Data(CompanionVacuumFixtures.statusJSON.utf8)),
            history: [
                CompanionVacuumRunFixtures.run("w1", "watch", ended: 1_760_000_900, steps: [CompanionVacuumRunFixtures.step("resource_sample")]),
                CompanionVacuumRunFixtures.run("j1", "janitor", ended: 1_760_000_600, freed: 4_096, exit: 1, took: 90),
            ],
            isRunning: false,
            includeSteps: false
        ))
        let built = snapshot(allowed: true, vacuum: status)
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(built))
        XCTAssertEqual(decoded.vacuum, built.vacuum)
        XCTAssertEqual(decoded.vacuum?.lastRunTrigger, "janitor")
        XCTAssertEqual(decoded.vacuum?.recentRuns?.map(\.runId), ["w1", "j1"])
        XCTAssertEqual(decoded.vacuum?.recentRuns?.last?.bytesFreed, 4_096)
        XCTAssertEqual(decoded.vacuum?.recentRuns?.last?.exitCode, 1)
        XCTAssertEqual(decoded.vacuum?.recentRuns?.last?.durationSeconds, 90)
        XCTAssertEqual(decoded.vacuum?.recentRuns?.last?.endedAt, Date(timeIntervalSince1970: 1_760_000_600))
    }

    func testAnOlderMacsSnapshotWithoutRecentRunsStillDecodes() throws {
        let built = snapshot(allowed: true, vacuum: try CompanionVacuumRunFixtures.statusWithRecentRuns())
        XCTAssertEqual(built.vacuum?.recentRuns?.count, 1, "the fixture does carry one")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionJSON.encode(built)) as? [String: Any])
        var vacuum = try XCTUnwrap(object["vacuum"] as? [String: Any])
        XCTAssertNotNil(vacuum["recentRuns"])
        vacuum.removeValue(forKey: "recentRuns")
        vacuum.removeValue(forKey: "lastRunTrigger")
        object["vacuum"] = vacuum
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try CompanionJSON.decode(legacy)
        XCTAssertNil(decoded.vacuum?.recentRuns)
        XCTAssertNil(decoded.vacuum?.lastRunTrigger)
        XCTAssertEqual(decoded.vacuum?.health, "healthy", "the rest of the status is untouched")
    }

    func testARunInTheListNeedsOnlyItsIdentityToDecode() throws {
        let minimal = Data(#"{"runId":"r1","trigger":"watch","bytesFreed":0,"exitCode":0,"durationSeconds":0}"#.utf8)
        let run = try CompanionJSON.decoder().decode(CompanionVacuumRun.self, from: minimal)
        XCTAssertNil(run.endedAt)
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(run.id, "r1")
    }
}

// MARK: - Copy

final class CompanionVacuumCopyTests: XCTestCase {
    private func message(of body: Data) throws -> String {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["error"] as? String)
    }

    private func assertGap(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains("\u{00A0}"), "no non-breaking gap in: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("\\"), "a literal backslash reached the screen: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains(".  "), "two ASCII spaces collapse on the phone: \(text)", file: file, line: line)
    }

    @MainActor
    func testTheStartedReplyKeepsItsGap() throws {
        let suite = "hoghunter.tests.vacuumcopy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let vacuum = RoboticVacuumStore(supportDirectory: directory, repoRoot: directory) { _ in true }
        let store = HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), vacuum: vacuum, startImmediately: false)
        let started = store.performRemoteVacuumRun(kind: "full")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: started.body) as? [String: Any])
        assertGap(try XCTUnwrap(json["message"] as? String))
    }

    /// The phone's own strings live in the iOS target, which these tests do
    /// not compile.  Read the source and look for the thing the owner banned:
    /// two ASCII spaces after a sentence inside a string literal.
    func testThePhoneScreenWritesItsGapsAsNonBreakingSpaces() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["ios/Sources/CompanionVacuumView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            let code = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code {
                for literal in Self.stringLiterals(in: line) {
                    XCTAssertFalse(literal.range(of: #"[.!?]  \S"#, options: .regularExpression) != nil, "two ASCII spaces in \(name): \(literal)")
                }
            }
        }
    }

    private static func stringLiterals(in line: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inside = false
        var escaped = false
        for character in line {
            if inside {
                if escaped { current.append(character); escaped = false; continue }
                if character == "\\" { current.append(character); escaped = true; continue }
                if character == "\"" { results.append(current); current = ""; inside = false; continue }
                current.append(character)
            } else if character == "\"" {
                inside = true
            }
        }
        return results
    }
}

// MARK: - Fixtures

enum CompanionVacuumFixtures {
    /// What `scripts/robotic-vacuum.py` writes to `status.json`, trimmed to
    /// three steps.  One reason names a folder, to check it stays behind the opt-in.
    static let statusJSON = """
    {
      "health": "healthy",
      "launchd_loaded": true,
      "next_run_at": { "full": 1760014400.0 },
      "last_runs": { "full": 1760000100.0 },
      "intervals_seconds": { "full": 14400 },
      "last_run": {
        "run_id": "r1",
        "trigger": "full",
        "started_at": 1760000000,
        "ended_at": 1760000100,
        "bytes_freed": 5000,
        "exit_code": 0,
        "steps": []
      },
      "step_last_results": {
        "zz_new_step": { "step_id": "zz_new_step", "title": "", "status": "failed", "reason": "Could not reach the server.", "bytes_freed": 0, "duration_ms": 5 },
        "janitor_worktree_retire": { "step_id": "janitor_worktree_retire", "title": "Retire old merged git worktrees", "status": "skipped", "reason": "Kept lane-claude-secret-project because it has unpushed work.", "bytes_freed": 0, "duration_ms": 12 },
        "resource_sample": { "step_id": "resource_sample", "title": "Check disk and memory", "status": "ran", "reason": "Disk 41% used.", "bytes_freed": 0, "duration_ms": 80 }
      },
      "history_count": 1
    }
    """
}

/// Who reads the vacuum's step detail.  The shared pairing code can read the
/// snapshot from anywhere, and a step's reason can name a folder or a server.
final class CompanionVacuumDisclosureTests: XCTestCase {
    private let code = "ABCD2345"
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)

    private func snapshot(steps: Bool) -> CompanionSnapshot {
        var snapshot = CompanionServerRoutingTests.minimalSnapshot()
        var status = CompanionVacuumStatus(health: "healthy", displayHealth: "On schedule", launchdLoaded: true, isRunning: false)
        if steps {
            status.steps = [CompanionVacuumStep(stepId: "janitor_worktree_retire", title: "Retire old merged git worktrees", statusLabel: "Done", reason: "Retired ~/apps/lanes/hoghunter/claude-secret-lane.", bytesFreed: 1)]
        }
        snapshot.vacuum = status
        return snapshot
    }

    private func served(_ server: CompanionServer, token: String, from peer: CompanionPeer) throws -> CompanionSnapshot {
        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: token), peer: peer) }
        guard case .reply(let data) = disposition, let parsed = CompanionHTTP.parseResponse(data), parsed.status == 200 else {
            throw XCTSkip("the snapshot was not served")
        }
        return try CompanionJSON.decode(parsed.body)
    }

    func testOnlyAPhonesOwnTokenOnTheLocalNetworkReadsTheSteps() throws {
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.update(snapshot: snapshot(steps: false), detailed: snapshot(steps: true))
        server.syncOnQueue {}

        XCTAssertNotNil(try served(server, token: token, from: lan).vacuum?.steps, "a paired phone at home reads the detail")
        XCTAssertNil(try served(server, token: token, from: wan).vacuum?.steps, "from outside the local network it reads the plain snapshot")
        XCTAssertNil(try served(server, token: code, from: lan).vacuum?.steps, "the shared code never reads the detail")
        XCTAssertNil(try served(server, token: code, from: wan).vacuum?.steps)
        XCTAssertEqual(try served(server, token: code, from: wan).vacuum?.health, "healthy", "the coarse status is there for everyone")
    }

    func testWithoutADetailedSnapshotEveryoneReadsThePlainOne() throws {
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.update(snapshot: snapshot(steps: false))
        server.syncOnQueue {}
        XCTAssertNil(try served(server, token: token, from: lan).vacuum?.steps)
    }
}
