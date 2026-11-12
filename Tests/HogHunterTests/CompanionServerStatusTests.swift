import XCTest

@testable import HogHunter

// Server status on the phone, stage 1 (read-only).
//
// Nothing here runs SSH: every reading comes from a stub fetcher or is handed
// to the builder directly.

private let canaryHost = "canary-host-nbg1"
private let canaryProcess = "canary-process-name"
private let canaryContainer = "canary-container-name"
private let canaryOwner = "canary-owner"
private let canaryDirectory = "/srv/canary-directory"
private let canaryDatabase = "canary_database_key"
private let canaryReason = "canary tool reason names /root/canary-path"
private let canaryNote = "300GB disk: canary mount note"
private let canaryMount = "/mnt/canary-mount"
private let canaryWorkload = "canary-workload-name"
private let canaryError = "ssh: connect to host canary-host-nbg1 port 22: Connection refused"
private let canaries = [
    canaryHost, canaryProcess, canaryContainer, canaryOwner, canaryDirectory, canaryDatabase,
    "canary tool reason", "/root/canary-path", "canary mount note", canaryMount, canaryWorkload,
    "Connection refused", "server.tool", "server.disk", "Critical Service Stopped",
]

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// A reading with one of everything, and a canary in every field that names
/// a server internal.  `withSizes: false` leaves out the databases and
/// directories, which a real store would record in the shared growth history.
private func fullReading(now: Date = Date(), withSizes: Bool = true) -> VPSStatusSnapshot {
    VPSStatusSnapshot(
        generatedAt: iso(now.addingTimeInterval(-60)),
        host: canaryHost,
        devices: [
            "root": VPSDevice(mount: "/", freeBytes: 2 * 1024 * 1024 * 1024, note: canaryNote),
            "extra-thing": VPSDevice(mount: canaryMount, freeBytes: 1024, note: nil),
        ],
        appDbs: withSizes ? ["st_app_db": 1_000, canaryDatabase: 2_000] : nil,
        cpu: VPSCPU(pct: 91, load1: 2.5, cores: 8),
        memory: VPSMemory(totalBytes: 1_000, usedBytes: 950, availableBytes: 50),
        swap: VPSSwap(totalBytes: 1_000, usedBytes: 900, freeBytes: 100),
        memoryPressure: VPSMemoryPressure(
            sampledAt: iso(now.addingTimeInterval(-60)),
            durationSeconds: 2,
            swapInBytesPerSecond: 1_024,
            swapOutBytesPerSecond: nil,
            memorySomeAvg10: nil,
            memoryFullAvg10: 1.5
        ),
        largestDirs: withSizes ? [VPSDirectory(path: canaryDirectory, bytes: 5_000)] : nil,
        toolStatuses: [
            VPSToolStatus(id: "docker", name: "Docker", state: .stopped, count: 0, reason: canaryReason),
        ],
        processes: [
            VPSProcess(pid: 4242, name: canaryProcess, startTime: 987_654, owner: canaryOwner, container: canaryContainer,
                       cpuPercent: 12, memoryBytes: 100, bootID: "boot-id-canary", swapBytes: nil, nice: 0,
                       allowedActions: ["stop"], protectionReason: nil),
        ],
        coolify: [
            VPSCoolifyResource(uuid: "uuid-canary", name: canaryWorkload, container: "container-canary", type: "service", status: "running",
                               cpuPercent: nil, memoryBytes: nil, image: "image-canary", startedAt: "2026-11-04T00:00:00Z",
                               containerID: String(repeating: "a", count: 64)),
        ]
    )
}

private func build(
    host: String = "fake-host",
    reading: VPSStatusSnapshot?,
    error: String? = nil,
    history: [Double] = [],
    databaseChange: @escaping (String) -> Double? = { _ in nil },
    directoryChange: @escaping (String) -> Double? = { _ in nil },
    now: Date = Date()
) -> CompanionServerStatus {
    CompanionServerStatusBuilder.make(
        configuredHost: host,
        snapshot: reading,
        error: error,
        fetchedAt: reading == nil ? nil : now,
        cpuHistory: history,
        databaseChange: databaseChange,
        directoryChange: directoryChange,
        now: now
    )
}

// MARK: - The block

final class CompanionServerStatusBuilderTests: XCTestCase {
    func testThePhoneCanTellTheFourStatesApart() {
        let now = Date()
        XCTAssertEqual(build(host: "  ", reading: nil, now: now).resolvedState(now: now), .notConfigured)
        XCTAssertEqual(build(reading: nil, now: now).resolvedState(now: now), .noReading)
        XCTAssertEqual(build(reading: nil, error: "boom", now: now).resolvedState(now: now), .error)
        XCTAssertEqual(build(reading: fullReading(now: now), now: now).resolvedState(now: now), .ok)
        let old = fullReading(now: now.addingTimeInterval(-3_600))
        XCTAssertEqual(build(reading: old, now: now).resolvedState(now: now), .stale)
    }

