import XCTest

@testable import HogHunter

/// The phone's controls: how the server routes a request without blocking its
/// queue, what the Network tab is fed, and that exclusion edits from the phone
/// and the Mac cannot undo each other.
final class CompanionServerRoutingTests: XCTestCase {
    private let code = "ABCD2345"
    /// The paired phone's own token, issued by whichever server a test builds.
    private var deviceToken = ""

    private func makeServer(allowClean: Bool = true) -> CompanionServer {
        let server = CompanionServer()
        server.updateToken(code)
        deviceToken = server.devices.issue(name: "Test iPhone").token
        server.allowRemoteClean = allowClean
        // `updateToken` is queued; this drains it.
        server.syncOnQueue {}
        return server
    }

    private func status(of response: Data) -> Int? {
        CompanionHTTP.parseResponse(response)?.status
    }

    func testCleanIsStartedOffTheRouterNotAnsweredInline() {
        let server = makeServer()
        var handlerCalls = 0
        server.onRemoteClean = { _, _ in handlerCalls += 1 }

        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.cleanRequest(token: deviceToken)) }

        XCTAssertEqual(disposition, .startClean(nil))
        XCTAssertEqual(handlerCalls, 0, "routing must not run the clean on the server queue")
    }

    func testSnapshotPollIsAnsweredImmediatelyWhileACleanIsRunning() {
        let server = makeServer()
        var finishClean: (@Sendable (CompanionServer.Reply) -> Void)?
        server.onRemoteClean = { _, completion in finishClean = completion }
        server.update(snapshot: Self.minimalSnapshot())

        let started = server.syncOnQueue { server.disposition(for: CompanionHTTP.cleanRequest(token: deviceToken)) }
        XCTAssertEqual(started, .startClean(nil))
        // The clean is "running": its completion has not been called.  A
        // snapshot poll on the same queue must still be served.
        let poll = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: code)) }
        guard case .reply(let response) = poll else { return XCTFail("poll was not answered inline") }
        XCTAssertEqual(status(of: response), 200)
        XCTAssertNil(finishClean, "the clean handler is only invoked when the connection is handed over")
    }

    func testCleanIsRefusedWhenTheOwnerHasNotAllowedIt() {
        let server = makeServer(allowClean: false)
        server.onRemoteClean = { _, _ in XCTFail("must not start") }

        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.cleanRequest(token: deviceToken)) }

        guard case .reply(let response) = disposition else { return XCTFail("expected an inline refusal") }
        XCTAssertEqual(status(of: response), 403)
    }

    func testCleanNeedsTheCode() {
        let server = makeServer()
        server.onRemoteClean = { _, _ in XCTFail("must not start") }

        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.cleanRequest(token: "WRONG234")) }

        guard case .reply(let response) = disposition else { return XCTFail("expected an inline refusal") }
        XCTAssertEqual(status(of: response), 401)
    }

    func testCleanWithNoHandlerIsNotImplemented() {
        let server = makeServer()
        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.cleanRequest(token: deviceToken)) }
        guard case .reply(let response) = disposition else { return XCTFail("expected an inline reply") }
        XCTAssertEqual(status(of: response), 501)
    }

    func testSnapshotServedHookFiresOnlyForAnAuthorizedPoll() {
        let server = makeServer()
        server.update(snapshot: Self.minimalSnapshot())
        var served = 0
        server.onSnapshotServed = { served += 1 }

        _ = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: "WRONG234")) }
        XCTAssertEqual(served, 0)
        _ = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: code)) }
        XCTAssertEqual(served, 1)
        _ = server.syncOnQueue { server.disposition(for: CompanionHTTP.cleanRequest(token: deviceToken)) }
        XCTAssertEqual(served, 1, "only snapshot fetches count")
    }

    func testOneShotReplySendsOnlyTheFirstAnswer() {
        var sent: [Data] = []
        let lock = NSLock()
        let once = CompanionOneShotReply { data in
            lock.lock(); sent.append(data); lock.unlock()
        }
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            once.send(Data([UInt8(index)]))
        }
        XCTAssertEqual(sent.count, 1)
    }

    func testRefusalNamesTheRunningCleanWhicheverSideStartedIt() {
        XCTAssertNil(HogStore.cleanRefusal(remoteInFlight: false, macIsCleaning: false))
        for (remote, mac) in [(true, false), (false, true), (true, true)] {
            let refusal = HogStore.cleanRefusal(remoteInFlight: remote, macIsCleaning: mac)
            XCTAssertEqual(refusal?.status, 409)
            let json = refusal.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: String] }
            XCTAssertEqual(json?["status"], "busy")
            XCTAssertNotNil(json?["error"])
        }
    }

    func testReasonPhrasesCoverTheNewStatuses() {
        XCTAssertEqual(CompanionHTTP.reason(for: 409), "Conflict")
        XCTAssertEqual(CompanionHTTP.reason(for: 504), "Gateway Timeout")
        let reply = CompanionHTTP.jsonReply(status: 409, body: Data("{}".utf8))
        XCTAssertEqual(CompanionHTTP.parseResponse(reply)?.status, 409)
    }

    static func minimalSnapshot() -> CompanionSnapshot {
        CompanionSnapshotBuilder.make(
            hostName: "Test Mac", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .perCore, pulse: MachinePulse.empty, rows: []
        )
    }
}

