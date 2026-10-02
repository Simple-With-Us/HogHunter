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
