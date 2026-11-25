import AppKit
import SwiftUI
import XCTest
@testable import HogHunter

/// The Overview summary was capped at 320pt so it never grew with the window
/// (PR #398 fixed that), and then `layoutPriority(1)` on `activitySection`
/// claimed space first so the summary collapsed to 0pt in short windows
/// (Kody's high-severity finding on PR #398).  Both regressions are covered
/// here: the summary never collapses below a usable floor, and it grows with
/// the window like the Disk Cleaner does.  No live app is launched.
@MainActor
final class OverviewLayoutTests: XCTestCase {

    private let minimumSize = CGSize(width: 860, height: 580)
    private let grownSize   = CGSize(width: 1050, height: 780)
    private let windowWidth: CGFloat = 1024
    private let windowHeight: CGFloat = 848

    private final class Box {
        var height: CGFloat = 0
    }

    /// A populated store the Overview panel can render without starting the
    /// real sampler (layout tests only).
    private func populatedStore(_ preferences: UserDefaults) -> HogStore {
        let store = HogStore(historyURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("overview-layout-\(UUID().uuidString).sqlite"),
            defaults: preferences, startImmediately: false)
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
        let processes = processRows.enumerated().map { index, row in
            let pid = pid_t(90_000 + index)
            return ProcessSample(key: ProcessKey(pid: pid, startTime: UInt64(index + 1)),
                ppid: 1, uid: getuid(), name: row.0, path: "/fixture/\(index)", cpuPercent: row.1,
                hasBaseline: true, footprintBytes: row.2, residentBytes: row.2, threadCount: 8,
                diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0, idleWakeupsPerSec: 0)
        }
        store.applyLayoutSnapshotForTest(Snapshot(pulse: pulse, processes: processes, hasBaseline: true),
            cpuHistory: (0..<30).map { Double(25 + ($0 * 13) % 55) },
            diskSpace: DiskSpace(freeBytes: 120_000_000_000, totalBytes: 500_000_000_000))
        return store
    }

    /// Renders the Overview panel at a window size and returns the measured
    /// summary height, writing a PNG when `renderName` is given.
    private func overviewSummaryHeight(in size: CGSize, preferences: UserDefaults,
                                       renderName: String?) throws -> CGFloat {
        let box = Box()
        let store = populatedStore(preferences)
        let root = HogHunterPanel(initialTab: .overview)
            .environmentObject(store)
            .defaultAppStorage(preferences)
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(OverviewSummaryHeight.self) { box.height = $0 }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        if let renderName { try render(host, size: size, name: renderName) }
        window.contentView = nil
        return box.height
    }

    private func render<V: View>(_ host: NSHostingView<V>, size: CGSize, name: String) throws {
        let directory = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("overview-layout").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "nothing rendered for \(name)")
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    /// **The regression.**  With `layoutPriority(1)` on `activitySection`, the
    /// summary ScrollView starved to 0pt in a short window and the overview
    /// cards vanished.  The summary must keep a usable minimum regardless of
    /// how short the window is.
    func testOverviewSummaryNeverCollapsesInAShortWindow() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let height = try overviewSummaryHeight(in: minimumSize, preferences: suite,
                                               renderName: "hh236-overview-minimum")
        XCTAssertGreaterThanOrEqual(height, 200, "the summary got \(Int(height))pt in a \(Int(minimumSize.height))pt window")
    }

    /// **Jay's "Grow" decision.**  A taller window gives the summary more room,
    /// just like the Disk Cleaner's scroll region grows with the window.
    func testOverviewSummaryGrowsWithTheWindow() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let short = try overviewSummaryHeight(in: minimumSize, preferences: suite,
                                              renderName: "hh236-overview-minimum")
        let tall = try overviewSummaryHeight(in: grownSize, preferences: suite,
                                             renderName: "hh236-overview-grown")
        XCTAssertGreaterThan(tall, short + 200, "the summary did not grow with the window (short \(Int(short))pt, tall \(Int(tall))pt)")
    }

    /// The panel must fit within the height it is offered rather than asking
    /// for more than the window has.
    func testOverviewPanelDoesNotOverflowTheHeightItIsOffered() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = populatedStore(suite)
        let root = HogHunterPanel(initialTab: .overview)
            .environmentObject(store)
            .defaultAppStorage(suite)
            .frame(width: windowWidth, height: windowHeight)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: CGSize(width: windowWidth, height: windowHeight))
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        XCTAssertLessThanOrEqual(fitted.height, windowHeight + 1,
            "the overview panel wants \(Int(fitted.height))pt but was offered \(Int(windowHeight))pt")
    }

    /// The runner draws the Overview at minimum and grown sizes so the owner
    /// can see the result without launching the app on their machine.
    func testOverviewRendersForTheRunner() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        for (name, size) in [("hh236-overview-minimum", minimumSize),
                             ("hh236-overview-grown", grownSize)] {
            let store = populatedStore(suite)
            let root = HogHunterPanel(initialTab: .overview)
                .environmentObject(store)
                .defaultAppStorage(suite)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: .aqua)
            host.frame = CGRect(origin: .zero, size: size)
            try render(host, size: size, name: name)
        }
    }
}