    func testAnErrorKeepsTheEarlierReadingsAndSaysSo() {
        let status = build(reading: fullReading(), error: "ssh: refused\nsecond line")
        XCTAssertEqual(status.resolvedState(), .error)
        XCTAssertEqual(status.errorText, "ssh: refused", "one line only")
        XCTAssertNotNil(status.cpu)
        XCTAssertTrue(status.hasReading)
    }

    func testANotConfiguredServerCarriesNothingEvenWithAnOldReading() {
        let status = build(host: "", reading: fullReading(), error: "stale error")
        XCTAssertEqual(status.resolvedState(), .notConfigured)
        XCTAssertNil(status.errorText)
        XCTAssertFalse(status.hasReading)
    }

    func testAReadingAgesOnThePhoneAfterTheMacGoesQuiet() {
        let sent = Date()
        let status = build(reading: fullReading(now: sent), now: sent)
        XCTAssertEqual(status.state, "ok")
        XCTAssertEqual(status.resolvedState(now: sent.addingTimeInterval(CompanionServerStatus.staleAfter + 120)), .stale)
    }

    func testAnUnreadableTimeOrAClockFarAheadIsNotCurrent() {
        XCTAssertEqual(CompanionServerStatus.readingState(generatedAt: nil, now: Date()), .stale)
        XCTAssertEqual(CompanionServerStatus.readingState(generatedAt: Date().addingTimeInterval(3_600), now: Date()), .stale)
    }

    func testAStateFromALaterMacDoesNotClaimAReading() {
        XCTAssertEqual(CompanionServerStatus(state: "somethingNew").resolvedState(), .noReading)
    }

    func testMissingNumbersStayNilAndNeverReadAsZero() throws {
        let reading = VPSStatusSnapshot(
            generatedAt: iso(Date()),
            host: "host",
            devices: ["root": VPSDevice(mount: "/", freeBytes: 1_024, note: nil)],
            cpu: nil,
            memory: VPSMemory(totalBytes: 0, usedBytes: 0, availableBytes: 0),
            swap: VPSSwap(totalBytes: 0, usedBytes: 0, freeBytes: 0)
        )
        let status = build(reading: reading)
        XCTAssertNil(status.cpu)
        XCTAssertNil(status.memory, "VPSMemory says 0% for a zero total, which is not a reading")
        XCTAssertNil(status.swap?.percent)
        XCTAssertNil(status.swap?.percentText)
        XCTAssertEqual(status.swap?.detail, "No swap")
        XCTAssertNil(status.headline?.cpuText)
        XCTAssertNil(status.headline?.memoryText)
        let root = try XCTUnwrap(status.devices?.first)
        XCTAssertNil(root.usedPercent, "no size in the note, so no percentage")
        XCTAssertNil(root.usedText)
        XCTAssertNil(root.totalText)
        XCTAssertNotNil(root.freeText)

        let full = build(reading: fullReading(withSizes: true))
        XCTAssertNil(full.pressure?.swapOutText)
        XCTAssertNil(full.directories?.first?.changeText, "no day of history yet")
        XCTAssertNil(full.directories?.first?.changePercent)
        XCTAssertNil(full.workloads?.first?.cpuText)
    }

    func testAZeroThatWasMeasuredIsStillShown() {
        let reading = VPSStatusSnapshot(generatedAt: iso(Date()), host: "h", devices: [:], cpu: VPSCPU(pct: 0, load1: 0, cores: 4))
        let status = build(reading: reading)
        XCTAssertEqual(status.cpu?.percent, 0)
        XCTAssertEqual(status.cpu?.percentText, "0.0%")
        XCTAssertEqual(status.cpu?.loadText, "0.00")
    }

