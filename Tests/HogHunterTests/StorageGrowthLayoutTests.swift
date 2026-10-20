import AppKit
import SwiftUI
import XCTest
@testable import HogHunter

@MainActor
final class StorageGrowthLayoutTests: XCTestCase {
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
                         "Fleet Recall", "Shellular", "Docker", "Caddy", "PostgreSQL", "Redis"]
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

    private func render<V: View>(_ host: NSHostingView<V>, size: CGSize, name: String) throws {
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let directory = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("hh165-render").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
}