final class CompanionNetworkCacheTests: XCTestCase {
    private func usage(_ pid: pid_t, _ name: String, established: Int) -> NetworkUsage {
        NetworkUsage(pid: pid, bundleId: nil, name: name, isRunning: true, openSockets: established, establishedSockets: established, remoteHostCount: 2, topRemoteHosts: ["1.2.3.4:443"])
    }

    func testRowsAreBusiestFirstAndCapped() {
        let usages = (1...15).map { usage(pid_t($0), "app\($0)", established: $0) }
        let rows = CompanionSnapshotBuilder.networkRows(from: usages, limit: 10)
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first?.name, "app15")
        XCTAssertEqual(rows.first?.establishedCount, 15)
        XCTAssertEqual(rows.first?.uniqueRemoteHosts, 2)
        XCTAssertEqual(rows.first?.sampleRemoteHosts, ["1.2.3.4:443"])
    }

    func testBeforeTheFirstScanTheTabSaysItIsLooking() {
        let cache = CompanionNetworkCache()
        XCTAssertTrue(cache.current.rows.isEmpty)
        XCTAssertEqual(cache.current.note, CompanionNetworkCache.scanningNote)
    }

    func testRefreshStoresRowsAndReachesTheSnapshot() throws {
        let cache = CompanionNetworkCache()
        let row = CompanionNetworkRow(id: "1", name: "Safari", pid: 1, establishedCount: 4, uniqueRemoteHosts: 2, sampleRemoteHosts: ["9.9.9.9:443"])
        let done = expectation(description: "scan stored")
        cache.refreshIfStale(scan: { CompanionNetworkScan(rows: [row], note: nil) }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)

        XCTAssertEqual(cache.current.rows, [row])
        XCTAssertNil(cache.current.note)

        let snapshot = CompanionSnapshotBuilder.make(
            hostName: "Test Mac", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .perCore, pulse: MachinePulse.empty, rows: [],
            network: cache.current.rows, networkNote: cache.current.note
        )
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(snapshot))
        XCTAssertEqual(decoded.network, [row])
    }

    func testAFreshResultIsNotScannedAgainButAStaleOneIs() {
        let cache = CompanionNetworkCache()
        let scans = CompanionLocked(0)
        let first = expectation(description: "first")
        cache.refreshIfStale(maxAge: 60, scan: { scans.value += 1; return CompanionNetworkScan(rows: [], note: nil) }, completion: { first.fulfill() })
        wait(for: [first], timeout: 5)

        // Fresh: skipped.
        cache.refreshIfStale(maxAge: 60, scan: { scans.value += 1; return CompanionNetworkScan(rows: [], note: nil) })
        // Stale by the clock: scanned.
        let second = expectation(description: "second")
        cache.refreshIfStale(maxAge: 60, now: Date().addingTimeInterval(120), scan: { scans.value += 1; return CompanionNetworkScan(rows: [], note: nil) }, completion: { second.fulfill() })
        wait(for: [second], timeout: 5)
        XCTAssertEqual(scans.value, 2)
    }

    func testOnlyOneScanRunsAtATime() {
        let cache = CompanionNetworkCache()
        let scans = CompanionLocked(0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "finished")
        cache.refreshIfStale(scan: {
            scans.value += 1
            release.wait()
            return CompanionNetworkScan(rows: [], note: nil)
        }, completion: { finished.fulfill() })
        // While the first scan is blocked, more requests must not start another.
        for _ in 0..<5 {
            cache.refreshIfStale(now: Date().addingTimeInterval(3_600), scan: { scans.value += 1; return CompanionNetworkScan(rows: [], note: nil) })
        }
        release.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(scans.value, 1)
    }

    func testAnUnavailableScanKeepsItsReasonForThePhone() {
        let cache = CompanionNetworkCache()
        let done = expectation(description: "done")
        cache.refreshIfStale(scan: { CompanionNetworkScan(rows: [], note: "The Mac could not list network connections.  lsof denied") }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(cache.current.note, "The Mac could not list network connections.  lsof denied")
    }
}

final class CleanerExclusionsConcurrencyTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "hoghunter.tests.exclusions.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testUpdateAppliesToTheStoredValueNotACopy() {
        CleanerExclusions.update(in: defaults) { $0.addPath("/phone/path") }
        let result = CleanerExclusions.update(in: defaults) { $0.toggleCategory(.trash) }
        XCTAssertEqual(result.excludedPaths, ["/phone/path"])
        XCTAssertTrue(result.isCategoryExcluded(.trash))
        XCTAssertEqual(CleanerExclusions.load(from: defaults), result)
    }

    func testConcurrentUpdatesDoNotLoseWrites() {
        let count = 120
        DispatchQueue.concurrentPerform(iterations: count) { index in
            CleanerExclusions.update(in: defaults) { $0.addPath("/folder/\(index)") }
        }
        XCTAssertEqual(CleanerExclusions.load(from: defaults).excludedPaths.count, count)
    }

    @MainActor
    func testMacStoreKeepsAnEditTheIPhoneMadeSinceLaunch() {
        let store = DiskCleanerStore(
            cleaner: DiskCleaner(),
            historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults,
            rescanAfterExclusionChange: false
        )
        // The phone edits after the store loaded its copy.
        CleanerExclusions.update(in: defaults) { $0.addPath("/phone/path") }
        XCTAssertTrue(store.exclusions.excludedPaths.isEmpty, "the store still holds its launch-time copy")

        store.toggleCategoryExclusion(.userCaches)

        let stored = CleanerExclusions.load(from: defaults)
        XCTAssertEqual(stored.excludedPaths, ["/phone/path"], "the Mac edit must not undo the phone's")
        XCTAssertTrue(stored.isCategoryExcluded(.userCaches))
        XCTAssertEqual(store.exclusions, stored)
    }

    @MainActor
    func testReloadPicksUpAnEditMadeElsewhere() {
        let store = DiskCleanerStore(
            cleaner: DiskCleaner(),
            historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults,
            rescanAfterExclusionChange: false
        )
        CleanerExclusions.update(in: defaults) { $0.addPath("/phone/path") }
        store.reloadExclusions()
        XCTAssertEqual(store.exclusions.excludedPaths, ["/phone/path"])
    }

    @MainActor
    func testRemovingAPathOnTheMacKeepsTheOthers() {
        let store = DiskCleanerStore(
            cleaner: DiskCleaner(),
            historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults,
            rescanAfterExclusionChange: false
        )
        CleanerExclusions.update(in: defaults) { $0.addPath("/a"); $0.addPath("/b") }
        store.removeExcludedPath("/a")
        XCTAssertEqual(CleanerExclusions.load(from: defaults).excludedPaths, ["/b"])
    }
}