    func testANonFiniteNumberCannotStopTheSnapshotEncoding() throws {
        let reading = VPSStatusSnapshot(
            generatedAt: iso(Date()),
            host: "h",
            devices: [:],
            largestDirs: [VPSDirectory(path: "/a", bytes: 1)],
            processes: [VPSProcess(pid: 1, name: "p", startTime: 1, owner: nil, container: nil, cpuPercent: .nan, memoryBytes: nil)]
        )
        var status = build(reading: reading, history: [1, .infinity, .nan, 2], directoryChange: { _ in .infinity })
        status.cpu = CompanionServerCPU(history: status.cpu?.history)
        XCTAssertNil(status.directories?.first?.changePercent)
        XCTAssertNil(status.processes?.first?.cpuText)
        var snapshot = CompanionTestSnapshots.plain()
        snapshot.server = status
        XCTAssertNoThrow(try CompanionJSON.encode(snapshot))

        let cpu = build(reading: VPSStatusSnapshot(generatedAt: iso(Date()), host: "h", devices: [:], cpu: VPSCPU(pct: .nan, load1: .infinity, cores: 0)), history: [1, .nan])
        XCTAssertNil(cpu.cpu?.percent)
        XCTAssertNil(cpu.cpu?.severity)
        XCTAssertNil(cpu.cpu?.loadText)
        XCTAssertNil(cpu.cpu?.cores)
        XCTAssertEqual(cpu.cpu?.history, [1])
        snapshot.server = cpu
        XCTAssertNoThrow(try CompanionJSON.encode(snapshot))
    }

    func testRowIDsCarryNoPidBootIDOrContainerIdentity() throws {
        let status = build(reading: fullReading())
        var snapshot = CompanionTestSnapshots.plain()
        snapshot.server = status
        let json = try XCTUnwrap(String(data: CompanionJSON.encode(snapshot), encoding: .utf8))
        for secret in ["4242", "987654", "boot-id-canary", "uuid-canary", "container-canary", "image-canary", String(repeating: "a", count: 64), "allowed"] {
            XCTAssertFalse(json.contains(secret), "\(secret) must not reach the phone")
        }
        let process = try XCTUnwrap(status.processes?.first)
        XCTAssertEqual(process.id.count, 16)
        XCTAssertEqual(process.id, CompanionServerStatusBuilder.opaqueID(try XCTUnwrap(fullReading().processes?.first).id), "the Mac can resolve it again")
    }

    func testDailyChangeIsCarried() {
        let status = build(
            reading: fullReading(),
            databaseChange: { $0 == "st_app_db" ? 12.5 : nil },
            directoryChange: { _ in -3 }
        )
        XCTAssertEqual(status.databases?.first?.name, "Socratic Trade")
        XCTAssertEqual(status.databases?.first?.changePercent, 12.5)
        XCTAssertNotNil(status.databases?.first?.changeText)
        XCTAssertEqual(status.databases?.last?.id, canaryDatabase, "a database the Mac has no name for still travels")
        XCTAssertNil(status.databases?.last?.changeText)
        XCTAssertEqual(status.directories?.first?.changePercent, -3)
    }

    func testRowsAreBounded() {
        let many = (0..<50).map { VPSProcess(pid: $0, name: "p\($0)", startTime: 1, owner: nil, container: nil, cpuPercent: 1, memoryBytes: nil) }
        let status = build(reading: VPSStatusSnapshot(generatedAt: iso(Date()), host: "h", devices: [:], processes: many))
        XCTAssertEqual(status.processes?.count, CompanionServerStatusBuilder.processLimit)
        XCTAssertEqual(status.processCount, 50)
    }

    func testFreshnessMatchesTheMacsRules() {
        let now = Date()
        for age in [-10.0, -4, 0, 899, 901] {
            for duration in [-1.0, 0, 2, 10, 11, 15, 16] {
                let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
                let date = ISO8601DateFormatter().date(from: stamp)
                let mac = VPSMemoryPressure(sampledAt: stamp, durationSeconds: duration, swapInBytesPerSecond: nil, swapOutBytesPerSecond: nil, memorySomeAvg10: nil, memoryFullAvg10: nil)
                let phone = CompanionServerPressure(sampledAt: date, durationSeconds: duration)
                XCTAssertEqual(phone.isFresh(now: now), mac.isFresh(relativeTo: now), "pressure age \(age) duration \(duration)")

                let macStorage = VPSStorageDiagnostics(
                    sampledAt: stamp,
                    durationSeconds: duration,
                    status: "complete",
                    daemon: VPSStorageDaemon(status: "complete", usesContainerd: false),
                    categories: VPSStorageCategories(status: "complete", items: []),
                    blobs: VPSBlobStorage(status: "complete", allocatedBytes: nil, changeBytes: nil, baselineStatus: nil)
                )
                let phoneStorage = CompanionServerStorageDiagnostics(sampledAt: date, durationSeconds: duration)
                XCTAssertEqual(phoneStorage.isFresh(now: now), macStorage.isFresh(relativeTo: now), "storage age \(age) duration \(duration)")
            }
        }
    }

