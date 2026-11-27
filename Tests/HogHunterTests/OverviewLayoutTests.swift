import AppKit
import SwiftUI
import XCTest
@testable import HogHunter

/// The Overview summary was capped at 320pt so it never grew with the window
/// (PR #398 fixed that), and then `layoutPriority(1)` on `activitySection`
/// claimed space first so the summary collapsed to 0pt in short windows
/// (Kody's high-severity finding on PR #398).  The split is gone now: one
/// scroll holds the cards, captions, and activity rows together.  Covered
/// here: the scroll viewport never collapses below a usable floor, it grows
/// with the window like the Disk Cleaner does, and the rows size their own
/// block instead of clipping to a strip.  No live app is launched.
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
    /// real sampler (layout tests only).  Pass explicit rows (possibly none)
    /// to pin how the activity block sizes itself.
    private func populatedStore(_ preferences: UserDefaults,
                                processRows: [(String, Double, UInt64)]? = nil) -> HogStore {
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

        let processRows: [(String, Double, UInt64)] = processRows ?? [
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
    /// scroll viewport height, writing a PNG when `renderName` is given.
    private func overviewScrollViewportHeight(in size: CGSize, preferences: UserDefaults,
                                              renderName: String?) throws -> CGFloat {
        let box = Box()
        let store = populatedStore(preferences)
        let root = HogHunterPanel(initialTab: .overview)
            .environmentObject(store)
            .defaultAppStorage(preferences)
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(OverviewScrollViewportHeight.self) { box.height = $0 }
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

    /// Renders the Overview panel and returns the height the activity rows
    /// actually occupy, so the rows can never silently clip to a fixed
    /// strip with their own scrollbar again.
    private func overviewActivityHeight(in size: CGSize, preferences: UserDefaults,
                                        processRows: [(String, Double, UInt64)]?) throws -> CGFloat {
        let box = Box()
        let store = populatedStore(preferences, processRows: processRows)
        let root = HogHunterPanel(initialTab: .overview)
            .environmentObject(store)
            .defaultAppStorage(preferences)
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(OverviewActivityHeight.self) { box.height = $0 }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        window.contentView = nil
        return box.height
    }

    private func render<V: View>(_ host: NSHostingView<V>, size: CGSize, name: String) throws {
        let directory = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("overview-layout").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // The host must lay out in a window and cache its display, or the
        // bitmap comes back black (the Maintain layout tests do the same).
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "nothing rendered for \(name)")
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    /// **The regression.**  With `layoutPriority(1)` on `activitySection`, the
    /// summary ScrollView starved to 0pt in a short window and the overview
    /// cards vanished.  The one scroll viewport must keep a usable minimum
    /// regardless of how short the window is.
    func testOverviewScrollNeverCollapsesInAShortWindow() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let height = try overviewScrollViewportHeight(in: minimumSize, preferences: suite,
                                                      renderName: "hh236-overview-minimum")
        XCTAssertGreaterThanOrEqual(height, 200, "the scroll got \(Int(height))pt in a \(Int(minimumSize.height))pt window")
    }

    /// **Jay's "Grow" decision.**  A taller window gives the scroll viewport
    /// more room, just like the Disk Cleaner's scroll region grows with the
    /// window.  The window grows 200pt between the two sizes; the viewport
    /// must take nearly all of it.
    func testOverviewScrollGrowsWithTheWindow() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let short = try overviewScrollViewportHeight(in: minimumSize, preferences: suite,
                                                     renderName: "hh236-overview-minimum")
        let tall = try overviewScrollViewportHeight(in: grownSize, preferences: suite,
                                                    renderName: "hh236-overview-grown")
        XCTAssertGreaterThan(tall, short + 150, "the scroll did not grow with the window (short \(Int(short))pt, tall \(Int(tall))pt)")
    }

    /// **The dashboard scroll.**  The activity rows lived in a fixed strip
    /// with its own scrollbar while the summary above scrolled separately,
    /// so the processes were a tiny area at the bottom.  The rows now size
    /// their own block inside the one Overview scroll: seven rows must stand
    /// a full row-set taller than none.
    func testActivityRowsSizeTheScrollContent() throws {
        let suiteName = "hh-overview-layout-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let empty = try overviewActivityHeight(in: minimumSize, preferences: suite, processRows: [])
        let full = try overviewActivityHeight(in: minimumSize, preferences: suite, processRows: nil)
        XCTAssertGreaterThan(full - empty, 100,
            "seven rows stand only \(Int(full - empty))pt taller than none (empty \(Int(empty))pt, full \(Int(full))pt)")
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
