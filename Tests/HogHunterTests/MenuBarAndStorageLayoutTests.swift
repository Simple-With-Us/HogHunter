import AppKit
import XCTest
import SwiftUI
@testable import HogHunter

final class MenuBarAndStorageLayoutTests: XCTestCase {

    func testMenuBarLabelModeIncludesHistoryBars() {
        XCTAssertEqual(MenuBarLabelMode.historyBars.rawValue, "History Bars & %")
        XCTAssertTrue(MenuBarLabelMode.allCases.contains(.historyBars))
        XCTAssertEqual(MenuBarLabelMode(rawValue: "History Bars & %"), .historyBars)
    }

    func testCompanionSnapshotCarriesHistoryBars() {
        XCTAssertTrue(CompanionSettingsLimits.menuBarLabelModes.contains("History Bars & %"))
    }

    func testCompanionSettingsValidatesHistoryBars() {
        let req = CompanionSettingsUpdateRequest(menuBarLabelMode: "History Bars & %")
        let res = CompanionSettingsValidator.validate(req)
        switch res {
        case .success(let val):
            XCTAssertEqual(val.menuBarLabelMode, MenuBarLabelMode.historyBars)
        case .failure(let err):
            XCTFail("Expected success but got: \(err.message)")
        }
    }

    func testCompanionSettingsRejectsUnknownMode() {
        let req = CompanionSettingsUpdateRequest(menuBarLabelMode: "Invalid Mode")
        let res = CompanionSettingsValidator.validate(req)
        switch res {
        case .success:
            XCTFail("Expected failure for invalid mode")
        case .failure(let err):
            XCTAssertTrue(err.message.contains("History Bars & %"))
        }
    }

    func testStorageSubTabsCarriesThreeSections() {
        XCTAssertEqual(
            HogHunterPanel.StorageSubTab.allCases.map(\.rawValue),
            ["Installed Apps", "Disk Cleaner", "Drives & Folders"]
        )
    }