    func testIncompleteDockerTotalsSendNoRows() throws {
        var snapshot = fullReading()
        snapshot = VPSStatusSnapshot(
            generatedAt: snapshot.generatedAt,
            host: snapshot.host,
            devices: snapshot.devices,
            storageDiagnostics: VPSStorageDiagnostics(
                sampledAt: snapshot.generatedAt,
                durationSeconds: 2,
                status: "partial",
                daemon: VPSStorageDaemon(status: "complete", usesContainerd: true),
                categories: VPSStorageCategories(status: "unavailable", items: [
                    VPSStorageCategory(id: "images", totalCount: 0, activeCount: 0, sizeBytes: 0, engineReclaimableBytes: 0),
                ]),
                blobs: VPSBlobStorage(status: "incomplete", allocatedBytes: nil, changeBytes: nil, baselineStatus: nil)
            )
        )
        let diagnostics = try XCTUnwrap(build(reading: snapshot).storageDiagnostics)
        XCTAssertEqual(diagnostics.categoriesComplete, false)
        XCTAssertNil(diagnostics.categories, "unknown totals are absent, not zero")
        XCTAssertEqual(diagnostics.blobText, "Reading incomplete")
    }
}

// MARK: - Who reads it

enum CompanionTestSnapshots {
    static func plain() -> CompanionSnapshot {
        CompanionSnapshot(
            version: CompanionService.version,
            hostName: "Test Mac",
            sampledAt: Date(),
            hasBaseline: true,
            window: "Now",
            grouping: "Apps",
            cpuScale: "Per Core",
            pulse: CompanionPulse(cpuPercent: 1, cpuText: "1%", cpuCaption: "of all 10 cores", cpuSeverity: "calm", memoryPercent: 1, memoryText: "1 of 16 GB", memoryCaption: "Memory in use", swapText: nil, pressureText: nil, pressureSeverity: "calm"),
            rows: []
        )
    }
}

final class CompanionServerRouteTests: XCTestCase {
    private let code = "ABCD2345"
    private let lan = CompanionPeer(key: "192.168.1.20", isTrusted: true)
    private let tailscale = CompanionPeer(key: "100.100.1.2", isTrusted: true)
    private let wan = CompanionPeer(key: "203.0.113.9", isTrusted: false)

    private func served(_ server: CompanionServer, token: String, from peer: CompanionPeer) throws -> (snapshot: CompanionSnapshot, json: String) {
        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: token), peer: peer) }
        guard case .reply(let data) = disposition, let parsed = CompanionHTTP.parseResponse(data), parsed.status == 200 else {
            XCTFail("the snapshot was not served")
            throw CompanionClientErrorForTest.notServed
        }
        return (try CompanionJSON.decode(parsed.body), String(data: parsed.body, encoding: .utf8) ?? "")
    }

    private enum CompanionClientErrorForTest: Error { case notServed }

    private func serverWithDetail() -> (server: CompanionServer, token: String) {
        var plain = CompanionTestSnapshots.plain()
        plain.remoteServerStatusAllowed = true
        plain.flaggedIssues = []
        plain.flaggedIssuesCoverServer = false
        var detailed = plain
        detailed.server = build(reading: fullReading(), error: canaryError)
        detailed.flaggedIssues = [CompanionFlaggedIssue(id: "server.tool.docker.stopped", title: "Critical Service Stopped: Docker", message: "Stopped on \(canaryHost)", priority: 1, priorityText: "High", host: "Server")]
        detailed.flaggedIssuesCoverServer = true
        let server = CompanionServer()
        server.updateToken(code)
        let token = server.devices.issue(name: "Test iPhone").token
        server.update(snapshot: plain, detailed: detailed)
        server.syncOnQueue {}
        return (server, token)
    }

    func testAPhonesOwnTokenOnTheLocalNetworkReadsTheBlock() throws {
        let (server, token) = serverWithDetail()
        let reply = try served(server, token: token, from: lan)
        XCTAssertEqual(reply.snapshot.server?.host, canaryHost)
        XCTAssertEqual(reply.snapshot.flaggedIssues?.count, 1)
        XCTAssertEqual(reply.snapshot.flaggedIssuesCoverServer, true)
    }

    func testAPhonesOwnTokenOverTailscaleReadsTheBlock() throws {
        let (server, token) = serverWithDetail()
        XCTAssertNotNil(try served(server, token: token, from: tailscale).snapshot.server)
    }

    func testAPhonesOwnTokenFromOutsideDoesNot() throws {
        let (server, token) = serverWithDetail()
        try assertNoInternals(try served(server, token: token, from: wan))
    }

    func testTheSharedCodeOnTheLocalNetworkDoesNot() throws {
        let (server, _) = serverWithDetail()
        try assertNoInternals(try served(server, token: code, from: lan))
    }

    func testTheSharedCodeOverTailscaleDoesNot() throws {
        let (server, _) = serverWithDetail()
        try assertNoInternals(try served(server, token: code, from: tailscale))
    }

    func testTheSharedCodeFromOutsideDoesNot() throws {
        let (server, _) = serverWithDetail()
        try assertNoInternals(try served(server, token: code, from: wan))
    }

    func testAWrongCredentialReadsNothing() {
        let (server, _) = serverWithDetail()
        let disposition = server.syncOnQueue { server.disposition(for: CompanionHTTP.request(token: "hh1_wrong"), peer: lan) }
        guard case .reply(let data) = disposition else { return XCTFail("expected a reply") }
        XCTAssertEqual(CompanionHTTP.parseResponse(data)?.status, 401)
    }

    private func assertNoInternals(_ reply: (snapshot: CompanionSnapshot, json: String), file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(reply.snapshot.server, file: file, line: line)
        XCTAssertEqual(reply.snapshot.flaggedIssuesCoverServer, false, file: file, line: line)
        XCTAssertEqual(reply.snapshot.flaggedIssues ?? [], [], file: file, line: line)
        XCTAssertEqual(reply.snapshot.remoteServerStatusAllowed, true, "the phone can say why the block is missing", file: file, line: line)
        for canary in canaries {
            XCTAssertFalse(reply.json.contains(canary), "\(canary) reached a plain snapshot", file: file, line: line)
        }
    }
}

