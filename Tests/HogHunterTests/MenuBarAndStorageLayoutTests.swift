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
    func testHogStoreDefaultsToHistoryBars() {
        let store = HogStore(startImmediately: false)
        XCTAssertEqual(store.menuBarLabelMode, .historyBars)
        XCTAssertTrue(store.menuBarHelp.contains("Last 14 minutes CPU history"))
    }

    @MainActor
    func testStorageViewInitializesWithShowModePickerFalse() {
        let maintain = MaintainStore()
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
}
