import XCTest

@testable import HogHunter

/// The dashboard's left rail: the host and the sections live together, so a
/// section can never be picked and then ignored.
final class DashboardNavigationTests: XCTestCase {

    /// The rail carries both hosts, in the order a person reads them.
    func testTheRailCarriesBothHosts() {
        XCTAssertEqual(HogHunterPanel.HostScope.allCases.map(\.rawValue),
                       ["This Mac", "Server"])
    }

    /// Every section answers for the server, and no two sections answer with
    /// the same readings.  The old behaviour showed one card for Overview and
    /// for Storage alike, so choosing a section looked like it did nothing.
    func testEveryServerSectionHasItsOwnAnswer() {
        XCTAssertNil(HogHunterPanel.serverSection(for: .network),
                     "the snapshot cannot answer the network section")
        let answered = PanelTab.allCases.compactMap { HogHunterPanel.serverSection(for: $0) }
        XCTAssertEqual(answered.count, PanelTab.allCases.count - 1)
        XCTAssertEqual(answered.count, Set(answered).count,
                       "two sections answer with the same readings")
    }

    /// A section shows the readings it owns and not the ones next door.
    func testServerSectionsOwnTheirReadings() {
        XCTAssertTrue(VPSResourceSection.activity.showsHeadline)
        XCTAssertFalse(VPSResourceSection.activity.showsDevices)
        XCTAssertFalse(VPSResourceSection.activity.showsTools)

        XCTAssertTrue(VPSResourceSection.storage.showsDevices)
        XCTAssertTrue(VPSResourceSection.storage.showsDatabases)
        XCTAssertTrue(VPSResourceSection.storage.showsDirectories)
        XCTAssertFalse(VPSResourceSection.storage.showsHeadline)
        XCTAssertFalse(VPSResourceSection.storage.showsTools)

        XCTAssertTrue(VPSResourceSection.maintenance.showsTools)
        XCTAssertFalse(VPSResourceSection.maintenance.showsHeadline)
        XCTAssertFalse(VPSResourceSection.maintenance.showsDevices)

        XCTAssertTrue(VPSResourceSection.all.showsHeadline)
        XCTAssertTrue(VPSResourceSection.all.showsTools)
    }
}

/// Every volume is said the same way, and every activity row says both
/// numbers.
final class VolumeAndActivityCaptionTests: XCTestCase {

    /// The internal disk and an external drive read the same shape: how much
    /// of the volume is spoken for, and how much room is left.
    func testEveryVolumeIsSaidTheSameWay() {
        let internalCaption = HogFormat.capacity(usedPercent: 96.3, freeBytes: 17_000_000_000)
        let externalCaption = HogFormat.capacity(usedPercent: 69.0, freeBytes: 145_400_000_000)
        XCTAssertEqual(internalCaption, "96% used · 15.8 GB free")
        XCTAssertEqual(externalCaption, "69% used · 135.4 GB free")
        for caption in [internalCaption, externalCaption] {
            XCTAssertTrue(caption.contains("% used · "), caption)
            XCTAssertTrue(caption.hasSuffix(" free"), caption)
        }
    }

    /// A volume that cannot be read says so instead of guessing.
    func testAVolumeThatCannotBeRead() {
        XCTAssertEqual(HogFormat.capacity(usedPercent: nil, freeBytes: nil), "Unavailable")
    }

    /// The activity row carries the memory the app is holding as well as the
    /// CPU it is using.
    func testTheActivityRowCarriesCpuAndMemory() {
        let row = HogActivityRow(name: "ChatGPT", cpuText: "13.4%", memoryText: "1.2 GB")
        XCTAssertTrue(row.accessibilityLabel.contains("13.4%"), row.accessibilityLabel)
        XCTAssertTrue(row.accessibilityLabel.contains("1.2 GB"), row.accessibilityLabel)
    }
}