// MARK: - The opt-in, from the store

@MainActor
final class CompanionServerOptInTests: XCTestCase {
    private func makeStore(reading: VPSStatusSnapshot?, error: Error? = nil, defaults: UserDefaults? = nil) throws -> HogStore {
        let suite = "hoghunter-server-optin-\(UUID().uuidString)"
        let defaults = defaults ?? UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hoghunter-server-optin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let maintain = MaintainStore(
            supportDirectory: directory,
            repoRoot: directory,
            launcher: { _ in
                XCTFail("a test must not launch the script")
                return true
            },
            infisical: IsolatedInfisical.make(),
            vpsFetcher: { _ in
                if let error { throw error }
                guard let reading else { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: canaryError]) }
                return reading
            }
        )
        addTeardownBlock { await MainActor.run { maintain.vpsStore.stopPolling() } }
        return HogStore(historyURL: isolatedHistoryURL(), defaults: defaults, infisical: IsolatedInfisical.make(), maintain: maintain, startImmediately: false)
    }

    /// Sets the host and waits for the stub fetcher's answer.
    private func read(_ store: HogStore) async throws {
        let vps = store.maintain.vpsStore
        vps.setHost("fake-host")
        for _ in 0..<200 {
            if vps.snapshot != nil || vps.lastReadError != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the stub fetcher never answered")
    }

    private func json(_ snapshot: CompanionSnapshot) throws -> String {
        String(data: try CompanionJSON.encode(snapshot), encoding: .utf8) ?? ""
    }

    func testItIsOffByDefaultAndTheBlockStaysHome() async throws {
        let store = try makeStore(reading: fullReading(withSizes: false))
        try await read(store)
        XCTAssertFalse(store.allowRemoteServerStatus)
        let (plain, detailed) = store.companionSnapshots()
        XCTAssertNil(detailed, "with every opt-in off there is no detailed snapshot at all")
        XCTAssertNil(plain.server)
        XCTAssertEqual(plain.remoteServerStatusAllowed, false)
        XCTAssertEqual(plain.flaggedIssuesCoverServer, false)
    }

    func testTurningItOnFillsOnlyTheDetailedSnapshot() async throws {
        let store = try makeStore(reading: fullReading(withSizes: false))
        try await read(store)
        store.allowRemoteServerStatus = true
        let (plain, detailed) = store.companionSnapshots()
        XCTAssertNil(plain.server)
        XCTAssertEqual(plain.remoteServerStatusAllowed, true)
        let text = try json(plain)
        for canary in canaries {
            XCTAssertFalse(text.contains(canary), "\(canary) reached the plain snapshot")
        }
        let detail = try XCTUnwrap(detailed)
        XCTAssertEqual(detail.server?.host, canaryHost)
        XCTAssertEqual(detail.flaggedIssuesCoverServer, true)
        XCTAssertTrue(detail.flaggedIssues?.contains { $0.isServer } == true, "the reading is bad enough to flag")
        XCTAssertFalse(plain.flaggedIssues?.contains { $0.isServer } == true)
    }

    func testIssueActionsReachOnlyTheDetailedSnapshot() async throws {
        let store = try makeStore(reading: nil)
        try await read(store)
        store.allowRemoteServerStatus = true
        store.allowRemoteQuit = true
        store.allowRemoteClean = true
        let (plain, detailed) = store.companionSnapshots()
        XCTAssertTrue(plain.flaggedIssues?.allSatisfy { $0.action == nil } ?? true, "the shared code reads the plain snapshot and cannot act")
        XCTAssertFalse(try json(plain).contains("\"action\""))
        let detail = try XCTUnwrap(detailed)
        XCTAssertEqual(detail.flaggedIssues?.first { $0.id == "server.unreachable" }?.actionKind, .retry)
    }

    func testTheRouterKnowsWhetherAServerIsSetUp() async throws {
        let store = try makeStore(reading: nil)
        XCTAssertFalse(store.serverConfiguredOnRouter)
        try await read(store)
        XCTAssertTrue(store.serverConfiguredOnRouter)
        store.maintain.vpsStore.setHost("")
        XCTAssertFalse(store.serverConfiguredOnRouter)
    }

    func testAFailedReadsErrorTextStaysOutOfThePlainSnapshot() async throws {
        let store = try makeStore(reading: nil)
        try await read(store)
        store.allowRemoteServerStatus = true
        let (plain, detailed) = store.companionSnapshots()
        let detail = try XCTUnwrap(detailed)
        XCTAssertEqual(detail.server?.resolvedState(), .error)
        XCTAssertEqual(detail.server?.errorText, canaryError)
        XCTAssertEqual(detail.flaggedIssues?.first { $0.id == "server.unreachable" }?.message, canaryError)
        let text = try json(plain)
        XCTAssertFalse(text.contains("Connection refused"))
        XCTAssertFalse(text.contains(canaryHost))
    }

    func testTheMaintainOptInAloneCarriesNoServerDetail() async throws {
        let store = try makeStore(reading: fullReading(withSizes: false))
        try await read(store)
        store.allowRemoteMaintain = true
        let detail = try XCTUnwrap(store.companionSnapshots().detailed)
        XCTAssertNil(detail.server)
        XCTAssertEqual(detail.flaggedIssuesCoverServer, false)
        XCTAssertFalse(detail.flaggedIssues?.contains { $0.isServer } == true)
        let text = try json(detail)
        XCTAssertFalse(text.contains(canaryHost))
        XCTAssertFalse(text.contains(canaryProcess))
    }

    func testTheServerOptInAloneCarriesNoMaintainSteps() async throws {
        let store = try makeStore(reading: nil)
        store.allowRemoteServerStatus = true
        let detail = try XCTUnwrap(store.companionSnapshots().detailed)
        XCTAssertNil(detail.maintain?.steps)
    }

    func testNoServerSetUpReadsAsNotConfigured() throws {
        let store = try makeStore(reading: nil)
        store.allowRemoteServerStatus = true
        let detail = try XCTUnwrap(store.companionSnapshots().detailed)
        XCTAssertEqual(detail.server?.resolvedState(), .notConfigured)
    }

    func testTheOptInSurvivesARestart() throws {
        let suite = "hoghunter-server-optin-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let first = try makeStore(reading: nil, defaults: defaults)
        first.allowRemoteServerStatus = true
        let second = try makeStore(reading: nil, defaults: defaults)
        XCTAssertTrue(second.allowRemoteServerStatus)
    }

    func testTheStoreKeepsAFailureThroughARetry() async throws {
        let store = try makeStore(reading: nil)
        try await read(store)
        let vps = store.maintain.vpsStore
        XCTAssertEqual(vps.lastReadError, canaryError)
        vps.fetch(force: true)
        XCTAssertNil(vps.errorMessage, "the retry clears the Mac's own message")
        XCTAssertEqual(vps.lastReadError, canaryError, "the phone still reads the failure")
    }
}

