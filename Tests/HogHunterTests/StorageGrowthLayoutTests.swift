import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import HogHunter

@MainActor
final class StorageGrowthLayoutTests: XCTestCase {
    func testMountedDrivePageStaysClampedAfterRemovalAndReplug() {
        var page = HogHunterPanel.clampedMountedDrivePage(2, count: 12)
        XCTAssertEqual(page, 2)
        page = HogHunterPanel.clampedMountedDrivePage(page, count: 3)
        XCTAssertEqual(page, 0)
        page = HogHunterPanel.clampedMountedDrivePage(page, count: 12)
        XCTAssertEqual(page, 0)
        XCTAssertEqual(HogHunterPanel.clampedMountedDrivePage(2, count: 0), 0)
        XCTAssertEqual(HogHunterPanel.clampedMountedDrivePage(-1, count: 12), 0)
        XCTAssertEqual(HogHunterPanel.clampedMountedDrivePage(2, count: 6), 1)
    }

    private var dashboardStageWidth: CGFloat { HogHunterPanel.dashboardWidth - 154 - 24 - 36 }

    func testCompactRowsAndServerContentRenderWithinPanelWidth() async throws {
        let now = Date()
        let snapshot = VPSStatusSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: now), host: "Development Server",
            devices: ["root": VPSDevice(mount: "/", freeBytes: 70_000_000_000, note: "301GB disk")],
            appDbs: ["st_app_db": 19_756_849_561, "ct_db": 4_000_000_000, "um_db": 900_000_000],
            cpu: VPSCPU(pct: 48, load1: 4.8, cores: 16),
            memory: VPSMemory(totalBytes: 32_000_000_000, usedBytes: 20_000_000_000, availableBytes: 12_000_000_000),
            largestDirs: [VPSDirectory(path: "~/Code", bytes: 25_000_000_000),
                          VPSDirectory(path: "~/apps/lanes", bytes: 12_000_000_000),
                          VPSDirectory(path: "~/.codex", bytes: 5_000_000_000)],
            toolStatuses: [VPSToolStatus(id: "codex", name: "Codex", state: .running, count: 2),
                           VPSToolStatus(id: "shellular", name: "Shellular", state: .running, count: 1),
                           VPSToolStatus(id: "muse", name: "Muse", state: .stopped, count: 0)],
            databaseSamples: [VPSSizeSample(path: "st_app_db", bytes: 18_293_379_223,
                                           sampledAt: now.addingTimeInterval(-86_400).timeIntervalSince1970)]
        )
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        let store = VPSStatusStore(initialHost: "fixture", fetcher: { _ in snapshot }, history: history)
        store.fetch(force: true)
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.databasePercentChange(key: "st_app_db") ?? 0, 8, accuracy: 0.01)

        let width = dashboardStageWidth
        let view = ServerStatusView(store: store)
            .frame(width: width, alignment: .topLeading)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 17)
        try render(host, size: CGSize(width: width + 16, height: 650), name: "hh165-server")

        let row = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
            SizeUsageRow(name: "Socratic Trade", bytes: 19_756_849_561, percentChange: 8)
            SizeUsageRow(name: "~/apps/lanes", bytes: 12_000_000_000, percentChange: -12)
            SizeUsageRow(name: "~/.codex", bytes: 5_000_000_000, percentChange: 0.8)
            SizeUsageRow(name: "~/Code", bytes: 25_000_000_000, percentChange: 0.02)
        }.padding(10).frame(width: 320).background(Color(nsColor: .windowBackgroundColor)))
        row.appearance = NSAppearance(named: .aqua)
        try render(row, size: CGSize(width: 320, height: 110), name: "hh165-size-rows")
    }

    /// Measure the complete report at its natural height.  A fixed-height
    /// wrapper or clipping here would let an overflowing last row pass.
    func testFullServerReportFitsWithoutScrollingAtDefaultPanelSize() async throws {
        let now = Date()
        let paths = ["/var/lib/docker", "/var/lib/docker/volumes", "/data", "/data/backups",
                     "/root/Code", "/root/apps/lanes", "/root/.claude", "/root/.codex",
                     "/root/.config/muse", "/root/.minimax", "/root/.minimax-code",
                     "/root/.npm", "/root/.cache"]
        let toolNames = ["Claude Code", "Codex", "Muse", "MiniMax Code", "Fleet CLI", "Fleet Listener",
                         "Fleet Recall", "Shellular", "Docker", "PostgreSQL", "Redis"]
        let states: [VPSToolStatus.State] = [.running, .stopped, .absent, .unknown]
        let snapshot = VPSStatusSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: now), host: "fleet-hetzner-nbg1",
            devices: ["root": VPSDevice(mount: "/", freeBytes: 74_097_487_872, note: "301GB disk: OS"),
                      "tmp": VPSDevice(mount: "/tmp", freeBytes: 16_201_887_744, note: "16GB RAM tmpfs"),
                      "shm": VPSDevice(mount: "/dev/shm", freeBytes: 16_424_865_792, note: "16GB RAM tmpfs")],
            appDbs: ["st_app_db": 19_904_122_112, "ct_db": 4_736_902_136, "um_db": 3_457_937_592],
            cpu: VPSCPU(pct: 24.8, load1: 3.07, cores: 16),
            memory: VPSMemory(totalBytes: 32_853_925_888, usedBytes: 9_095_159_808, availableBytes: 23_758_766_080),
            swap: VPSSwap(totalBytes: 18_253_602_816, usedBytes: 9_132_191_744, freeBytes: 9_121_411_072),
            largestDirs: paths.enumerated().map {
                VPSDirectory(path: $0.element, bytes: Int64(78_000_000_000 / ($0.offset + 1)))
            },
            toolStatuses: toolNames.enumerated().map {
                VPSToolStatus(id: $0.element, name: $0.element, state: states[$0.offset % states.count], count: 3)
            },
            databaseSamples: [VPSSizeSample(path: "st_app_db", bytes: 18_000_000_000,
                                           sampledAt: now.addingTimeInterval(-86_400).timeIntervalSince1970)],
            directorySamples: paths.map {
                VPSSizeSample(path: $0, bytes: 100_000_000_000,
                              sampledAt: now.addingTimeInterval(-86_400).timeIntervalSince1970)
            }
        )
        let store = VPSStatusStore(initialHost: "fixture", fetcher: { _ in snapshot },
                                   history: SizeGrowthHistory(fileURL: nil, now: { now }))
        store.fetch(force: true)
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(store.snapshot, "the full report must have loaded before measuring")
        let width = dashboardStageWidth
        let host = NSHostingView(rootView: ServerStatusView(store: store)
            .frame(width: width, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        let natural = host.fittingSize
        XCTAssertLessThanOrEqual(natural.width, width + 1)
        XCTAssertLessThanOrEqual(natural.height, 580,
                                 "full Server report should fit at the default dashboard size; got \(natural.height)pt")
        try render(host, size: CGSize(width: width, height: natural.height), name: "hh174-server-full-report")
    }

    func testExternalAndBackupDrivesFitCompactStorageWidth() async throws {
        let store = MountedDriveStore(probe: {
            [MountedDriveCandidate(name: "External", path: "/Volumes/External", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 2_500_000_000),
             MountedDriveCandidate(name: "Time Machine", path: "/Volumes/Time Machine", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 75_000_000_000)]
        })
        await store.refresh()
        let width = (dashboardStageWidth - 16) / 3
        let view = MountedDriveUsageView(store: store).frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
        try render(host, size: CGSize(width: width, height: 170), name: "hh165-external-drives")
    }

    /// The capacity cards must follow the drives that are actually mounted,
    /// whatever they are named: no fixed "Time Machine" slot.  A Mac with no
    /// backup destination - or none, or three, or a backup volume renamed to
    /// ordinary storage - renders the drives it has and nothing else.
    func testCapacityCardsFollowMountedDrivesOfAnyName() async throws {
        var driveSets: [[MountedDriveCandidate]] = [
            // No external drives at all.
            [],
            // One ordinary external drive, no backup destination.
            [MountedDriveCandidate(name: "External", path: "/Volumes/External", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 143_000_000_000)],
            // A backup volume named without a space, plus repurposed storage:
            // names that must not be classified, filtered or dropped.
            [MountedDriveCandidate(name: "External", path: "/Volumes/External", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 143_000_000_000),
             MountedDriveCandidate(name: "TimeMachine500GB", path: "/Volumes/TimeMachine500GB", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 47_000_000_000),
             MountedDriveCandidate(name: "Storage", path: "/Volumes/Storage", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 490_000_000_000)],
        ]
        driveSets.append((0..<12).map { index in
            MountedDriveCandidate(name: "Drive \(index)", path: "/Volumes/Drive\(index)",
                isLocal: true, isHidden: false, isExternalPhysical: true,
                totalBytes: 500_000_000_000, availableBytes: 100_000_000_000)
        })
        for (index, candidates) in driveSets.enumerated() {
            let mounted = MountedDriveStore(probe: { candidates })
            await mounted.refresh()
            XCTAssertEqual(mounted.rows.count, candidates.count)
            let suite = "hh-capacity-cards-\(UUID().uuidString)"
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences.set("This Mac", forKey: "dashboardHostScope")
            defer { preferences.removePersistentDomain(forName: suite) }
            let store = populatedStore(preferences)

            let quick = NSHostingView(rootView: HogHunterPanel(isQuickView: true, mountedDrives: mounted)
                .environmentObject(store).defaultAppStorage(preferences))
            quick.appearance = NSAppearance(named: .aqua)
            let quickSize = quick.fittingSize
            XCTAssertEqual(quickSize.width, HogHunterPanel.panelWidth, accuracy: 1)
            XCTAssertGreaterThan(quickSize.height, 200)
            XCTAssertLessThanOrEqual(quickSize.height, HogHunterPanel.panelHeight)
            try render(quick, size: CGSize(width: HogHunterPanel.panelWidth, height: HogHunterPanel.panelHeight), name: "hh-capacity-quick-\(index)")

            let overviewSize = CGSize(width: HogHunterPanel.dashboardWidth, height: HogHunterPanel.dashboardHeight)
            let overview = NSHostingView(rootView: HogHunterPanel(mountedDrives: mounted)
                .environmentObject(store).defaultAppStorage(preferences)
                .frame(width: overviewSize.width, height: overviewSize.height))
            overview.appearance = NSAppearance(named: .aqua)
            XCTAssertLessThanOrEqual(overview.fittingSize.width, overviewSize.width + 1)
            try render(overview, size: overviewSize, name: "hh-capacity-cards-\(index)")
        }
    }

    /// The glance view puts the Mac on the left half and the server on the
    /// right half of every section.  This draws it with a server attached and
    /// checks that the panel keeps its fixed width and height ceiling.
    func testQuickViewSplitsMacLeftAndServerRight() async throws {
        let json = """
        {"generated_at": "2026-10-18T19:15:03Z", "host": "fleet-hetzner-nbg1",
         "devices": {"root": {"mount": "/", "free_bytes": 61000000000, "note": "301GB disk: OS"},
                     "fleet_extra": {"mount": "/mnt/fleet-extra", "free_bytes": 62000000000, "note": "246GB disk"}},
         "cpu": {"pct": 24.8, "load1": 3.07, "cores": 16},
         "memory": {"total_bytes": 32853925888, "used_bytes": 9095159808, "available_bytes": 23758766080},
         "processes": [
           {"pid": 11, "name": "node", "cpu_percent": 88.0, "memory_bytes": 2100000000, "container": "botfleet"},
           {"pid": 12, "name": "postgres", "cpu_percent": 41.0, "memory_bytes": 900000000},
           {"pid": 13, "name": "dockerd", "cpu_percent": 6.0, "memory_bytes": 300000000}]}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(VPSStatusSnapshot.self, from: json)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"coolify_ssh_host": "fleet-hetzner-nbg1"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let maintain = MaintainStore(supportDirectory: directory, repoRoot: directory,
                                     launcher: { _ in XCTFail("no launch"); return true },
                                     vpsFetcher: { _ in snapshot })
        maintain.vpsStore.fetch(force: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(maintain.vpsStore.snapshot)

        let drives = MountedDriveStore(probe: {
            [MountedDriveCandidate(name: "External", path: "/Volumes/External", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 1_000_000_000_000, availableBytes: 622_000_000_000)]
        })
        await drives.refresh()
        let suite = "hh219-split-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = populatedStore(preferences, maintain: maintain)

        let quick = NSHostingView(rootView: HogHunterPanel(isQuickView: true, mountedDrives: drives)
            .environmentObject(store).defaultAppStorage(preferences))
        quick.appearance = NSAppearance(named: .aqua)
        let size = quick.fittingSize
        XCTAssertEqual(size.width, HogHunterPanel.panelWidth, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, HogHunterPanel.panelHeight)
        try render(quick, size: size, name: "hh219-quick-split")
    }

    func testQuickViewAndInitialStorageRenderWithMountedDrives() async throws {
        let drives = MountedDriveStore(probe: {
            [MountedDriveCandidate(name: "External", path: "/Volumes/External", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 2_500_000_000),
             MountedDriveCandidate(name: "Time Machine", path: "/Volumes/Time Machine", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 75_000_000_000),
             MountedDriveCandidate(name: "Time Machine Archive", path: "/Volumes/Time Machine Archive", isLocal: true,
                                   isHidden: false, isExternalPhysical: true,
                                   totalBytes: 500_000_000_000, availableBytes: 5_000_000_000)]
        })
        await drives.refresh()
        XCTAssertEqual(drives.rows.count, 3)
        let suite = "hh174-dashboard-layout-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set("This Mac", forKey: "dashboardHostScope")
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = populatedStore(preferences)
        XCTAssertEqual(store.rows.count, 7)
        XCTAssertEqual(store.cpuMinuteHistory.bars(at: store.pulse.sampledAt).compactMap { $0 }.count, 30)

        let quick = NSHostingView(rootView: HogHunterPanel(isQuickView: true, mountedDrives: drives)
            .environmentObject(store).defaultAppStorage(preferences))
        quick.appearance = NSAppearance(named: .aqua)
        let quickSize = quick.fittingSize
        XCTAssertEqual(quickSize.width, HogHunterPanel.panelWidth, accuracy: 1)
        XCTAssertGreaterThan(quickSize.height, 200)
        XCTAssertLessThanOrEqual(quickSize.height, HogHunterPanel.panelHeight)
        try render(quick, size: quickSize, name: "hh174-quick-external")

        for (name, size) in [
            ("minimum", CGSize(width: HogHunterPanel.dashboardMinimumWidth, height: 580)),
            ("default", CGSize(width: HogHunterPanel.dashboardWidth, height: HogHunterPanel.dashboardHeight))
        ] {
            let dashboard = NSHostingView(rootView: HogHunterPanel(initialTab: .storage, mountedDrives: drives)
                .environmentObject(store).defaultAppStorage(preferences)
                .frame(width: size.width, height: size.height))
            dashboard.appearance = NSAppearance(named: .aqua)
            XCTAssertLessThanOrEqual(dashboard.fittingSize.width, size.width + 1)
            try render(dashboard, size: size, name: "hh174-storage-\(name)")
        }

        let overviewSize = CGSize(width: HogHunterPanel.dashboardWidth, height: HogHunterPanel.dashboardHeight)
        let overview = NSHostingView(rootView: HogHunterPanel(mountedDrives: drives)
            .environmentObject(store).defaultAppStorage(preferences)
            .frame(width: overviewSize.width, height: overviewSize.height))
        overview.appearance = NSAppearance(named: .aqua)
        XCTAssertLessThanOrEqual(overview.fittingSize.width, overviewSize.width + 1)
        try render(overview, size: overviewSize, name: "hh174-overview-populated")
    }

    func testActivityStageRendersAtMinimumAndGrownSizes() throws {
        let suite = "hh174-activity-layout-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set("This Mac", forKey: "dashboardHostScope")
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = populatedStore(preferences)
        XCTAssertEqual(store.rows.count, 7)

        for (name, size) in [
            ("minimum", CGSize(width: HogHunterPanel.dashboardMinimumWidth, height: 580)),
            ("grown", CGSize(width: 1050, height: 780))
        ] {
            let activity = NSHostingView(rootView: HogHunterPanel(initialTab: .activity)
                .environmentObject(store).defaultAppStorage(preferences)
                .frame(width: size.width, height: size.height))
            activity.appearance = NSAppearance(named: .aqua)
            XCTAssertLessThanOrEqual(activity.fittingSize.width, size.width + 1)
            XCTAssertLessThanOrEqual(activity.fittingSize.height, size.height + 1)
            try render(activity, size: size, name: "hh174-activity-\(name)")
        }
    }

    func testOverviewActivityUsesRemainingHeightWithMacAndServerStops() async throws {
        let suite = "hh-overview-scroll-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("This Mac", forKey: "dashboardHostScope")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"coolify_ssh_host":"fixture"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let processes = (0..<30).map { index in
            VPSProcess(pid: 90000 + index, name: "Server worker \(index + 1)",
                startTime: Int64(index + 1), owner: "fixture", container: nil,
                cpuPercent: Double(95 - index), memoryBytes: 300_000_000,
                bootID: "fixture-boot", allowedActions: index == 0 ? [] : ["quit"],
                protectionReason: index == 0 ? "Protected fixture" : nil)
        }
        let snapshot = VPSStatusSnapshot(generatedAt: ISO8601DateFormatter().string(from: Date()),
            host: "Fixture server", devices: ["root": VPSDevice(mount: "/", freeBytes: 120_000_000_000, note: "500GB disk")],
            cpu: try JSONDecoder().decode(VPSCPU.self, from: Data(#"{"pct":32,"load1":2.1,"cores":16}"#.utf8)),
            memory: try JSONDecoder().decode(VPSMemory.self, from: Data(#"{"total_bytes":32000000000,"used_bytes":12000000000,"available_bytes":20000000000}"#.utf8)),
            processes: processes)
        let maintain = MaintainStore(supportDirectory: directory, repoRoot: directory,
            launcher: { _ in XCTFail("No maintenance action in a layout test"); return false },
            vpsFetcher: { _ in snapshot })
        maintain.vpsStore.setHost("fixture")
        maintain.vpsStore.fetch(force: true)
        for _ in 0..<100 where maintain.vpsStore.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let store = populatedStore(preferences, maintain: maintain, processCount: 30)
        XCTAssertGreaterThan(store.rows.count, 20)
        for _ in 0..<100 where maintain.vpsStore.snapshot == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(maintain.vpsStore.snapshot?.processes?.count, 30)
        XCTAssertFalse(store.tick(), "No live sampler in layout validation")
        for (name, quick, size) in [
            ("quick", true, CGSize(width: 720, height: 640)),
            ("overview-minimum", false, CGSize(width: 860, height: 580)),
            ("overview-grown", false, CGSize(width: 1050, height: 780))
        ] {
            let view = HogHunterPanel(isQuickView: quick).environmentObject(store)
                .defaultAppStorage(preferences).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .aqua)
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
            try render(host, size: size, name: "hh-overview-" + name)
            try render(host, size: size, name: "hh-overview-" + name + "-scrolled", scrollToEnd: true)
        }
        preferences.set("Server", forKey: "dashboardHostScope")
        for (name, size) in [("minimum", CGSize(width: 860, height: 580)),
                             ("grown", CGSize(width: 1050, height: 780))] {
            let host = NSHostingView(rootView: HogHunterPanel().environmentObject(store)
                .defaultAppStorage(preferences).frame(width: size.width, height: size.height))
            host.appearance = NSAppearance(named: .aqua)
            try render(host, size: size, name: "hh-overview-server-" + name)
            try render(host, size: size, name: "hh-overview-server-" + name + "-scrolled", scrollToEnd: true)
        }
        XCTAssertTrue(processes[1].can(action: "quit"))
        XCTAssertFalse(processes[0].can(action: "quit"))
        XCTAssertNil(maintain.lastError)
    }

    private func populatedStore(_ preferences: UserDefaults, maintain: MaintainStore? = nil, processCount: Int = 7) -> HogStore {
        let store = HogStore(historyURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hh174-populated-layout-\(UUID().uuidString).sqlite"),
            defaults: preferences, maintain: maintain, startImmediately: false)
        XCTAssertFalse(store.tick(), "the layout test host must never start the real sampler")
        var pulse = MachinePulse.empty
        pulse.cpuPercent = 68
        pulse.visibleCpuPercent = 61
        pulse.coreCount = 12
        pulse.readableProcessCount = 7
        pulse.memoryUsedBytes = 24_000_000_000
        pulse.appMemoryBytes = 15_000_000_000
        pulse.wiredBytes = 5_000_000_000
        pulse.compressedBytes = 4_000_000_000
        pulse.totalMemoryBytes = 32_000_000_000
        pulse.swapUsedBytes = 6_000_000_000
        pulse.swapTotalBytes = 12_000_000_000
        pulse.pressure = .warning
        pulse.thermalState = .serious
        pulse.batteryPercent = 67
        pulse.isCharging = false
        pulse.powerSource = "Battery Power"
        pulse.sampledAt = Date()

        let processRows: [(String, Double, UInt64)] = [
            ("Browser", 180, 7_400_000_000),
            ("Code Editor", 122, 4_800_000_000),
            ("Design Tool", 71, 3_200_000_000),
            ("Photo Library", 38, 2_100_000_000),
            ("Video Call", 24, 1_500_000_000),
            ("Backup Helper", 15, 900_000_000),
            ("Terminal", 6, 420_000_000),
        ]
        let processes = (0..<processCount).map { index in
            let row = processRows[index % processRows.count]
            let pid = pid_t(90_000 + index)
            return ProcessSample(key: ProcessKey(pid: pid, startTime: UInt64(index + 1)),
                ppid: 1, uid: getuid(), name: processCount > 7 ? "\(row.0) \(index + 1)" : row.0,
                path: "/fixture/\(index)", cpuPercent: row.1, hasBaseline: true,
                footprintBytes: row.2, residentBytes: row.2, threadCount: 8,
                diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0, idleWakeupsPerSec: 0)
        }
        store.applyLayoutSnapshotForTest(Snapshot(pulse: pulse, processes: processes, hasBaseline: true),
            cpuHistory: (0..<30).map { Double(25 + ($0 * 13) % 55) },
            diskSpace: DiskSpace(freeBytes: 120_000_000_000, totalBytes: 500_000_000_000))
        return store
    }

    private func render<V: View>(_ host: NSHostingView<V>, size: CGSize, name: String,
                                 scrollToEnd: Bool = false) throws {
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if scrollToEnd {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
            }
            let lists = scrollViews(host).filter { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height }
            XCTAssertFalse(lists.isEmpty, "The full process list must scroll, not truncate rows")
            for list in lists {
                guard let document = list.documentView else { continue }
                let y = document.isFlipped ? max(0, document.bounds.height - list.contentView.bounds.height) : 0
                list.contentView.scroll(to: NSPoint(x: 0, y: y))
                list.reflectScrolledClipView(list.contentView)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let directory = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("hh165-render").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        // Deliver pointer motion to this fixture window only. No global
        // pointer, sampler, process action or server request is involved.
        window.acceptsMouseMovedEvents = true
        for point in [NSPoint(x: size.width * 0.35, y: size.height * 0.25),
                      NSPoint(x: size.width * 0.8, y: size.height * 0.2)] {
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0) {
                window.sendEvent(event)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size, "Hover must not resize the activity area")
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + "-hover.png"))
        window.contentView = nil
    }
}
