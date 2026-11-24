import AppKit
import SwiftUI
import XCTest
@testable import HogHunter

/// The Storage tab's Disk Cleaner used to squeeze its category list into a
/// sliver at the bottom of the window: the header's own spacer took every
/// spare point, so the scroll region holding the list got almost nothing and
/// only that sliver scrolled.  The whole tab scrolls now, with the action bar
/// pinned at the bottom.
@MainActor
final class StorageCleanerLayoutTests: XCTestCase {

    private final class Box {
        var height: CGFloat = 0
    }

    /// The size of the window Jay was looking at.
    private let windowWidth: CGFloat = 1024
    private let windowHeight: CGFloat = 848

    private func sampleReport() -> CleanScanReport {
        func item(_ category: CleanCategory, _ title: String, bytes: UInt64) -> CleanItem {
            CleanItem(category: category, title: title, subtitle: title,
                      url: URL(fileURLWithPath: "/tmp/hoghunter-layout-\(title)"),
                      bytes: bytes, fileCount: 3, lastModified: nil, isSelected: false, detail: nil)
        }
        func group(_ row: CleanItem) -> CleanCategoryReport {
            CleanCategoryReport(category: row.category, items: [row], totalBytes: row.bytes,
                                selectedBytes: 0, itemCount: 3)
        }
        return CleanScanReport(
            categories: [
                group(item(.userCaches, "User Caches", bytes: 83_000_000)),
                group(item(.logsAndDiagnostics, "Logs and Diagnostics", bytes: 40_000_000)),
                group(item(.developer, "Developer", bytes: 900_000_000)),
                group(item(.apfsSnapshots, "APFS Local Snapshots", bytes: 1_200_000_000))
            ],
            totalBytes: 2_223_000_000,
            totalSelectedBytes: 0,
            scannedAt: Date(),
            tier: .standard
        )
    }

    private func store() -> DiskCleanerStore {
        let store = DiskCleanerStore(historyStore: CleanupHistoryStore(inMemory: true))
        store.setReportForTest(sampleReport())
        return store
    }

    /// The height the cleaner's scroll region was given inside a window of
    /// `height` points.
    private func scrollHeight(in height: CGFloat) -> CGFloat {
        let box = Box()
        let root = DiskCleanerView(store: store())
            .onPreferenceChange(DiskCleanerScrollHeightKey.self) { box.height = $0 }
            .frame(width: windowWidth, height: height)
        let controller = NSHostingController(rootView: root)
        controller.view.frame = CGRect(x: 0, y: 0, width: windowWidth, height: height)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        controller.view.layoutSubtreeIfNeeded()
        return box.height
    }

    /// **The bug.**  The list used to get the crumbs: the header's spacer took
    /// every spare point, so the scroll region was a sliver at the bottom of
    /// the window and only that sliver scrolled.
    func testTheScrollRegionTakesTheWindowInsteadOfASliver() {
        let height = scrollHeight(in: windowHeight)
        XCTAssertGreaterThan(
            height,
            windowHeight * 0.5,
            "the category list got \(Int(height)) pt of a \(Int(windowHeight)) pt window"
        )
    }

    /// The same tab in a taller window gets a taller scroll region, which is
    /// what "the whole tab scrolls" means: the list is not pinned to a fixed
    /// strip of pixels.
    func testTheScrollRegionGrowsWithTheWindow() {
        let short = scrollHeight(in: 700)
        let tall = scrollHeight(in: 1100)
        XCTAssertGreaterThan(tall, short + 200, "the scroll region did not grow with the window")
    }

    /// The tab must take the height it is offered and scroll the rest, rather
    /// than asking for more than the window has.
    func testTheTabDoesNotOverflowTheHeightItIsOffered() {
        let controller = NSHostingController(rootView: DiskCleanerView(store: store()))
        let offered: CGFloat = 520
        let fitted = controller.sizeThatFits(in: CGSize(width: windowWidth, height: offered))
        XCTAssertLessThanOrEqual(
            fitted.height,
            offered + 1,
            "the cleaner wants \(Int(fitted.height)) pt but was offered \(Int(offered)) pt"
        )
    }

    /// The runner draws the tab so the owner can see the result without anyone
    /// launching the app on their machine.
    func testTheStorageCleanerRendersForTheRunner() throws {
        let rep = bitmap(
            of: DiskCleanerView(store: store()).frame(width: windowWidth, height: windowHeight),
            size: CGSize(width: windowWidth, height: windowHeight)
        )
        try savePNG(rep, named: "hh236-storage-cleaner-tab.png")
    }

    private func bitmap<V: View>(of view: V, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    private func savePNG(_ rep: NSBitmapImageRep?, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["HOGHUNTER_RENDER_DIR"], !folder.isEmpty else { return }
        let rep = try XCTUnwrap(rep, "nothing rendered for \(name)")
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