@MainActor
final class RemoteTameStatusTests: XCTestCase {
    func testATameOfAChangedProcessIsNotReportedAsSuccess() throws {
        // A start time of 1 can never match the live launchd, so this is a
        // pid that "now belongs to something else".
        let target = CompanionTarget(rowId: "p-1-1", name: "launchd", members: [ProcessKey(pid: 1, startTime: 1)])
        let suite = "hoghunter.tests.tamestatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HogStore(defaults: defaults)
        let reply = store.performRemoteTame(target: target, action: "tame")

        XCTAssertEqual(reply.status, 400)
        let decoded = try JSONDecoder().decode(CompanionTameResponse.self, from: reply.body)
        XCTAssertEqual(decoded.status, "changed")
        XCTAssertNil(decoded.message)
        XCTAssertNotNil(decoded.error)
        XCTAssertFalse(decoded.isTamed)
        XCTAssertEqual(decoded.acted, 0)
        XCTAssertEqual(decoded.skipped, 1)
    }
}

// MARK: - The names the phone sends

final class CompanionPhoneNameTests: XCTestCase {
    func testTheSortIsTheWholeNameAndNothingElse() {
        XCTAssertEqual(HogSort.fromPhone("CPU"), .cpu)
        XCTAssertEqual(HogSort.fromPhone("Memory"), .memory)
        XCTAssertEqual(HogSort.fromPhone(" Memory "), .memory)
        XCTAssertNil(HogSort.fromPhone("program"), "\"program\" merely contains \"ram\"")
        XCTAssertNil(HogSort.fromPhone("cpu usage"), "\"cpu usage\" merely contains \"cpu\"")
        XCTAssertNil(HogSort.fromPhone("ram"), "\"ram\" was never a name the Mac offered")
        XCTAssertNil(HogSort.fromPhone(""))
    }

    func testTheCpuScaleIsTheWholeNameAndNothingElse() {
        XCTAssertEqual(CpuScale.fromPhone("Per Core"), .perCore)
        XCTAssertEqual(CpuScale.fromPhone("Share of Machine"), .machineShare)
        XCTAssertEqual(CpuScale.fromPhone("Per Machine"), .machineShare)
        XCTAssertEqual(CpuScale.fromPhone("Machine Share"), .machineShare)
        XCTAssertEqual(CpuScale.fromPhone(" share of machine "), .machineShare)
        XCTAssertNil(CpuScale.fromPhone("machinesplatter"), "it merely contains \"machine\"")
        XCTAssertNil(CpuScale.fromPhone("sideways"))
        XCTAssertNil(CpuScale.fromPhone(""))
        for scale in CpuScale.allCases {
            XCTAssertEqual(CpuScale.fromPhone(scale.rawValue), scale, "the raw value the phone echoes back must map to itself")
        }
    }
}

// MARK: - The directory status line

final class CompanionDirectoryStatusTests: XCTestCase {
    private func row(title: String = "Code") -> DirectoryUsageRow {
        DirectoryUsageRow(title: title, path: "/Users/jay/Code", displayPath: "/Users/jay/Code")
    }

    func testARowInTheMiddleOfAWalkShowsTheProgress() {
        var row = row()
        row.scanStartedAt = Date(timeIntervalSince1970: 1_767_225_600)
        row.progressBytes = 1024
        row.progressEntries = 12
        row.statusText = "Scanning"
        XCTAssertEqual(row.statusLine, "1 KB scanned · 12 entries · scanning")
    }

    func testAFinishedRowShowsWhenTheWalkBegan() {
        var row = row()
        row.bytes = 2048
        row.statusText = "Complete"
        row.sampledAt = Date(timeIntervalSince1970: 1_767_225_600)
        XCTAssertEqual(row.statusLine, "walk began Dec 31, 6:00pm")
    }

    func testARowThatHasNotStartedShowsItsOwnStatus() {
        var row = row()
        row.statusText = "Waiting to measure"
        XCTAssertEqual(row.statusLine, "Waiting to measure")
    }

    func testTheStampIsTheMacsOwn() {
        XCTAssertEqual(DirectoryUsageRow.timestamp(Date(timeIntervalSince1970: 1_767_225_600)), "Dec 31, 6:00pm")
        XCTAssertEqual(DirectoryUsageRow.timestamp(Date(timeIntervalSince1970: 1_767_229_200)), "Dec 31, 7:00pm")
    }
}

