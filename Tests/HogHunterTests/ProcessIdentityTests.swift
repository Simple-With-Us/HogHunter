import XCTest

@testable import HogHunter

/// A recycled pid must never be signalled.  These use real child processes of
/// the test runner: same user, harmless (`sleep`), and a wrong start time
/// stands in for "the pid now belongs to something else".
final class ProcessIdentityTests: XCTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children.removeAll()
        super.tearDown()
    }

    private func spawnSleeper() throws -> ProcessKey {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        children.append(process)
        let pid = process.processIdentifier
        // The kernel may take a moment to report the process.
        var start: UInt64?
        for _ in 0..<50 {
            start = ProcessControl.startTime(pid)
            if start != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return ProcessKey(pid: pid, startTime: try XCTUnwrap(start))
    }

    /// A child starts at the runner's own priority, which is not always 0.
    private var baseNice: Int32 { getpriority(PRIO_PROCESS, 0) }

    private func nice(_ key: ProcessKey) -> Int32 {
        errno = 0
        return getpriority(PRIO_PROCESS, id_t(key.pid))
    }

    func testTameActsOnAProcessWhoseStartTimeMatches() throws {
        let key = try spawnSleeper()
        let outcome = ProcessControl.tame(members: [key], fallbackName: "sleep")
        XCTAssertEqual(outcome.actedOn, 1)
        XCTAssertEqual(nice(key), 20)
        XCTAssertTrue(ProcessControl.isTamed(pid: key.pid))
        // Restoring is not asserted: lowering a nice value needs root on
        // macOS (EACCES), so untame cannot succeed for an ordinary user.
        // Filed as a follow-up on the board; it is outside this batch.
    }

    func testTameLeavesARecycledPidAlone() throws {
        let real = try spawnSleeper()
        let stale = ProcessKey(pid: real.pid, startTime: real.startTime &+ 1)

        let outcome = ProcessControl.tame(members: [stale], fallbackName: "sleep")

        XCTAssertEqual(outcome.actedOn, 0)
        guard case .changed = outcome.results.first?.outcome else { return XCTFail("expected changed, got \(String(describing: outcome.results.first?.outcome))") }
        XCTAssertEqual(nice(real), baseNice, "the process behind the pid must not be reniced")
    }

    func testUntameAndQuitAlsoRefuseARecycledPid() throws {
        let real = try spawnSleeper()
        let stale = ProcessKey(pid: real.pid, startTime: real.startTime &+ 1)
        _ = ProcessControl.tame(members: [real], fallbackName: "sleep")

        let restored = ProcessControl.untame(members: [stale], fallbackName: "sleep")
        XCTAssertEqual(restored.actedOn, 0)
        guard case .changed = restored.results.first?.outcome else {
            return XCTFail("a stale untame must stop at the identity check, got \(String(describing: restored.results.first?.outcome))")
        }

        let quit = ProcessControl.quit(members: [stale], fallbackName: "sleep", force: true)
        XCTAssertEqual(quit.actedOn, 0)
        let process = try XCTUnwrap(children.first { $0.processIdentifier == real.pid })
        XCTAssertTrue(process.isRunning, "a stale force quit must not kill the live process")
    }

    func testAKeyWithNoStartTimeCannotBeVerifiedSoItIsRefused() throws {
        let real = try spawnSleeper()
        let outcome = ProcessControl.quit(members: [ProcessKey(pid: real.pid, startTime: 0)], fallbackName: "sleep", force: true)
        XCTAssertEqual(outcome.actedOn, 0)
        let process = try XCTUnwrap(children.first { $0.processIdentifier == real.pid })
        XCTAssertTrue(process.isRunning)
    }

    func testAGroupActsOnEveryLiveMemberAndSkipsTheChangedOne() throws {
        let a = try spawnSleeper()
        let b = try spawnSleeper()
        let c = try spawnSleeper()
        let staleC = ProcessKey(pid: c.pid, startTime: c.startTime &+ 1)

        let outcome = ProcessControl.tame(members: [a, b, staleC], fallbackName: "Sleepers")

        XCTAssertEqual(outcome.actedOn, 2)
        XCTAssertEqual(outcome.results.count, 3)
        XCTAssertEqual(nice(a), 20)
        XCTAssertEqual(nice(b), 20)
        XCTAssertEqual(nice(c), baseNice, "the changed member is skipped")
        XCTAssertEqual(outcome.message?.hasPrefix("Tamed 2, skipped"), true, outcome.message ?? "nil")
    }

    func testForceQuitEndsEveryMemberOfAGroup() throws {
        let a = try spawnSleeper()
        let b = try spawnSleeper()
        let outcome = ProcessControl.quit(members: [a, b], fallbackName: "Sleepers", force: true)
        XCTAssertEqual(outcome.actedOn, 2)
        for key in [a, b] {
            let process = try XCTUnwrap(children.first { $0.processIdentifier == key.pid })
            process.waitUntilExit()
            XCTAssertFalse(process.isRunning)
        }
    }

    func testHogHunterItselfIsNeverActedOn() {
        let me = ProcessKey(pid: getpid(), startTime: ProcessControl.startTime(getpid()) ?? 1)
        let outcome = ProcessControl.tame(members: [me], fallbackName: "HogHunter")
        XCTAssertEqual(outcome.actedOn, 0)
        guard case .blocked = outcome.results.first?.outcome else { return XCTFail("expected blocked") }
    }

    func testAnEmptyRowSaysItIsOnlyInHistory() {
        let outcome = ProcessControl.quit(members: [], fallbackName: "Gone", force: false)
        XCTAssertEqual(outcome.message, "That hog is only in history.  Switch to Now to act on a live process.")
    }
}

