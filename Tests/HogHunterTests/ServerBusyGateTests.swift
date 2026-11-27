import XCTest

@testable import HogHunter

// A3: one shared server gate.
//
// The store owns a single `ServerControl` (and a single
// `ServerMaintenanceControl`) that the Mac's menus and the phone's server
// routes both run, so a Mac action and a phone action cannot run at once.
// Nothing here runs SSH: the control takes an injected runner, and a gate
// holds the first run open until the test lets it finish.
//
// A4's tame fixtures live here too, so this stream touches no other test
// file: the builder is exercised through its public `make`, the same way
// the existing builder tests call it.

/// Holds a runner open until the test lets it finish.
private final class ServerGate: @unchecked Sendable {
    private let parked = CompanionLocked<[CheckedContinuation<Void, Never>]>([])
    func wait() async {
        await withCheckedContinuation { continuation in
            parked.withLock { $0.append(continuation) }
        }
    }
    func releaseOne() {
        let next: CheckedContinuation<Void, Never>? = parked.withLock { list in
            guard !list.isEmpty else { return nil }
            return list.removeFirst()
        }
        next?.resume()
    }
}

private func gateProcess(nice: Int? = 0) -> VPSProcess {
    VPSProcess(pid: 4242, name: "gate-worker", startTime: 987_654, owner: "app", container: nil,
               cpuPercent: 12, memoryBytes: 100, bootID: "boot-gate", nice: nice,
               allowedActions: ["quit", "force-quit", "tame", "untame", "sample"])
}

private func gateReading(processes: [VPSProcess] = [gateProcess()]) -> VPSStatusSnapshot {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return VPSStatusSnapshot(generatedAt: formatter.string(from: Date().addingTimeInterval(-60)),
                             host: "server-1", devices: [:], processes: processes)
}

// MARK: - The shared gate

@MainActor
final class ServerSharedGateTests: XCTestCase {
    private func store(control: ServerControl) throws -> HogStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-server-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let reading = gateReading()
        let maintain = MaintainStore(supportDirectory: directory, repoRoot: directory, launcher: { _ in
            XCTFail("a test must not launch the script")
            return true
        }, infisical: IsolatedInfisical.make(), vpsFetcher: { _ in reading })
        let suite = "hoghunter-server-gate-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(),
                        maintain: maintain, startImmediately: false, serverControl: control)
    }

    /// The store keeps the control it was given, and the phone routes run
    /// on that same instance: a phone action in flight refuses the Mac's
    /// next action on it.
    func testThePhoneRoutesRunOnTheStoresOwnControl() async throws {
        let gate = ServerGate()
        let control = ServerControl(runner: { _, _ in
            await gate.wait()
            return #"{"ok":true}"#
        })
        let store = try store(control: control)
        XCTAssertTrue(store.serverControl === control)
        addTeardownBlock { [store] in
            await MainActor.run { store.maintain.vpsStore.stopPolling() }
        }
        store.maintain.vpsStore.setHost("server.tailnet")
        for _ in 0..<200 where store.maintain.vpsStore.snapshot == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let row = try XCTUnwrap(store.maintain.vpsStore.snapshot?.processes?.first)
        let rowID = CompanionServerStatusBuilder.opaqueID(row.id)
        let phone = Task { await store.serverActions.perform(.process(rowId: rowID, action: "quit"), device: "Test iPhone") }
        for _ in 0..<200 where !control.isWorking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(control.isWorking, "the phone's action holds the shared control")
        await store.serverControl.stop(process: row, host: "server.tailnet", allowWorkloadInterruption: false)
        XCTAssertEqual(store.serverControl.lastOutcome, .refused("Another server action is already running."))
        gate.releaseOne()
        let reply = await phone.value
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(store.serverControl.lastOutcome, .acted("Asked gate-worker to quit"))
    }

    /// The guard itself: a second run refuses while the first is in flight,
    /// and the first still lands once its runner answers.
    func testASecondRunIsRefusedWhileTheFirstIsInFlight() async throws {
        let gate = ServerGate()
        let control = ServerControl(runner: { _, _ in
            await gate.wait()
            return #"{"ok":true}"#
        })
        let row = gateProcess()
        let first = Task { await control.stop(process: row, host: "server.tailnet", allowWorkloadInterruption: false) }
        for _ in 0..<200 where !control.isWorking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(control.isWorking)
        await control.tame(process: row, host: "server.tailnet", allowWorkloadInterruption: false)
        XCTAssertEqual(control.lastOutcome, .refused("Another server action is already running."))
        gate.releaseOne()
        await first.value
        XCTAssertEqual(control.lastOutcome, .acted("Asked gate-worker to quit"))
    }
}

