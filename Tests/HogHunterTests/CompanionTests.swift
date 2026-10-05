import XCTest

@testable import HogHunter

final class CompanionTests: XCTestCase {
    func testAuthorizedResponseReturnsTheSnapshotBody() {
        let body = Data("{\"secret\":true}".utf8)
        let response = CompanionHTTP.response(
            request: CompanionHTTP.request(token: "ABCD2345"),
            body: body,
            token: "ABCD2345"
        )
        let parsed = CompanionHTTP.parseResponse(response)
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(parsed?.body, body)
    }

    func testParseResponseWaitsUntilContentLengthArrives() {
        let body = Data(repeating: 0x61, count: 4000)
        let response = CompanionHTTP.response(
            request: CompanionHTTP.request(token: "ABCD2345"),
            body: body,
            token: "ABCD2345"
        )
        let marker = Data("\r\n\r\n".utf8)
        let range = response.range(of: marker)
        XCTAssertNotNil(range)
        let split = range!.upperBound + 1
        XCTAssertNil(CompanionHTTP.parseResponse(response.prefix(split)))
        let parsed = CompanionHTTP.parseResponse(response)
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(parsed?.body, body)
    }

    func testWrongCodeDoesNotReturnTheSnapshot() {
        let body = Data("top-secret-snapshot".utf8)
        let response = CompanionHTTP.response(
            request: CompanionHTTP.request(token: "WRONG234"),
            body: body,
            token: "ABCD2345"
        )
        let parsed = CompanionHTTP.parseResponse(response)
        XCTAssertEqual(parsed?.status, 401)
        XCTAssertFalse(String(data: parsed?.body ?? Data(), encoding: .utf8)?.contains("top-secret") ?? true)
    }

    func testUnknownPathIsNotFound() {
        let request = Data("GET /quit HTTP/1.1\r\nHost: hoghunter\r\n\r\n".utf8)
        let response = CompanionHTTP.response(request: request, body: Data("nope".utf8), token: "ABCD2345")
        XCTAssertEqual(CompanionHTTP.parseResponse(response)?.status, 404)
    }