// MARK: - What the phone decides

final class CompanionServerPresentationTests: XCTestCase {
    private func snapshot(allowed: Bool?, server: CompanionServerStatus? = nil, issues: [CompanionFlaggedIssue]? = nil, cover: Bool? = nil) -> CompanionSnapshot {
        var snapshot = CompanionTestSnapshots.plain()
        snapshot.remoteServerStatusAllowed = allowed
        snapshot.server = server
        snapshot.flaggedIssues = issues
        snapshot.flaggedIssuesCoverServer = cover
        return snapshot
    }

    private let macIssue = CompanionFlaggedIssue(id: "mac.disk.low", title: "Low", message: "m", priority: 1, priorityText: "High", host: "Mac")
    private let serverIssue = CompanionFlaggedIssue(id: "server.cpu.high", title: "High", message: canaryHost, priority: 1, priorityText: "High", host: "Server")

    func testServerAccessTellsThePhoneWhatToSay() {
        let status = CompanionServerStatus(state: "noReading")
        XCTAssertEqual(snapshot(allowed: nil).serverAccess, .macTooOld)
        XCTAssertEqual(snapshot(allowed: false).serverAccess, .optInOff)
        XCTAssertEqual(snapshot(allowed: true).serverAccess, .notOnThisLink)
        XCTAssertEqual(snapshot(allowed: true, server: status).serverAccess, .available(status))
    }

