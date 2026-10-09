import XCTest

@testable import HogHunter

// Phone parity, batch 2, PR C: Robotic Vacuum status and Run Now.
//
// Nothing here runs the real script.  Every store is built with a stub
// launcher, and the default launcher refuses to start inside XCTest, so a test
// that forgot a stub would fail instead of cleaning this Mac.

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

        let first = HogStore(defaults: defaults, vacuum: vacuumStore(directory), startImmediately: false)
        XCTAssertFalse(first.allowRemoteVacuum, "off until the owner turns it on")
        first.allowRemoteVacuum = true
        XCTAssertEqual(defaults.bool(forKey: "allowRemoteVacuum"), true)

        let second = HogStore(defaults: defaults, vacuum: vacuumStore(directory), startImmediately: false)
        XCTAssertTrue(second.allowRemoteVacuum)
    }

    @MainActor
    func testTheOptInIsIndependentOfTheOtherThree() throws {
        let suite = "hoghunter.tests.remotevacuum.independent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults, vacuum: vacuumStore(try temporaryDirectory()), startImmediately: false)
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
        let store = HogStore(defaults: defaults, vacuum: vacuumStore(try temporaryDirectory()), startImmediately: false)
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
        let store = HogStore(defaults: defaults, vacuum: vacuumStore(directory), startImmediately: false)

        let coarse = try XCTUnwrap(store.vacuumStatusForPhone())
        XCTAssertEqual(coarse.health, "healthy")
        XCTAssertNil(coarse.steps, "step reasons can name folders and servers: not without the opt-in")

        store.allowRemoteVacuum = true
        XCTAssertEqual(try XCTUnwrap(store.vacuumStatusForPhone()).steps?.count, 3)

        store.allowRemoteVacuum = false
        XCTAssertNil(try XCTUnwrap(store.vacuumStatusForPhone()).steps, "turning it off takes the detail back out")
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
        let store = HogStore(defaults: defaults, vacuum: vacuum, startImmediately: false)

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
    }

    func testBytesNeverGoNegative() throws {
        let json = CompanionVacuumFixtures.statusJSON.replacingOccurrences(of: #""bytes_freed": 5000"#, with: #""bytes_freed": -5"#)
        let built = try XCTUnwrap(CompanionVacuum.status(from: decode(json), history: [], isRunning: false, includeSteps: true))
        XCTAssertEqual(built.lastRunBytesFreed, 0)
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
        let store = HogStore(defaults: defaults, vacuum: vacuum, startImmediately: false)
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