    func testSnapshotRoundTrip() throws {
        let snapshot = sampleSnapshot(scale: .perCore)
        let decoded = try CompanionJSON.decode(try CompanionJSON.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testMachineShareShowsTheDividedCPU() {
        let snapshot = sampleSnapshot(scale: .machineShare)
        XCTAssertEqual(snapshot.rows.first?.cpuText, "100%")
        XCTAssertEqual(snapshot.rows.first?.severity, "hot")
        XCTAssertEqual(snapshot.pulse.pressureText, "Pressure critical")
        XCTAssertEqual(snapshot.pulse.pressureSeverity, "hot")
        XCTAssertEqual(snapshot.window, "Now")
    }

    func testSnapshotIncludesStorageAndNetworkRoundTrip() throws {
        let storage = CompanionStorageSummary(
            freeBytes: 100_000_000_000,
            totalBytes: 500_000_000_000,
            usedBytes: 400_000_000_000,
            freeText: "100 GB Free",
            totalText: "500 GB Total",
            usedText: "400 GB Used",
            usedPercent: 80.0,
            standardCleanableBytes: 5_000_000_000,
            standardCleanableText: "5 GB Cleanable"
        )
        let networkRow = CompanionNetworkRow(
            id: "123",
            name: "Safari",
            pid: 123,
            establishedCount: 12,
            uniqueRemoteHosts: 4,
            sampleRemoteHosts: ["1.1.1.1:443", "8.8.8.8:53"]
        )
        var snapshot = sampleSnapshot(scale: .perCore)
        snapshot.storage = storage
        snapshot.network = [networkRow]

        let encoded = try CompanionJSON.encode(snapshot)
        let decoded = try CompanionJSON.decode(encoded)

        XCTAssertEqual(decoded.storage, storage)
        XCTAssertEqual(decoded.network, [networkRow])
        XCTAssertEqual(decoded.rows.first?.cpuPercent, 400)
        XCTAssertEqual(decoded.rows.first?.memoryBytes, 2_147_483_648)
    }

    func testCompanionServerPreferredPortAndAddressDetection() {
        let addresses = CompanionServer.detectHostAddresses()
        if let local = addresses.localIP {
            XCTAssertFalse(local.isEmpty)
        }
        if let tailscale = addresses.tailscaleIP {
            XCTAssertTrue(tailscale.hasPrefix("100."))
        }
    }

    func testServiceNameDropsTheDomain() {
        XCTAssertEqual(CompanionServer.serviceName(from: "Studio.local"), "Studio")
        XCTAssertEqual(CompanionServer.serviceName(from: "   "), "Hog Hunter")
    }

    func testCompanionTameRequestAndResponse() {
        var tamedPid: pid_t?
        var tameAction: String?
        let handler: (pid_t, String) -> (status: Int, body: Data) = { pid, action in
            tamedPid = pid
            tameAction = action
            let resp = CompanionTameResponse(status: "tamed", pid: pid, name: "test", isTamed: true, message: "OK", error: nil)
            return (200, (try? JSONEncoder().encode(resp)) ?? Data())
        }

        let request = CompanionHTTP.tameRequest(token: "ABCD2345", pid: 9999, action: "tame")
        let response = CompanionHTTP.response(
            request: request,
            body: Data(),
            token: "ABCD2345",
            tameHandler: handler
        )
        let parsed = CompanionHTTP.parseResponse(response)
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(tamedPid, 9999)
        XCTAssertEqual(tameAction, "tame")

        let decoded = try? JSONDecoder().decode(CompanionTameResponse.self, from: parsed?.body ?? Data())
        XCTAssertEqual(decoded?.status, "tamed")
        XCTAssertEqual(decoded?.pid, 9999)
        XCTAssertEqual(decoded?.isTamed, true)
    }

    func testCompanionSnapshotCarriesBatteryAndThermalAndTaming() throws {
        var pulse = MachinePulse.empty
        pulse.batteryPercent = 88
        pulse.isCharging = true
        pulse.powerSource = "AC"
        pulse.thermalState = .serious

        let row = HogRow(
            id: "a-test",
            keys: [],
            name: "HogApp",
            detail: "test",
            cpuPercent: 250,
            memoryBytes: 500_000_000,
            peakMemoryBytes: nil,
            presence: nil,
            icon: nil,
            path: nil,
            isApp: true,
            isGroup: false,
            canQuit: true,
            quitBlockReason: nil,
            isTamed: true,
            isSleepBlocker: true,
            canTame: true
        )

        let snapshot = CompanionSnapshotBuilder.make(
            hostName: "MacBook",
            sampledAt: Date(),
            hasBaseline: true,
            window: .now,
            grouping: .processes,
            scale: .perCore,
            pulse: pulse,
            rows: [row]
        )

        XCTAssertEqual(snapshot.pulse.batteryText, "88% (AC)")
        XCTAssertEqual(snapshot.pulse.isCharging, true)
        XCTAssertEqual(snapshot.pulse.thermalState, "serious")
        XCTAssertEqual(snapshot.rows.first?.isTamed, true)
        XCTAssertEqual(snapshot.rows.first?.isSleepBlocker, true)
        XCTAssertEqual(snapshot.rows.first?.canTame, true)

        let roundTrip = try CompanionJSON.decode(try CompanionJSON.encode(snapshot))
        XCTAssertEqual(roundTrip.pulse.batteryText, "88% (AC)")
        XCTAssertEqual(roundTrip.pulse.thermalState, "serious")
        XCTAssertEqual(roundTrip.rows.first?.isTamed, true)
        XCTAssertEqual(roundTrip.rows.first?.isSleepBlocker, true)
    }

    func testCompanionExclusionsRequestAndResponse() {
        var receivedReq: CompanionExclusionsUpdateRequest?
        let handler: (CompanionExclusionsUpdateRequest) -> (status: Int, body: Data) = { req in
            receivedReq = req
            let resp = CompanionExclusionsUpdateResponse(
                status: "ok",
                excludedCategories: ["userCaches"],
                excludedPaths: ["/Users/jay/Excluded"],
                message: "OK"
            )
            return (200, (try? JSONEncoder().encode(resp)) ?? Data())
        }

        let request = CompanionHTTP.exclusionsRequest(
            token: "ABCD2345",
            toggleCategory: "userCaches",
            addPath: "/Users/jay/Excluded"
        )
        let response = CompanionHTTP.response(
            request: request,
            body: Data(),
            token: "ABCD2345",
            exclusionsHandler: handler
        )
        let parsed = CompanionHTTP.parseResponse(response)
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(receivedReq?.toggleCategory, "userCaches")
        XCTAssertEqual(receivedReq?.addPath, "/Users/jay/Excluded")

        let decoded = try? JSONDecoder().decode(CompanionExclusionsUpdateResponse.self, from: parsed?.body ?? Data())
        XCTAssertEqual(decoded?.status, "ok")
        XCTAssertEqual(decoded?.excludedCategories, ["userCaches"])
        XCTAssertEqual(decoded?.excludedPaths, ["/Users/jay/Excluded"])
    }

    func testCompanionViewRequestAndResponse() {
        var receivedReq: CompanionViewUpdateRequest?
        let handler: (CompanionViewUpdateRequest) -> (status: Int, body: Data) = { req in
            receivedReq = req
            let resp = CompanionViewUpdateResponse(
                status: "ok",
                window: req.window ?? "Now",
                grouping: req.grouping ?? "Apps",
                cpuScale: req.cpuScale ?? "Per Core",
                message: "OK"
            )
            return (200, (try? JSONEncoder().encode(resp)) ?? Data())
        }

        let request = CompanionHTTP.viewRequest(
            token: "ABCD2345",
            window: "Past Hour",
            grouping: "Processes",
            cpuScale: "Machine Share"
        )
        let response = CompanionHTTP.response(
            request: request,
            body: Data(),
            token: "ABCD2345",
            viewHandler: handler
        )
        let parsed = CompanionHTTP.parseResponse(response)
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(receivedReq?.window, "Past Hour")
        XCTAssertEqual(receivedReq?.grouping, "Processes")
        XCTAssertEqual(receivedReq?.cpuScale, "Machine Share")

        let decoded = try? JSONDecoder().decode(CompanionViewUpdateResponse.self, from: parsed?.body ?? Data())
        XCTAssertEqual(decoded?.status, "ok")
        XCTAssertEqual(decoded?.window, "Past Hour")
        XCTAssertEqual(decoded?.grouping, "Processes")
        XCTAssertEqual(decoded?.cpuScale, "Machine Share")
    }

    func testCompanionStorageSummaryBreakdownAndExclusions() throws {
        let category = CompanionStorageCategorySummary(
            id: "userCaches",
            title: "User Caches",
            description: "Caches that can be rebuilt",
            icon: "arrow.triangle.2.circlepath",
            isExcluded: false,
            isExtremeOnly: false
        )
        let summary = CompanionStorageSummary(
            freeBytes: 100_000_000_000,
            totalBytes: 500_000_000_000,
            usedBytes: 400_000_000_000,
            freeText: "100 GB Free",
            totalText: "500 GB Total",
            usedText: "400 GB Used",
            usedPercent: 80.0,
            standardCleanableBytes: 4_000_000_000,
            standardCleanableText: "4 GB Cleanable",
            excludedCategories: ["trash"],
            excludedPathsCount: 1,
            categoryBreakdown: [category],
            excludedPaths: ["/Users/jay/Keep"]
        )

        let encoded = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(CompanionStorageSummary.self, from: encoded)

        XCTAssertEqual(decoded.categoryBreakdown?.count, 1)
        XCTAssertEqual(decoded.categoryBreakdown?.first?.title, "User Caches")
        XCTAssertEqual(decoded.excludedPaths, ["/Users/jay/Keep"])

        let currentSummary = CompanionSnapshotBuilder.currentStorageSummary()
        XCTAssertNotNil(currentSummary?.categoryBreakdown)
        XCTAssertEqual(currentSummary?.categoryBreakdown?.count, CleanCategory.allCases.count)
    }

    private func sampleSnapshot(scale: CpuScale) -> CompanionSnapshot {
        let pulse = MachinePulse(
            cpuPercent: 40,
            coreCount: 4,
            visibleCpuPercent: 40,
            readableProcessCount: 2,
            unreadableProcessCount: 0,
            memoryUsedBytes: 8_589_934_592,
            appMemoryBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedFilesBytes: 0,
            totalMemoryBytes: 17_179_869_184,
            swapUsedBytes: 0,
            swapTotalBytes: 0,
            swapInBytesPerSec: 0,
            swapOutBytesPerSec: 0,
            pressure: .critical,
            thermalState: .nominal,
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let row = HogRow(
            id: "a-chrome",
            keys: [],
            name: "Chrome",
            detail: "3 processes",
            cpuPercent: 400,
            memoryBytes: 2_147_483_648,
            peakMemoryBytes: nil,
            presence: nil,
            icon: nil,
            path: nil,
            isApp: true,
            isGroup: true,
            canQuit: true,
            quitBlockReason: nil
        )
        return CompanionSnapshotBuilder.make(
            hostName: "Studio",
            sampledAt: pulse.sampledAt,
            hasBaseline: true,
            window: .now,
            grouping: .apps,
            scale: scale,
            pulse: pulse,
            rows: [row]
        )
    }
}

/// The iPhone shows a "Mac Disk Usage" section only when the snapshot carries
/// a `storage` summary; with none, it renders "Disk telemetry will update with
/// next sample" and there is no way for the user to tell that from a Mac that
/// simply has no disk.  Both the builder's fallback and the iOS view landed in
/// the same PR, so a stale Mac and a stale phone look identical.  This pins
/// the Mac half so a regression here shows up as a test failure rather than as
/// a blank panel on someone's phone.
final class CompanionStorageTelemetryTests: XCTestCase {

    func testStorageSummaryIsBuiltFromTheLiveVolume() throws {
        let summary = try XCTUnwrap(CompanionSnapshotBuilder.currentStorageSummary(),
                                    "the startup volume must always be readable")
        XCTAssertGreaterThan(summary.totalBytes, 0)
        XCTAssertLessThanOrEqual(summary.freeBytes, summary.totalBytes)
        XCTAssertEqual(summary.usedBytes, summary.totalBytes - summary.freeBytes)
        // Percent has to agree with the byte counts it was derived from, or the
        // iPhone shows a bar that contradicts its own caption.
        let expected = Double(summary.usedBytes) / Double(summary.totalBytes) * 100
        XCTAssertEqual(summary.usedPercent, expected, accuracy: 0.001)
        XCTAssertFalse(summary.freeText.isEmpty)
        XCTAssertFalse(summary.usedText.isEmpty)
    }

    /// A snapshot built without an explicit summary must still carry one, so a
    /// plain tick is never the reason the phone shows nothing.
    func testBuilderFallsBackToLiveStorageWhenNoneIsPassed() {
        var pulse = MachinePulse.empty
        pulse.cpuPercent = 10
        pulse.coreCount = 10
        pulse.memoryUsedBytes = 8_000_000_000
        let snapshot = CompanionSnapshotBuilder.make(
            hostName: "test", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .perCore, pulse: pulse, rows: []
        )
        XCTAssertNotNil(snapshot.storage, "the phone renders nothing without this")
    }

    // MARK: - Approve-on-Mac pairing

    func testPairRequestRoundTripsTheDeviceName() {
        let request = CompanionHTTP.pairRequest(deviceName: "Jay’s iPhone & Co")
        XCTAssertEqual(CompanionHTTP.pairDeviceName(in: request), "Jay’s iPhone & Co")
    }

    func testPairDeviceNameIsSanitizedAndCapped() {
        let hostile = String(repeating: "A", count: 200) + "\u{0007}"
        let request = CompanionHTTP.pairRequest(deviceName: hostile)
        let name = CompanionHTTP.pairDeviceName(in: request)
        XCTAssertEqual(name?.count, CompanionHTTP.maxDeviceNameLength)
        XCTAssertFalse(name?.contains("\u{0007}") ?? true)
    }

    func testOnlyPostToPairPathIsAPairRequest() {
        XCTAssertNil(CompanionHTTP.pairDeviceName(in: CompanionHTTP.request(token: "ABCD2345")))
        let get = Data("GET /v1/pair?device=x HTTP/1.1\r\n\r\n".utf8)
        XCTAssertNil(CompanionHTTP.pairDeviceName(in: get))
        let blank = Data("POST /v1/pair HTTP/1.1\r\n\r\n".utf8)
        XCTAssertEqual(CompanionHTTP.pairDeviceName(in: blank), "An iPhone")
    }

    func testPairResponseCarriesTheTokenOnlyWhenApproved() throws {
        let yes = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.pairResponse(approvedToken: "ABCD2345")))
        XCTAssertEqual(yes.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: yes.body) as? [String: String])
        XCTAssertEqual(json["token"], "ABCD2345")

        let no = try XCTUnwrap(CompanionHTTP.parseResponse(CompanionHTTP.pairResponse(approvedToken: nil)))
        XCTAssertEqual(no.status, 403)
        XCTAssertFalse(String(decoding: no.body, as: UTF8.self).contains("ABCD2345"))
        XCTAssertEqual(CompanionHTTP.parseResponse(CompanionHTTP.pairBusyResponse())?.status, 429)
    }