    func testAnOlderMacsSilenceIsNotCalm() {
        XCTAssertEqual(snapshot(allowed: nil).flaggedSummary(), .unavailable)
    }

    func testAllSystemsCalmNeedsTheServerLookedAtAndCurrent() {
        let now = Date()
        let current = CompanionServerStatus(state: "ok", generatedAt: now)
        let old = CompanionServerStatus(state: "ok", generatedAt: now.addingTimeInterval(-3_600))
        let none = CompanionServerStatus(state: "notConfigured")
        let waiting = CompanionServerStatus(state: "noReading")
        let failed = CompanionServerStatus(state: "error", errorText: "x")
        XCTAssertEqual(snapshot(allowed: true, server: current, issues: [], cover: true).flaggedSummary(now: now), .allCalm)
        XCTAssertEqual(snapshot(allowed: true, server: none, issues: [], cover: true).flaggedSummary(now: now), .allCalm)
        XCTAssertEqual(snapshot(allowed: true, server: old, issues: [], cover: true).flaggedSummary(now: now), .macCalmServerUnknown)
        XCTAssertEqual(snapshot(allowed: true, server: waiting, issues: [], cover: true).flaggedSummary(now: now), .macCalmServerUnknown)
        XCTAssertEqual(snapshot(allowed: true, server: failed, issues: [], cover: true).flaggedSummary(now: now), .macCalmServerUnknown)
        XCTAssertEqual(snapshot(allowed: false, issues: [], cover: false).flaggedSummary(now: now), .macCalmServerNotShown)
        XCTAssertEqual(snapshot(allowed: true, issues: [], cover: false).flaggedSummary(now: now), .macCalmServerNotShown, "the shared code's snapshot withholds the server")
    }

    func testIssuesSayWhetherTheServerWasCounted() {
        XCTAssertEqual(snapshot(allowed: false, issues: [macIssue], cover: false).flaggedSummary(), .issues(count: 1, serverIncluded: false))
        let status = CompanionServerStatus(state: "ok", generatedAt: Date())
        XCTAssertEqual(snapshot(allowed: true, server: status, issues: [macIssue, serverIssue], cover: true).flaggedSummary(), .issues(count: 2, serverIncluded: true))
    }

    func testTheWidgetCopyHoldsNoServerInternals() throws {
        var full = snapshot(allowed: true, server: build(reading: fullReading(), error: canaryError), issues: [macIssue, serverIssue], cover: true)
        full = full.withoutServerDetail()
        XCTAssertNil(full.server)
        XCTAssertEqual(full.flaggedIssues, [macIssue])
        XCTAssertEqual(full.flaggedIssuesCoverServer, false)
        let text = String(data: try CompanionJSON.encode(full), encoding: .utf8) ?? ""
        for canary in canaries {
            XCTAssertFalse(text.contains(canary), "\(canary) reached the widget's copy")
        }
    }

    func testAnOlderMacsSnapshotStillDecodes() throws {
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionJSON.encode(CompanionTestSnapshots.plain())) as? [String: Any])
        for key in ["remoteServerStatusAllowed", "server", "flaggedIssues", "flaggedIssuesCoverServer"] {
            dictionary.removeValue(forKey: key)
        }
        let decoded = try CompanionJSON.decode(JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertNil(decoded.server)
        XCTAssertEqual(decoded.serverAccess, .macTooOld)
        XCTAssertEqual(decoded.flaggedSummary(), .unavailable)
    }

    func testAnOlderPhoneIgnoresTheNewFields() throws {
        // What an older phone's decoder does: it knows none of the new keys.
        struct OlderPhoneSnapshot: Decodable {
            var hostName: String
            var maintain: CompanionMaintainStatus?
        }
        var full = CompanionTestSnapshots.plain()
        full.remoteServerStatusAllowed = true
        full.server = build(reading: fullReading())
        full.flaggedIssues = [serverIssue]
        full.flaggedIssuesCoverServer = true
        let decoded = try CompanionJSON.decoder().decode(OlderPhoneSnapshot.self, from: CompanionJSON.encode(full))
        XCTAssertEqual(decoded.hostName, "Test Mac")
    }

    func testASparseBlockFromALaterMacDecodes() throws {
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionJSON.encode(CompanionTestSnapshots.plain())) as? [String: Any])
        dictionary["server"] = ["state": "somethingNew", "futureField": 1, "tools": [["id": "a", "name": "A", "state": "strange", "stateText": "Strange"]]]
        let decoded = try CompanionJSON.decode(JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertEqual(decoded.server?.tools?.first?.state, "strange")
        XCTAssertEqual(decoded.server?.resolvedState(), .noReading)
    }

    func testARoundTripKeepsTheBlock() throws {
        var full = CompanionTestSnapshots.plain()
        var status = build(reading: fullReading())
        status.generatedAt = status.generatedAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        status.pressure = nil
        status.fetchedAt = nil
        full.server = status
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(full))
        XCTAssertEqual(decoded.server, status)
    }
}

