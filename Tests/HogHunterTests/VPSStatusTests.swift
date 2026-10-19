import XCTest
@testable import HogHunter

final class VPSStatusTests: XCTestCase {
    private let sampleJSON = """
    {
      "generated_at": "2026-10-18T19:15:03Z",
      "host": "fleet-hetzner-nbg1",
      "devices": {
        "root": {
          "mount": "/",
          "free_bytes": 74097487872,
          "note": "301GB disk: OS, Docker images, all container volumes incl ST DB, dev/agent dirs"
        },
        "tmp": {
          "mount": "/tmp",
          "free_bytes": 16201887744,
          "note": "16GB RAM tmpfs shared by host, builds, docker exec"
        },
        "shm": {
          "mount": "/dev/shm",
          "free_bytes": 16424865792,
          "note": "16GB RAM tmpfs, container shm"
        }
      },
      "app_dbs": {
        "st_app_db": 19904122112,
        "ct_db": 4736902136,
        "um_db": 3457937592
      },
      "cpu": {
        "pct": 24.8,
        "load1": 3.07,
        "cores": 16,
        "source": "proc-stat tick delta 1s"
      },
      "memory": {
        "total_bytes": 32853925888,
        "used_bytes": 9095159808,
        "available_bytes": 23758766080
      },
      "swap": {
        "total_bytes": 18253602816,
        "used_bytes": 9132191744,
        "free_bytes": 9121411072
      },
      "largest_dirs": [
        {"path": "/var/lib/docker", "bytes": 77807898624},
        {"path": "/var/lib/docker/volumes", "bytes": 77448314880},
        {"path": "/data", "bytes": 66587992064},
        {"path": "/data/backups", "bytes": 61563092992}
      ]
    }
    """.data(using: .utf8)!

    func testDecodeSnapshot() throws {
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: sampleJSON)
        XCTAssertEqual(snapshot.host, "fleet-hetzner-nbg1")
        XCTAssertEqual(snapshot.generatedAt, "2026-10-18T19:15:03Z")
        XCTAssertNotNil(snapshot.generatedAtDate)

        // CPU
        guard let cpu = snapshot.cpu else {
            XCTFail("Missing cpu in snapshot")
            return
        }
        XCTAssertEqual(cpu.pct, 24.8)
        XCTAssertEqual(cpu.load1, 3.07)
        XCTAssertEqual(cpu.cores, 16)
        XCTAssertEqual(cpu.severity, .calm)

        // Memory
        guard let mem = snapshot.memory else {
            XCTFail("Missing memory in snapshot")
            return
        }
        XCTAssertEqual(mem.totalBytes, 32853925888)
        XCTAssertEqual(mem.usedBytes, 9095159808)
        XCTAssertEqual(mem.availableBytes, 23758766080)
        XCTAssertEqual(Int(mem.usedPercentage), 27)
        XCTAssertEqual(mem.severity, .calm)

        // Swap
        guard let swap = snapshot.swap else {
            XCTFail("Missing swap in snapshot")
            return
        }
        XCTAssertEqual(swap.totalBytes, 18253602816)
        XCTAssertEqual(swap.usedBytes, 9132191744)
        XCTAssertEqual(Int(swap.usedPercentage), 50)
        XCTAssertEqual(swap.severity, .elevated)