// MARK: - The reply to a view change

final class CompanionViewStateTests: XCTestCase {
    private func current() -> CompanionViewState {
        CompanionViewState(window: .day, grouping: .processes, cpuScale: .machineShare, sort: .memory, sortAscending: true)
    }

    func testARequestThatNamesNoSortKeepsTheMacsOwn() {
        let resolved = current().resolving(after: CompanionViewUpdateRequest(window: "Past Hour"))
        XCTAssertEqual(resolved.sort, .memory, "the reply must not claim a sort the Mac is not using")
        XCTAssertTrue(resolved.sortAscending, "the reply must not claim a direction the Mac is not using")
        XCTAssertEqual(resolved.window, .hour)
        XCTAssertEqual(resolved.grouping, .processes, "a field the request leaves out keeps the Mac's value")
        XCTAssertEqual(resolved.cpuScale, .machineShare)
    }

    func testARequestThatNamesTheSortIsTaken() {
        let resolved = current().resolving(after: CompanionViewUpdateRequest(sort: "Memory"))
        XCTAssertEqual(resolved.sort, .memory)
    }

    func testARequestThatAsksForTheOtherSortIsTaken() {
        let start = CompanionViewState(sort: .memory, sortAscending: true)
        let resolved = start.resolving(after: CompanionViewUpdateRequest(sort: "CPU"))
        XCTAssertEqual(resolved.sort, .cpu)
        XCTAssertFalse(resolved.sortAscending, "the Mac puts the list back the right way round when the sort changes")
    }

    func testARequestThatNamesTheDirectionIsTaken() {
        let resolved = current().resolving(after: CompanionViewUpdateRequest(sortAscending: false))
        XCTAssertFalse(resolved.sortAscending)
        XCTAssertEqual(resolved.sort, .memory, "the direction does not change the sort")
    }

    func testTheWindowAndGroupingAreTheWholeNames() {
        XCTAssertEqual(CompanionViewState.window(from: "Now"), .now)
        XCTAssertEqual(CompanionViewState.window(from: "Past Hour"), .hour)
        XCTAssertEqual(CompanionViewState.window(from: "Past 24 Hours"), .day)
        XCTAssertNil(CompanionViewState.window(from: "Last Week"))
        XCTAssertEqual(CompanionViewState.grouping(from: "Apps"), .apps)
        XCTAssertEqual(CompanionViewState.grouping(from: "Processes"), .processes)
        XCTAssertNil(CompanionViewState.grouping(from: "Everything"))
    }

    func testAnUnknownSortLeavesTheMacsOwnAlone() {
        let resolved = current().resolving(after: CompanionViewUpdateRequest(sort: "program"))
        XCTAssertEqual(resolved.sort, .memory)
    }
}

// MARK: - The resolved appearance on the wire

final class CompanionResolvedAppearanceTests: XCTestCase {
    func testTheSummaryCarriesTheResolvedAppearance() throws {
        let summary = CompanionSettingsSummary(
            refreshInterval: 5,
            alertsEnabled: true,
            alertThresholdPercent: 300,
            alertSustainedMinutes: 5,
            webhookConfigured: false,
            resolvedAppearance: "Dark"
        )
        let data = try JSONEncoder().encode(summary)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["resolvedAppearance"] as? String, "Dark")
        let decoded = try JSONDecoder().decode(CompanionSettingsSummary.self, from: data)
        XCTAssertEqual(decoded.resolvedAppearance, "Dark")
    }

    func testAMacThatPredatesTheFieldStillDecodes() throws {
        let json = """
        {
          "refreshInterval": 5,
          "alertsEnabled": true,
          "alertThresholdPercent": 300,
          "alertSustainedMinutes": 5,
          "webhookConfigured": false
        }
        """
        let decoded = try JSONDecoder().decode(CompanionSettingsSummary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.resolvedAppearance, "Light")
    }

    func testTheMacsOwnChoiceResolvesToARealAppearance() {
        XCTAssertEqual(AppearanceChoice.light.resolvedName, "Light")
        XCTAssertEqual(AppearanceChoice.dark.resolvedName, "Dark")
        let system = AppearanceChoice.system.resolvedName
        XCTAssertTrue(system == "Light" || system == "Dark", "System must never travel as itself: \(system)")
    }
}

