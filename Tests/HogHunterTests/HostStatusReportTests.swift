import XCTest
import Darwin
@testable import HogHunter

/// Covers the Mac status file Muster reads: what it holds, what it must never hold, and how
/// it is written.
final class HostStatusReportTests: XCTestCase {

    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostStatusTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private let secrets = [
        "/Users/jay/apps/lanes/Secret/claude-secret-lane",
        "claude-secret-lane",
        "hetzner-secret-host.example",
        "/Applications/Secret.app/Contents/MacOS/Secret",
        "--token=abc123argv",
        "SecretVolumeName",
        "/Volumes/Secret/Private/Folder",
        "owner-host-secret",
    ]

    private func pulse(sampled: Bool = true) -> MachinePulse {
        var p = MachinePulse.empty
        p.cpuPercent = 41.256
        p.coreCount = 10
        p.totalMemoryBytes = 32 << 30
        p.memoryUsedBytes = 20 << 30
        p.swapTotalBytes = 4 << 30
        p.swapUsedBytes = 1 << 30
        p.sampledAt = sampled ? now : .distantPast
        return p
    }

    private func process(_ pid: Int32, _ name: String, cpu: Double, mem: UInt64 = 1 << 20,
                         baseline: Bool = true) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: 1), ppid: 1, uid: 501, name: name,
            path: "/Applications/Secret.app/Contents/MacOS/Secret", cpuPercent: cpu,
            hasBaseline: baseline, footprintBytes: mem, residentBytes: mem, threadCount: 1,
            diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0, idleWakeupsPerSec: 0)
    }

    private func maintainStatus() -> MaintainStatus {
        let step = MaintainStepResult(
            stepId: "worktrees", title: "Retire merged worktrees in claude-secret-lane",
            status: "ok", reason: "removed /Users/jay/apps/lanes/Secret/claude-secret-lane on hetzner-secret-host.example",
            bytesFreed: 5, durationMs: 1)
        let run = MaintainRun(
            runId: "r1", trigger: "scheduled", startedAt: now.timeIntervalSince1970 - 90,
            endedAt: now.timeIntervalSince1970 - 30, bytesFreed: 4096, exitCode: 0, steps: [step],
            outcome: "partial", currentStep: "claude-secret-lane", currentTarget: "--token=abc123argv")
        return MaintainStatus(
            health: "healthy", launchdLoaded: true, nextRunAt: [:], intervalsSeconds: [:],
            lastRunAt: nil, lastRun: run, stepLastResults: ["worktrees": step], historyCount: 1,
            updatedAt: nil)
    }

    private func source(_ overrides: (inout HostStatusSource) -> Void = { _ in }) -> HostStatusSource {
        var s = HostStatusSource(
            pulse: pulse(), hasBaseline: true,
            processes: (1...15).map { process(Int32($0), "proc\($0)", cpu: Double($0) * 3) },
            bootDisk: DiskSpace(freeBytes: 100 << 30, totalBytes: 500 << 30),
            drives: [MountedDriveUsage(
                name: "SecretVolumeName", path: "/Volumes/Data2", totalBytes: 1000, availableBytes: 250)],
            maintain: maintainStatus(), regimenEnabled: true,
            regimenLastRunAt: now.addingTimeInterval(-3600), regimenWaiting: false,
            serverSnapshotGeneratedAt: HostStatusBuilder.iso(now.addingTimeInterval(-120)))
        overrides(&s)
        return s
    }

    private func live(lock: String = "free") -> HostStatusLiveReadings {
        HostStatusLiveReadings(
            loadAverage: [1.234, 2, 3], uptimeSeconds: 7200, lockState: lock, host: "mac-mini",
            appVersion: "1.0.9")
    }

    private func encoded(_ report: HostStatusReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    // MARK: - Content

    func testPopulatedReportHasTheAgreedFields() throws {
        let report = HostStatusBuilder.build(source: source(), live: live(), now: now)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.tool, "hoghunter-mac-status")
        XCTAssertEqual(report.appVersion, "1.0.9")
        XCTAssertEqual(report.hostMetrics?.cpuCount, 10)
        XCTAssertEqual(report.hostMetrics?.cpuPercent, 41.26)
        XCTAssertEqual(report.hostMetrics?.uptimeSeconds, 7200)
        XCTAssertEqual(report.hostMetrics?.memory?.availableBytes, 12 << 30)
        XCTAssertEqual(report.hostMetrics?.swap?.freeBytes, 3 << 30)
        XCTAssertEqual(report.hostMetrics?.disks?.map(\.mount), ["/", "/Volumes/Data2"])
        XCTAssertEqual(report.hostMetrics?.disks?.last?.usedBytes, 750)
        XCTAssertEqual(report.processes?.count, 10)
        XCTAssertEqual(report.processes?.first?.name, "proc15")
        XCTAssertEqual(report.maintain?.health, "healthy")
        XCTAssertEqual(report.maintain?.lastRunOutcome, "partial")
        XCTAssertEqual(report.maintain?.bytesFreed, 4096)
        XCTAssertEqual(report.housekeeperLock, "free")
        XCTAssertEqual(report.regimen?.enabled, true)
        XCTAssertEqual(report.serverSnapshotAgeSeconds, 120)
    }

    func testEncodedReportCarriesNoPathArgvReasonLaneHostOrOwnerRecord() throws {
        let text = try encoded(HostStatusBuilder.build(source: source(), live: live(), now: now))
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "report leaked \(secret)")
        }
        // The only slashes in the report are the two mount points and the time stamps' none.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let strings = Self.strings(in: json).filter { $0.contains("/") }
        XCTAssertEqual(Set(strings), ["/", "/Volumes/Data2"])
    }

    func testOwnerRecordOfALiveLockIsReadButNeverReturned() throws {
        let lockPath = root.appendingPathComponent(".housekeeper.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        let owner: [String: Any] = [
            "pid": Int(getpid()), "host": "owner-host-secret", "acquired_at": 1.0, "lock": lockPath.path,
            "start": "x",
        ]
        let ownerURL = root.appendingPathComponent(".housekeeper.lock.owner")
        try JSONSerialization.data(withJSONObject: owner).write(to: ownerURL)
        let lock = HousekeeperLock(path: lockPath)
        let state = lock.observedState()
        XCTAssertNotEqual(state, .free)
        let report = HostStatusBuilder.build(
            source: source(), live: HostStatusLiveReadings(
                loadAverage: nil, uptimeSeconds: nil, lockState: state.rawValue, host: nil, appVersion: nil),
            now: now)
        let text = try encoded(report)
        XCTAssertFalse(text.contains("owner-host-secret"))
        XCTAssertFalse(text.contains(String(getpid()) + ","))
        XCTAssertFalse(text.contains(lockPath.path))
    }

    func testValuesNotMeasuredAreOmittedNeverZero() throws {
        var s = source()
        s.pulse = pulse(sampled: false)
        s.hasBaseline = false
        s.bootDisk = nil
        s.drives = []
        s.maintain = nil
        s.regimenEnabled = nil
        s.regimenLastRunAt = nil
        s.regimenWaiting = nil
        s.serverSnapshotGeneratedAt = nil
        let report = HostStatusBuilder.build(
            source: s,
            live: HostStatusLiveReadings(
                loadAverage: nil, uptimeSeconds: nil, lockState: "unknown", host: nil, appVersion: nil),
            now: now)
        let text = try encoded(report)
        for key in ["hostMetrics", "processes", "maintain", "regimen", "serverSnapshotAgeSeconds",
                    "cpuPercent", "memory", "swap", "disks", "host\""] {
            XCTAssertFalse(text.contains(key), "\(key) should be absent: \(text)")
        }
        XCTAssertTrue(text.contains("\"housekeeperLock\":\"unknown\""))
    }

    func testNoSwapAndNoBaselineAreLeftOut() {
        var s = source()
        s.hasBaseline = false
        var p = pulse()
        p.swapTotalBytes = 0
        p.swapUsedBytes = 0
        s.pulse = p
        let report = HostStatusBuilder.build(source: s, live: live(), now: now)
        XCTAssertNil(report.hostMetrics?.swap)
        XCTAssertNil(report.hostMetrics?.cpuPercent)
        XCTAssertNil(report.processes)
        XCTAssertNotNil(report.hostMetrics?.memory)
    }

    func testUnknownHealthAndOutcomeWordsAreDropped() {
        var status = maintainStatus()
        status.health = "all good at /Users/jay/secret"
        status.lastRun?.outcome = "weird /Users/jay/secret"
        let maintain = HostStatusBuilder.maintain(from: status)
        XCTAssertNil(maintain?.health)
        XCTAssertNil(maintain?.lastRunOutcome)
        XCTAssertEqual(maintain?.lastRunExitCode, 0)
    }

    func testFutureServerSnapshotHasNoAge() {
        var s = source()
        s.serverSnapshotGeneratedAt = HostStatusBuilder.iso(now.addingTimeInterval(600))
        XCTAssertNil(HostStatusBuilder.build(source: s, live: live(), now: now).serverSnapshotAgeSeconds)
    }

    func testReportRoundTripsThroughJSON() throws {
        let report = HostStatusBuilder.build(source: source(), live: live(), now: now)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(HostStatusReport.self, from: data), report)
    }

    // MARK: - Lock state

    func testLockStateFreeHeldStaleUnknown() throws {
        let path = root.appendingPathComponent(".housekeeper.lock", isDirectory: true)
        XCTAssertEqual(HousekeeperLock(path: path).observedState(), .free)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertEqual(HousekeeperLock(path: path).observedState(), .held)
        let old = Date().addingTimeInterval(-3 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        XCTAssertEqual(HousekeeperLock(path: path).observedState(), .stale)
        // A plain file at the lock path is not a lock directory.
        let file = root.appendingPathComponent("not-a-dir")
        try Data().write(to: file)
        XCTAssertEqual(HousekeeperLock(path: file).observedState(), .unknown)
    }

    func testObservingDoesNotChangeTheLock() throws {
        let path = root.appendingPathComponent(".housekeeper.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let before = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        _ = HousekeeperLock(path: path).observedState()
        let after = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: - Writing

    func testWritesOnlyIntoAnExistingFolderWithMode0600() throws {
        let folder = root.appendingPathComponent("fleet-tools", isDirectory: true)
        let reporter = HostStatusReporter(directory: folder)
        XCTAssertFalse(reporter.write(source: source(), now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the folder must not be created")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(reporter.write(source: source(), now: now))
        let attributes = try FileManager.default.attributesOfItem(atPath: reporter.reportURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let decoded = try JSONDecoder().decode(
            HostStatusReport.self, from: Data(contentsOf: reporter.reportURL))
        XCTAssertEqual(decoded.tool, "hoghunter-mac-status")
        // No temporary file is left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path),
                       ["hoghunter-mac.json"])
        // A second write replaces the first.
        XCTAssertTrue(reporter.write(source: source(), now: now.addingTimeInterval(60)))
    }

    func testRefusesToWriteThroughASymlink() throws {
        let folder = root.appendingPathComponent("fleet-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("elsewhere.json")
        try Data("keep".utf8).write(to: target)
        let reporter = HostStatusReporter(directory: folder)
        try FileManager.default.createSymbolicLink(at: reporter.reportURL, withDestinationURL: target)
        XCTAssertFalse(reporter.write(source: source(), now: now))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testDefaultReporterWritesNothingUnderXCTest() {
        // No directory is injected, so the run mode (unit tests) forbids the write, whether or
        // not the real folder exists on this Mac.
        let reporter = HostStatusReporter()
        XCTAssertFalse(reporter.write(source: source(), now: now))
    }

    // MARK: - Helpers

    private static func strings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let dict = value as? [String: Any] { return dict.values.flatMap(strings(in:)) }
        if let list = value as? [Any] { return list.flatMap(strings(in:)) }
        return []
    }

    func testAFolderOthersCanWriteToIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appendingPathComponent("hoghunter-mac.json")

        for mode in [0o775, 0o777, 0o757] {
            XCTAssertEqual(chmod(folder.path, mode_t(mode)), 0)
            XCTAssertFalse(HostStatusReporter.atomicWrite(Data("{}".utf8), to: report), "mode \(String(mode, radix: 8))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        }

        XCTAssertEqual(chmod(folder.path, 0o700), 0)
        XCTAssertTrue(HostStatusReporter.atomicWrite(Data("{}".utf8), to: report))
    }
}