final class GroupTamedTests: XCTestCase {
    private func sample(pid: pid_t, uid: uid_t, tamed: Bool) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: UInt64(pid)),
            ppid: 1, uid: uid, name: "helper", path: "", cpuPercent: 0, hasBaseline: true,
            footprintBytes: 0, residentBytes: 0, threadCount: 1,
            diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0, idleWakeupsPerSec: 0,
            isTamed: tamed
        )
    }

    func testAnAppWithAProtectedHelperStillReadsAsTamed() {
        let mine = getuid()
        let members = [sample(pid: 9001, uid: mine, tamed: true), sample(pid: 9002, uid: mine, tamed: true), sample(pid: 9003, uid: mine &+ 1, tamed: false)]
        XCTAssertTrue(HogStore.groupIsTamed(members))
    }

    func testAnAppWithAnUntamedReachableMemberIsNotTamed() {
        let mine = getuid()
        let members = [sample(pid: 9001, uid: mine, tamed: true), sample(pid: 9002, uid: mine, tamed: false)]
        XCTAssertFalse(HogStore.groupIsTamed(members))
    }

    func testARowOfOnlyProtectedMembersIsNeverTamed() {
        let other = getuid() &+ 1
        XCTAssertFalse(HogStore.groupIsTamed([sample(pid: 9001, uid: other, tamed: true)]))
        XCTAssertFalse(HogStore.groupIsTamed([]))
    }
}

final class CompanionTargetsTests: XCTestCase {
    private func row(_ id: String, name: String = "App", keys: [ProcessKey]) -> HogRow {
        HogRow(id: id, keys: keys, name: name, detail: "", cpuPercent: 0, memoryBytes: 0, peakMemoryBytes: nil, presence: nil, icon: nil, path: nil, isApp: true, isGroup: keys.count > 1, canQuit: true, quitBlockReason: nil)
    }

    private let chrome = [ProcessKey(pid: 100, startTime: 11), ProcessKey(pid: 101, startTime: 12), ProcessKey(pid: 102, startTime: 13)]

    func testIndexKeepsLiveRowsAndDropsHistoryRows() {
        let targets = CompanionTargets.index([
            row("a-app:com.google.Chrome", name: "Chrome", keys: chrome),
            row("h-gone", name: "Gone", keys: []),
        ])
        XCTAssertEqual(Set(targets.keys), ["a-app:com.google.Chrome"])
        XCTAssertEqual(targets["a-app:com.google.Chrome"]?.members, chrome)
    }

    func testARowIdResolvesToTheWholeGroup() {
        let targets = CompanionTargets.index([row("a-app:com.google.Chrome", name: "Chrome", keys: chrome)])
        let target = CompanionTargets.resolve(CompanionProcessRequest(rowId: "a-app:com.google.Chrome", pid: 100), in: targets)
        XCTAssertEqual(target?.members, chrome, "quitting the app must reach every process of it")
    }

    func testARowIdTheMacNoLongerShowsResolvesToNothing() {
        let targets = CompanionTargets.index([row("p-100-11", keys: [chrome[0]])])
        // The pid was recycled: the new process has a new start time, hence a new row id.
        XCTAssertNil(CompanionTargets.resolve(CompanionProcessRequest(rowId: "p-100-99", pid: 100), in: targets))
    }

    func testAnOlderPhoneSendingOnlyAPidActsOnThatOneProcessWithItsStartTime() {
        let targets = CompanionTargets.index([row("a-app:com.google.Chrome", keys: chrome)])
        let target = CompanionTargets.resolve(CompanionProcessRequest(rowId: nil, pid: 101), in: targets)
        XCTAssertEqual(target?.members, [chrome[1]])
        XCTAssertEqual(target?.members.first?.startTime, 12)
    }

