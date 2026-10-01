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
