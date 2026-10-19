import AppKit
import SwiftUI
import XCTest
@testable import HogHunter

@MainActor
final class StorageGrowthLayoutTests: XCTestCase {
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
        for _ in 0..<100 where store.isLoading { await Task.yield() }
        XCTAssertEqual(store.databasePercentChange(key: "st_app_db") ?? 0, 8, accuracy: 0.01)

        let width = HogHunterPanel.contentWidth
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