    func testPairPathStillNeedsTokenOnTheNormalRouter() {
        // The server intercepts pairing before the router.  If anything ever
        // reaches the router on /v1/pair, it must not leak the snapshot.
        let response = CompanionHTTP.response(
            request: Data("GET /v1/pair HTTP/1.1\r\n\r\n".utf8),
            body: Data("{\"secret\":true}".utf8),
            token: "ABCD2345"
        )
        XCTAssertNotEqual(CompanionHTTP.parseResponse(response)?.status, 200)
    }

    func testSnapshotCarriesRemotePermissions() throws {
        let snapshot = CompanionSnapshotBuilder.make(
            hostName: "test", sampledAt: Date(), hasBaseline: true,
            window: .now, grouping: .apps, scale: .perCore, pulse: MachinePulse.empty, rows: [],
            remoteQuitAllowed: true, remoteCleanAllowed: false
        )
        let decoded = try CompanionJSON.decode(CompanionJSON.encode(snapshot))
        XCTAssertEqual(decoded.remoteQuitAllowed, true)
        XCTAssertEqual(decoded.remoteCleanAllowed, false)
    }

    /// Regression: the "Pair this iPhone?" alert suppressed the `@Published`
    /// `didSet` publications with `loadingSettings = true` so the snapshot was
    ///  built once -- but both `didSet`s called `persist()` in that same state,
    ///  and `persist()` returns early while loading.  The owner's answer was
    ///  never written to UserDefaults and both flags reverted on next launch.
    ///  Fix: restore `loadingSettings` before a single `persist()`.
    @MainActor
    func testPairAlertPermissionsReachUserDefaults() {
        let suite = "hoghunter.tests.pairpermissions"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HogStore(defaults: defaults)
        store.allowRemoteQuit = true
        store.allowRemoteClean = true

        // Simulate what the alert does: suppress both didSet publications, set
        // the flags, restore the flag, then persist exactly once.
        store.setLoadingSettingsForTest(true)
        store.allowRemoteQuit = true
        store.allowRemoteClean = true
        store.setLoadingSettingsForTest(false)
        store.persistForTest()

        XCTAssertEqual(defaults.bool(forKey: "allowRemoteQuit"), true,
                       "remote-quit permission must survive a restart")
        XCTAssertEqual(defaults.bool(forKey: "allowRemoteClean"), true,
                       "remote-clean permission must survive a restart")

        // And a fresh store must read the owner's answer back, not reset it.
        let next = HogStore(defaults: defaults)
        XCTAssertEqual(next.allowRemoteQuit, true)
        XCTAssertEqual(next.allowRemoteClean, true)
    }
}
