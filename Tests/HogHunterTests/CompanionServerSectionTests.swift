import XCTest

/// Which rows each Server tab section shows, and how a screenshot flag or a
/// stored value picks the section.  The enum is Foundation-only, so these run
/// in the Mac test bundle without the phone app.
final class CompanionServerSectionTests: XCTestCase {
    private typealias Section = CompanionServerSection

    func testSectionsAreInMacDashboardOrder() {
        XCTAssertEqual(Section.allCases.map(\.rawValue), ["Overview", "Activity", "Storage", "Maintenance"])
    }

    func testOverviewShowsEveryPart() {
        let overview = Section.overview
        XCTAssertTrue(overview.showsActivityReadings)
        XCTAssertTrue(overview.showsProcesses)
        XCTAssertTrue(overview.showsWorkloads)
        XCTAssertTrue(overview.showsStorageReadings)
        XCTAssertTrue(overview.showsTools)
        XCTAssertTrue(overview.showsMaintenanceControls)
    }

    func testEachOtherSectionShowsOnlyItsOwnPart() {
        let activity = Section.activity
        XCTAssertTrue(activity.showsActivityReadings && activity.showsProcesses && activity.showsWorkloads)
        XCTAssertFalse(activity.showsStorageReadings || activity.showsTools || activity.showsMaintenanceControls)

        let storage = Section.storage
        XCTAssertTrue(storage.showsStorageReadings)
        XCTAssertFalse(storage.showsActivityReadings || storage.showsProcesses || storage.showsWorkloads
                       || storage.showsTools || storage.showsMaintenanceControls)

        let maintenance = Section.maintenance
        XCTAssertTrue(maintenance.showsTools && maintenance.showsMaintenanceControls)
        XCTAssertFalse(maintenance.showsActivityReadings || maintenance.showsProcesses
                       || maintenance.showsWorkloads || maintenance.showsStorageReadings)
    }

    func testEveryRowIsShownBySomeSection() {
        // A row no section shows would be unreachable from the picker.
        let parts: [(String, KeyPath<Section, Bool>)] = [
            ("activity", \.showsActivityReadings), ("processes", \.showsProcesses),
            ("workloads", \.showsWorkloads), ("storage", \.showsStorageReadings),
            ("tools", \.showsTools), ("controls", \.showsMaintenanceControls),
        ]
        for (name, path) in parts {
            XCTAssertTrue(Section.allCases.contains { $0[keyPath: path] }, "\(name) is shown nowhere")
        }
    }

    func testScreenshotFlagPicksTheSection() {
        XCTAssertEqual(Section.screenshotOverride(arguments: ["-HogHunterServerActivity"]), .activity)
        XCTAssertEqual(Section.screenshotOverride(arguments: ["app", "-HogHunterServerStorage"]), .storage)
        XCTAssertEqual(Section.screenshotOverride(arguments: ["-HogHunterServerMaintenance"]), .maintenance)
    }

    func testNoFlagLeavesTheStoredChoice() {
        XCTAssertNil(Section.screenshotOverride(arguments: []))
        XCTAssertNil(Section.screenshotOverride(arguments: ["-HogHunterSample"]))
    }

    func testStoredValueFallsBackToOverview() {
        XCTAssertEqual(Section.stored("Storage"), .storage)
        XCTAssertEqual(Section.stored("Maintenance"), .maintenance)
        XCTAssertEqual(Section.stored(""), .overview)
        XCTAssertEqual(Section.stored("storage"), .overview)
        XCTAssertEqual(Section.stored("Retired"), .overview)
    }

    func testDetailsAndControlsFramesWinOverAStoredSection() {
        XCTAssertEqual(CompanionServerSection.screenshotOverride(arguments: ["-HogHunterServerDetails"]), .overview)
        XCTAssertEqual(CompanionServerSection.screenshotOverride(arguments: ["-HogHunterServerControls"]), .overview)
        XCTAssertEqual(CompanionServerSection.screenshotOverride(arguments: ["-HogHunterServerStorage"]), .storage)
    }

    func testABareServerLaunchIsTheOverviewWhateverWasStored() {
        XCTAssertEqual(CompanionServerSection.screenshotOverride(arguments: ["-HogHunterServer"]), .overview)
        XCTAssertEqual(CompanionServerSection.screenshotOverride(arguments: ["-HogHunterServer", "-HogHunterServerStorage"]), .storage)
        XCTAssertNil(CompanionServerSection.screenshotOverride(arguments: []))
    }
}