    @MainActor
    private func makeIsolatedMaintainStore() -> MaintainStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-menubar-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MaintainStore(supportDirectory: directory, repoRoot: directory, launcher: { _ in true })
    }

    @MainActor
    private func makeIsolatedHogStore() -> HogStore {
        let maintain = makeIsolatedMaintainStore()
        let suite = "hh-menubar-storage-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: historyURL) }
        return HogStore(
            historyURL: historyURL,
            defaults: defaults,
            infisical: IsolatedInfisical.make(),
            maintain: maintain,
            startImmediately: false
        )
    }

    @MainActor
    func testMenuBarRefreshesAfterApplicationAppearanceChanges() async throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        app.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let store = makeIsolatedHogStore()
        store.refreshMenuBar()
        let revision = store.menuBarStatus.presentation.revision
        let rasters = store.menuBarStatus.rasterCount

        app.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        // The KVO callback hops to MainActor before updating the picture.
        for _ in 0..<100 where store.menuBarStatus.presentation.revision == revision {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(store.menuBarStatus.presentation.revision, revision)
        XCTAssertGreaterThan(store.menuBarStatus.rasterCount, rasters)
    }

    @MainActor
    func testHogStoreDefaultsToHistoryBars() {
        let store = makeIsolatedHogStore()
        XCTAssertEqual(store.menuBarLabelMode, .historyBars)
        XCTAssertTrue(store.menuBarHelp.contains("Last 14 minutes CPU history"))
        XCTAssertFalse(store.showMenuBarIcon)
        XCTAssertTrue(store.showMenuBarPercent)
    }

    @MainActor
    func testStorageViewInitializesWithShowModePickerFalse() {
        let maintain = makeIsolatedMaintainStore()
        let view = StorageView(
            runningBundleIds: { [] },
            maintainStore: maintain,
            embeddedInPanel: true,
            isTabActive: true,
            initialTab: .appStorage,
            includesMaintenance: false,
            autoScanCleaner: false,
            showModePicker: false
        )
        XCTAssertNotNil(view)
    }

    @MainActor
    func testStorageViewWithExternalTabBinding() {
        let maintain = makeIsolatedMaintainStore()
        var tab: StorageTab = .appStorage
        let binding = Binding<StorageTab>(
            get: { tab },
            set: { tab = $0 }
        )
        let view = StorageView(
            runningBundleIds: { [] },
            maintainStore: maintain,
            embeddedInPanel: true,
            isTabActive: true,
            externalTab: binding,
            initialTab: .appStorage,
            includesMaintenance: false,
            autoScanCleaner: false,
            showModePicker: false
        )
        XCTAssertNotNil(view)
    }

    func testMenuBarCpuBarsViewMakeImage() {
        var history = CpuMinuteHistory()
        history.record(percent: 45.0, at: Date())
        let image = MenuBarCpuBarsView.makeImage(history: history, cpuPercent: 72.0, showPercent: true)
        assertStatusBarBitmap(image, points: MenuBarCpuBarsView.pointSize)
        XCTAssertFalse(image.isTemplate)

        let imageNoPercent = MenuBarCpuBarsView.makeImage(history: history, cpuPercent: 72.0, showPercent: false)
        assertStatusBarBitmap(imageNoPercent, points: MenuBarCpuBarsView.pointSize)
        // The percent is hidden and the bar is calm, so the bitmap is a template.
        XCTAssertTrue(imageNoPercent.isTemplate)
    }

    func testCpuSparklineViewMakeImage() {
        let image = CpuSparklineView.makeImage(samples: [10.0, 30.0, 75.0, 90.0])
        assertStatusBarBitmap(image, points: CpuSparklineView.sparklinePointSize)
        XCTAssertFalse(image.isTemplate)
    }

    func testCpuSparklineViewMakeHogAndSparklineImage() {
        let image = CpuSparklineView.makeHogAndSparklineImage(samples: [15.0, 45.0, 60.0])
        assertStatusBarBitmap(image, points: CpuSparklineView.hogPointSize)
        XCTAssertFalse(image.isTemplate)
    }

    @MainActor
    func testMenuBarIgnoresSubPercentNoiseAndUnrelatedPublishes() {
        let store = makeIsolatedHogStore()
        let when = Date(timeIntervalSince1970: 1_800_000)
        applyMenuBar(store, cpu: 10.2, at: when)
        let revision = store.menuBarStatus.presentation.revision
        let rasters = store.menuBarStatus.rasterCount
        let image = store.menuBarStatus.presentation.image
        XCTAssertEqual(image?.size, MenuBarCpuBarsView.pointSize)

        applyMenuBar(store, cpu: 10.4, at: when)
        XCTAssertEqual(store.menuBarStatus.presentation.revision, revision)
        XCTAssertEqual(store.menuBarStatus.rasterCount, rasters)
        XCTAssertTrue(store.menuBarStatus.presentation.image === image)

        store.lastNotice = "Saved a note"
        XCTAssertEqual(store.menuBarStatus.presentation.revision, revision)
        XCTAssertTrue(store.menuBarStatus.presentation.image === image)

        applyMenuBar(store, cpu: 20, at: when)
        XCTAssertGreaterThan(store.menuBarStatus.presentation.revision, revision)
        XCTAssertFalse(store.menuBarStatus.presentation.image === image)
        assertStatusBarBitmap(store.menuBarStatus.presentation.image!, points: MenuBarCpuBarsView.pointSize)
    }

    @MainActor
    private func applyMenuBar(_ store: HogStore, cpu: Double, at date: Date) {
        var pulse = MachinePulse.empty
        pulse.cpuPercent = cpu
        pulse.sampledAt = date
        store.applyLayoutSnapshotForTest(
            Snapshot(pulse: pulse, processes: [], hasBaseline: true),
            cpuHistory: [cpu],
            diskSpace: DiskSpace(freeBytes: 120_000_000_000, totalBytes: 500_000_000_000)
        )
    }
}

func assertStatusBarBitmap(
    _ image: NSImage,
    points: NSSize,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let pixelsWide = Int((points.width * MenuBarBitmap.scale).rounded())
    let pixelsHigh = Int((points.height * MenuBarBitmap.scale).rounded())
    let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first {
        $0.pixelsWide == pixelsWide && $0.pixelsHigh == pixelsHigh
    }
    XCTAssertEqual(image.size, points, file: file, line: line)
    XCTAssertNotNil(rep, "status item image needs one \(pixelsWide)x\(pixelsHigh) bitmap", file: file, line: line)
    guard let rep, let data = rep.bitmapData else { return }
    let count = rep.bytesPerRow * rep.pixelsHigh
    var ink = false
    for index in 0..<count where data[index] != 0 {
        ink = true
        break
    }
    XCTAssertTrue(ink, "bitmap was allocated but nothing was drawn", file: file, line: line)
    XCTAssertLessThanOrEqual(rep.pixelsWide, Int(MenuBarBitmap.maxPointSize.width * MenuBarBitmap.scale), file: file, line: line)
    XCTAssertLessThanOrEqual(rep.pixelsHigh, Int(MenuBarBitmap.maxPointSize.height * MenuBarBitmap.scale), file: file, line: line)
}