        // Devices
        let root = snapshot.rootDevice
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.mount, "/")
        XCTAssertEqual(root?.freeBytes, 74097487872)
        XCTAssertEqual(root?.estimatedTotalBytes, 301 * 1024 * 1024 * 1024)
        XCTAssertNotNil(root?.usedFraction)

        let tmp = snapshot.tmpDevice
        XCTAssertNotNil(tmp)
        XCTAssertEqual(tmp?.mount, "/tmp")
        XCTAssertEqual(tmp?.freeBytes, 16201887744)
        XCTAssertEqual(tmp?.estimatedTotalBytes, 16 * 1024 * 1024 * 1024)
        XCTAssertNotNil(tmp?.usedFraction)

        let shm = snapshot.shmDevice
        XCTAssertNotNil(shm)
        XCTAssertEqual(shm?.mount, "/dev/shm")
        XCTAssertEqual(shm?.freeBytes, 16424865792)
        XCTAssertEqual(shm?.estimatedTotalBytes, 16 * 1024 * 1024 * 1024)
        XCTAssertNotNil(shm?.usedFraction)

        // Databases
        XCTAssertEqual(snapshot.appDbs?["st_app_db"], 19904122112)
        XCTAssertEqual(snapshot.appDbs?["ct_db"], 4736902136)
        XCTAssertEqual(snapshot.appDbs?["um_db"], 3457937592)

        // Largest directories
        XCTAssertEqual(snapshot.largestDirs?.count, 4)
        XCTAssertEqual(snapshot.largestDirs?.first?.path, "/var/lib/docker")
        XCTAssertEqual(snapshot.largestDirs?.first?.bytes, 77807898624)
    }

    func testSeverityCalculations() {
        let calmCpu = VPSCPU(pct: 20.0, load1: 1.0, cores: 8)
        XCTAssertEqual(calmCpu.severity, .calm)

        let elevatedCpu = VPSCPU(pct: 65.0, load1: 5.0, cores: 8)
        XCTAssertEqual(elevatedCpu.severity, .elevated)

        let hotCpu = VPSCPU(pct: 92.0, load1: 10.0, cores: 8)
        XCTAssertEqual(hotCpu.severity, .hot)

        let calmMem = VPSMemory(totalBytes: 100, usedBytes: 50, availableBytes: 50)
        XCTAssertEqual(calmMem.severity, .calm)

        let elevatedMem = VPSMemory(totalBytes: 100, usedBytes: 78, availableBytes: 22)
        XCTAssertEqual(elevatedMem.severity, .elevated)

        let hotMem = VPSMemory(totalBytes: 100, usedBytes: 95, availableBytes: 5)
        XCTAssertEqual(hotMem.severity, .hot)

        let calmSwap = VPSSwap(totalBytes: 100, usedBytes: 20, freeBytes: 80)
        XCTAssertEqual(calmSwap.severity, .calm)

        let elevatedSwap = VPSSwap(totalBytes: 100, usedBytes: 55, freeBytes: 45)
        XCTAssertEqual(elevatedSwap.severity, .elevated)

        let hotSwap = VPSSwap(totalBytes: 100, usedBytes: 85, freeBytes: 15)
        XCTAssertEqual(hotSwap.severity, .hot)
    }

    final class Counter: @unchecked Sendable {
        var value = 0
    }

    @MainActor
    func testVPSStatusStoreWithStub() async throws {
        let expected = try JSONDecoder().decode(VPSStatusSnapshot.self, from: sampleJSON)
        let counter = Counter()

        let store = VPSStatusStore(initialHost: "coolify", fetcher: { host in
            counter.value += 1
            if host == "fail.host" {
                throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
            }
            return expected
        })

        XCTAssertEqual(store.configuredHost, "coolify")
        XCTAssertNil(store.snapshot)

        store.fetch(force: true)
        // Give async Task a chance to complete
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(store.snapshot?.host, "fleet-hetzner-nbg1")
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.lastFetchDate)

        // Test failure path
        store.setHost("fail.host")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.value, 2)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.errorMessage, "Connection refused")
    }

    @MainActor
    func testStopPollingResetsIsLoading() async throws {
        let store = VPSStatusStore(initialHost: "coolify", fetcher: { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            throw NSError(domain: "test", code: 1, userInfo: nil)
        })

        store.fetch(force: true)
        XCTAssertTrue(store.isLoading)

        store.stopPolling()
        XCTAssertFalse(store.isLoading)
    }

    /// The panel shows the server headline and the Maintain tab shows one line,
    /// so the store is shared by more than one view.  One view closing must not
    /// switch the readings off for the others: the polling stops when the last
    /// owner lets go.
    @MainActor
    func testPollingSurvivesUntilTheLastOwnerLetsGo() {
        let store = VPSStatusStore(initialHost: "coolify", fetcher: { _ in
            throw NSError(domain: "test", code: 1, userInfo: nil)
        })

        store.acquirePolling()
        store.acquirePolling()
        store.releasePolling()
        XCTAssertTrue(store.isPolling, "one owner is left, so the readings keep coming")
        store.releasePolling()
        XCTAssertFalse(store.isPolling, "the last owner let go, so the readings stop")
    }

    /// The headline is the one-line answer the panel strip and the Maintain
    /// line are built from: the host, then each number with its own severity.
    func testTheHeadlineCarriesEachNumberWithItsOwnSeverity() throws {
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: sampleJSON)
        let headline = try XCTUnwrap(snapshot.headline)
        XCTAssertEqual(headline.host, "fleet-hetzner-nbg1")
        XCTAssertEqual(headline.cpuText, "25%")
        XCTAssertEqual(headline.cpuSeverity, .calm)
        XCTAssertEqual(headline.memoryText, "28%")
        XCTAssertEqual(headline.memorySeverity, .calm)
        // The root disk: 74 GB (69 GiB) free of an estimated 301 GiB.
        XCTAssertEqual(headline.diskText, "77% used")
        XCTAssertEqual(headline.diskSeverity, .elevated, "three quarters spent is worth a colour")
    }

    /// A snapshot with nothing in it still names its host, and nothing else.
    func testTheHeadlineOfAnEmptySnapshotIsTheHostAlone() throws {
        let json = """
        {"generated_at": "2026-10-18T19:15:03Z", "host": "empty-host", "devices": {}}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: json)
        let headline = try XCTUnwrap(snapshot.headline)
        XCTAssertEqual(headline.host, "empty-host")
        XCTAssertNil(headline.cpuText)
        XCTAssertNil(headline.memoryText)
        XCTAssertNil(headline.diskText)
    }

    @MainActor
    func testMaintainStoreVPSStoreIntegration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vps-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expected = try JSONDecoder().decode(VPSStatusSnapshot.self, from: sampleJSON)
        let configURL = tempDir.appendingPathComponent("config.json")
        try Data("{\"coolify_ssh_host\": \"coolify\"}".utf8).write(to: configURL)

        let maintainStore = MaintainStore(
            supportDirectory: tempDir,
            repoRoot: tempDir,
            launcher: { args in
                if args.count >= 2, args[0] == "--set-coolify-host" {
                    let newHost = args[1]
                    try? Data("{\"coolify_ssh_host\": \"\(newHost)\"}".utf8).write(to: configURL)
                }
                return true
            },
            infisical: nil,
            infisicalStore: nil,
            vpsFetcher: { _ in expected }
        )

        XCTAssertEqual(maintainStore.coolifyHost, "coolify")
        XCTAssertEqual(maintainStore.vpsStore.configuredHost, "coolify")

        maintainStore.setCoolifyHost("coolify-prod")
        for _ in 0..<50 where maintainStore.coolifyHost != "coolify-prod" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(maintainStore.coolifyHost, "coolify-prod")
        XCTAssertEqual(maintainStore.vpsStore.configuredHost, "coolify-prod")
    }
}
