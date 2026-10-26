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
    func testHogStoreDefaultsToHistoryBars() {
        let store = makeIsolatedHogStore()
        XCTAssertEqual(store.menuBarLabelMode, .historyBars)
        XCTAssertTrue(store.menuBarHelp.contains("Last 14 minutes CPU history"))
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
}