final class CompanionServerStatusReviewTests: XCTestCase {
    private func reading(_ devices: [String: VPSDevice]) -> VPSStatusSnapshot {
        VPSStatusSnapshot(generatedAt: iso(Date()), host: "h", devices: devices)
    }

    private func build(_ snapshot: VPSStatusSnapshot) -> CompanionServerStatus {
        CompanionServerStatusBuilder.make(
            configuredHost: "h", snapshot: snapshot, error: nil, fetchedAt: Date(),
            cpuHistory: [], databaseChange: { _ in nil }, directoryChange: { _ in nil }
        )
    }

    func testADeviceTitleNamesTheMountTheServerReported() {
        let status = build(reading([
            "extra": VPSDevice(mount: "/mnt/data", freeBytes: 1, note: nil),
            "tmp": VPSDevice(mount: "/run/scratch", freeBytes: 1, note: nil),
            "root": VPSDevice(mount: "/", freeBytes: 1, note: nil),
            "shm": VPSDevice(mount: "", freeBytes: 1, note: nil),
        ]))
        let titles = Dictionary(uniqueKeysWithValues: (status.devices ?? []).map { ($0.id, $0.title) })
        XCTAssertEqual(titles["extra"], "Fleet Extra (/mnt/data)")
        XCTAssertEqual(titles["tmp"], "Tmpfs (/run/scratch)")
        XCTAssertEqual(titles["root"], "Disk (/)")
        XCTAssertEqual(titles["shm"], "Shared Mem")
    }

    func testTheHeadlineAndTheDeviceListNameTheSameExtraDisk() {
        let snapshot = reading([
            "z-disk": VPSDevice(mount: "/mnt/fleet-extra/b", freeBytes: 1, note: nil),
            "a-disk": VPSDevice(mount: "/mnt/fleet-extra/a", freeBytes: 1, note: nil),
        ])
        XCTAssertEqual(snapshot.fleetExtraKey, "a-disk")
        XCTAssertEqual(snapshot.fleetExtraDevice?.mount, "/mnt/fleet-extra/a")
        let extra = build(snapshot).devices?.first { $0.title.hasPrefix("Fleet Extra") }
        XCTAssertEqual(extra?.id, "a-disk")
    }

    func testADeviceNamedOnceIsListedOnce() {
        let status = build(reading(["tmp": VPSDevice(mount: "/mnt/fleet-extra", freeBytes: 1, note: nil)]))
        XCTAssertEqual(status.devices?.map(\.id), ["tmp"])
        XCTAssertEqual(status.devices?.first?.title, "Fleet Extra (/mnt/fleet-extra)")
    }

    func testTheMemoRebuildsOnlyWhenItsKeyChanges() {
        var memo = CompanionServerStatusMemo()
        var builds = 0
        let at = Date()
        func key(_ state: CompanionServerState = .ok, fetchedAt: Date? = nil, error: String? = nil) -> CompanionServerStatusMemo.Key {
            CompanionServerStatusMemo.Key(host: "h", snapshot: nil, error: error, fetchedAt: fetchedAt ?? at, readingState: state)
        }
        func read(_ key: CompanionServerStatusMemo.Key) -> String {
            memo.status(for: key) {
                builds += 1
                return CompanionServerStatus(state: key.readingState.rawValue)
            }.state
        }
        _ = read(key())
        _ = read(key())
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(read(key(.stale)), CompanionServerState.stale.rawValue)
        XCTAssertEqual(builds, 2)
        _ = read(key(.stale, fetchedAt: at.addingTimeInterval(60)))
        XCTAssertEqual(builds, 3)
        _ = read(key(.stale, fetchedAt: at.addingTimeInterval(60), error: "e"))
        XCTAssertEqual(builds, 4)
    }
}