// MARK: - Tame state

final class ServerTameStateTests: XCTestCase {
    func testUnknownWithoutAPriority() {
        XCTAssertEqual(gateProcess(nice: nil).tameState, .unknown)
    }

    func testTamedAtNineteen() {
        XCTAssertEqual(gateProcess(nice: 19).tameState, .tamed)
    }

    func testUntamedAtZero() {
        XCTAssertEqual(gateProcess(nice: 0).tameState, .untamed)
    }

    func testSixteenIsNotTamed() {
        XCTAssertEqual(gateProcess(nice: 16).tameState, .untamed)
    }
}

// MARK: - The phone's tame labels

final class ServerTameLabelBuilderTests: XCTestCase {
    private func actions(processes: [VPSProcess]) -> [[String]] {
        let status = CompanionServerStatusBuilder.make(
            configuredHost: "server-1",
            snapshot: gateReading(processes: processes),
            error: nil, fetchedAt: Date(), cpuHistory: [],
            databaseChange: { _ in nil }, directoryChange: { _ in nil }
        )
        return status.processes?.map { $0.actions ?? [] } ?? []
    }

    private func tamedFlags(processes: [VPSProcess]) -> [Bool?] {
        let status = CompanionServerStatusBuilder.make(
            configuredHost: "server-1",
            snapshot: gateReading(processes: processes),
            error: nil, fetchedAt: Date(), cpuHistory: [],
            databaseChange: { _ in nil }, directoryChange: { _ in nil }
        )
        return status.processes?.map(\.isTamed) ?? []
    }

    /// The phone renders one label per action it is offered: a tamed
    /// process offers only the restore, an untamed one only the tame, and
    /// an unknown priority offers both rather than guessing.
    func testThePhoneSeesOneTameLabel() {
        let offered = actions(processes: [gateProcess(nice: nil), gateProcess(nice: 19),
                                          gateProcess(nice: 0), gateProcess(nice: 16)])
        XCTAssertEqual(offered.count, 4)
        XCTAssertTrue(offered[0].contains("tame") && offered[0].contains("untame"), "unknown keeps both")
        XCTAssertFalse(offered[1].contains("tame"))
        XCTAssertTrue(offered[1].contains("untame"))
        XCTAssertTrue(offered[2].contains("tame"))
        XCTAssertFalse(offered[2].contains("untame"))
        XCTAssertTrue(offered[3].contains("tame"), "16 is not the tame target")
        XCTAssertFalse(offered[3].contains("untame"))
        for labels in offered {
            XCTAssertTrue(labels.contains("quit") && labels.contains("forceQuit") && labels.contains("sample"),
                          "the other actions are untouched: \(labels)")
        }
    }

    /// The caption flag comes from the same state as the labels: unknown
    /// stays nil, 19 reads tamed, anything else reads untamed — so a
    /// nice-16 process never shows "Tamed" beside a lone "Tame…".
    func testTheTamedCaptionMatchesTheOfferedLabels() {
        XCTAssertEqual(tamedFlags(processes: [gateProcess(nice: nil), gateProcess(nice: 19),
                                               gateProcess(nice: 0), gateProcess(nice: 16)]),
                       [nil, true, false, false])
    }
}