// MARK: - The step toggle that has not landed yet

@MainActor
final class MaintainStepPersistTests: XCTestCase {
    /// An Infisical that is never configured, so a test that changes a step
    /// cannot reach the real service.
    private func unconfiguredInfisical() -> InfisicalSettings {
        InfisicalSettings(store: InfisicalStore(), credentialProvider: { nil })
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-step-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheToggleIsNotPersistedUntilTheSaveLands() async throws {
        let gate = AsyncGate()
        let launches = CompanionLocked<[[String]]>([])
        let store = MaintainStore(
            supportDirectory: try temporaryDirectory(),
            repoRoot: try temporaryDirectory(),
            launcher: { arguments in
                launches.value.append(arguments)
                await gate.wait()
                return true
            },
            infisical: unconfiguredInfisical(),
            infisicalStore: InfisicalStore()
        )
        XCTAssertTrue(store.stepTogglesPersisted, "nothing is being saved, so everything is on disk")

        store.setStepEnabled("coolify_remote", enabled: true)
        XCTAssertFalse(store.stepTogglesPersisted, "the save has not landed yet")

        for _ in 0..<200 where launches.value.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(launches.value, [["--set-step", "coolify_remote", "on"]])
        XCTAssertFalse(store.stepTogglesPersisted, "the script is still saving the step")

        gate.open()
        for _ in 0..<200 where !store.stepTogglesPersisted { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.stepTogglesPersisted, "the save has landed, so the step can be run")
    }

    func testASaveThatFailsSaysSoAndFreesTheFlag() async throws {
        let store = MaintainStore(
            supportDirectory: try temporaryDirectory(),
            repoRoot: try temporaryDirectory(),
            launcher: { _ in false },
            infisical: unconfiguredInfisical(),
            infisicalStore: InfisicalStore()
        )
        store.setStepEnabled("coolify_remote", enabled: true)
        XCTAssertFalse(store.stepTogglesPersisted)
        for _ in 0..<200 where !store.stepTogglesPersisted { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.stepTogglesPersisted, "a failed save must not leave the step unsavable")
        XCTAssertEqual(store.lastError, "Could not save that step setting.")
    }
}

// MARK: - The intervals the Mac will accept

final class CompanionIntervalValidatorTests: XCTestCase {
    /// The Mac's own rule for both intervals: a value of a second or more.
    /// The phone offers the Mac's own choices plus whatever the Mac is
    /// already using, so the Mac must never refuse a value it holds.
    func testAValueTheMacAlreadyHoldsIsNeverRefused() {
        for interval in [1.0, 2.0, 7.5, 20.0, 45.0, 300.0] {
            var request = CompanionSettingsUpdateRequest()
            request.refreshInterval = interval
            request.backgroundRefreshInterval = interval
            guard case .success = CompanionSettingsValidator.validate(request) else {
                XCTFail("the Mac refuses \(interval), a value it would hold itself")
                continue
            }
        }
    }

    func testAnIntervalTheMacCannotUseIsRefused() {
        for interval in [0.0, 0.5, -1.0] {
            var request = CompanionSettingsUpdateRequest()
            request.refreshInterval = interval
            guard case .failure = CompanionSettingsValidator.validate(request) else {
                XCTFail("the Mac accepts \(interval), which it cannot run")
                continue
            }
        }
    }

    func testTheRuleIsTheOneTheMacsOwnSettingsUse() {
        XCTAssertTrue(CompanionSettingsValidator.isAcceptedInterval(1))
        XCTAssertTrue(CompanionSettingsValidator.isAcceptedInterval(60))
        XCTAssertFalse(CompanionSettingsValidator.isAcceptedInterval(0.999))
        XCTAssertFalse(CompanionSettingsValidator.isAcceptedInterval(.nan))
        XCTAssertFalse(CompanionSettingsValidator.isAcceptedInterval(.infinity))
    }
}