    func testAPidTheMacNeverListedIsRefused() {
        let targets = CompanionTargets.index([row("a-app:com.google.Chrome", keys: chrome)])
        XCTAssertNil(CompanionTargets.resolve(CompanionProcessRequest(rowId: nil, pid: 4242), in: targets))
        XCTAssertNil(CompanionTargets.resolve(CompanionProcessRequest(), in: targets))
    }

    func testHistoryRowsGetTheirOwnMessage() {
        XCTAssertTrue(CompanionTargets.unresolvedMessage(for: CompanionProcessRequest(rowId: "h-x", pid: nil)).contains("history"))
        XCTAssertTrue(CompanionTargets.unresolvedMessage(for: CompanionProcessRequest(rowId: "p-1-2", pid: 1)).contains("no longer"))
    }
}

final class CompanionProcessRoutingTests: XCTestCase {
    private let code = "ABCD2345"
    private let chrome = [ProcessKey(pid: 100, startTime: 11), ProcessKey(pid: 101, startTime: 12)]

    private func server(quit: Bool = true) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        server.allowRemoteQuit = quit
        let row = HogRow(id: "a-app:com.google.Chrome", keys: chrome, name: "Chrome", detail: "", cpuPercent: 0, memoryBytes: 0, peakMemoryBytes: nil, presence: nil, icon: nil, path: nil, isApp: true, isGroup: true, canQuit: true, quitBlockReason: nil)
        server.update(snapshot: CompanionServerRoutingTests.minimalSnapshot(), targets: CompanionTargets.index([row]))
        server.syncOnQueue {}
        return server
    }

    private func reply(_ server: CompanionServer, _ request: Data) -> (status: Int, body: Data)? {
        guard case .reply(let data) = server.syncOnQueue({ server.disposition(for: request) }) else { return nil }
        return CompanionHTTP.parseResponse(data)
    }

    func testQuitByRowReachesTheHandlerWithEveryMember() {
        let server = server()
        var received: CompanionTarget?
        var forced: Bool?
        server.onRemoteQuit = { target, force in
            received = target
            forced = force
            return (200, Data("{}".utf8))
        }
        let result = reply(server, CompanionHTTP.quitRequest(token: code, pid: 100, rowId: "a-app:com.google.Chrome", force: true))
        XCTAssertEqual(result?.status, 200)
        XCTAssertEqual(received?.members, chrome)
        XCTAssertEqual(forced, true)
    }

    func testQuitOfAnUnknownRowNeverReachesTheHandler() throws {
        let server = server()
        server.onRemoteQuit = { _, _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let result = try XCTUnwrap(reply(server, CompanionHTTP.quitRequest(token: code, pid: 100, rowId: "p-100-99")))
        XCTAssertEqual(result.status, 400)
        let decoded = try JSONDecoder().decode(CompanionQuitResponse.self, from: result.body)
        XCTAssertEqual(decoded.status, "changed")
        XCTAssertNotNil(decoded.error)
    }

    func testTameByBarePidResolvesToOneMemberAndAnUnlistedPidIsRefused() throws {
        let server = server()
        var received: CompanionTarget?
        server.onRemoteTame = { target, _ in received = target; return (200, Data("{}".utf8)) }
        _ = reply(server, CompanionHTTP.tameRequest(token: code, pid: 101))
        XCTAssertEqual(received?.members, [chrome[1]])

        received = nil
        let refused = try XCTUnwrap(reply(server, CompanionHTTP.tameRequest(token: code, pid: 4242)))
        XCTAssertEqual(refused.status, 400)
        XCTAssertNil(received)
    }

    func testQuitIsRefusedWhenTheOwnerHasNotAllowedIt() {
        let server = server(quit: false)
        server.onRemoteQuit = { _, _ in XCTFail("must not reach the handler"); return (200, Data()) }
        XCTAssertEqual(reply(server, CompanionHTTP.quitRequest(token: code, pid: 100, rowId: "a-app:com.google.Chrome"))?.status, 403)
    }

    func testARequestThatNamesNothingIsBad() {
        let server = server()
        server.onRemoteQuit = { _, _ in XCTFail("must not reach the handler"); return (200, Data()) }
        let bare = Data("POST /v1/quit HTTP/1.1\r\nAuthorization: Bearer ABCD2345\r\n\r\n".utf8)
        XCTAssertEqual(reply(server, bare)?.status, 400)
    }

    func testRowIdWithColonsAndSpacesSurvivesTheRoundTrip() {
        let id = "a-app:com.example.My App"
        let request = CompanionHTTP.quitRequest(token: code, pid: 7, rowId: id)
        var seen: CompanionProcessRequest?
        _ = CompanionHTTP.response(request: request, body: Data(), token: code, quitHandler: { req, _ in seen = req; return (200, Data()) })
        XCTAssertEqual(seen?.rowId, id)
        XCTAssertEqual(seen?.pid, 7)
    }
}
