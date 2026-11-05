import XCTest
@testable import HogHunter

private final class ListingRecorder: FileManager {
    var listed: [String] = []

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        listed.append(url.path)
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

final class DiskCleanerScanBudgetTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("HHScanBudget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ relative: String) throws -> URL {
        let url = sandbox.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 4096).write(to: url)
        return url
    }

    private func exclusions(keeping categories: [CleanCategory]) -> CleanerExclusions {
        var result = CleanerExclusions()
        result.excludedCategories = Set(CleanCategory.allCases.filter { !categories.contains($0) }.map(\.rawValue))
        return result
    }

    private func debugBuildsLane(_ name: String) throws -> URL {
        try write("Library/Caches/HogHunterDerivedData/\(name)/data.bin").deletingLastPathComponent()
    }

    private func debugBuildsRows(in report: CleanScanReport) -> [CleanItem] {
        report.categories.flatMap(\.items).filter { $0.title == "Hog Hunter Debug Builds" }
    }

    /// A partial scan stops the regimen recording a run, and it never selects this row,
    /// so a lane that cannot be sized exactly would hold the regimen in a retry forever.
    func testADebugBuildsRowOnlyALowerBoundDoesNotMakeTheScanPartial() async throws {
        let lane = try debugBuildsLane("lane-a")
        try FileManager.default.createSymbolicLink(at: lane.appendingPathComponent("link"),
                                                   withDestinationURL: lane.appendingPathComponent("data.bin"))
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.developer]))
        let row = try XCTUnwrap(debugBuildsRows(in: report).first)
        XCTAssertTrue(row.isApproximate, "the row still says its size is a lower bound")
        XCTAssertFalse(row.isSelected)
        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.incompleteCategories, [])
    }

    func testAnyOtherDeveloperRowOnlyALowerBoundStillMakesTheScanPartial() async throws {
        let cache = try write("Library/Caches/Yarn/data.bin").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("link"),
                                                   withDestinationURL: cache.appendingPathComponent("data.bin"))
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.developer]))
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.incompleteCategories, [.developer])
    }

    /// One real lane is past the 25,000 entry cap, against a quick scan's 30,000 in all.
    func testDebugBuildsRowsDoNotSpendTheScansEntryBudget() async throws {
        let fm = FileManager.default
        for (name, count) in [("lane-a", 25_010), ("lane-b", 5_100)] {
            let lane = try debugBuildsLane(name)
            for entry in 0..<count {
                XCTAssertTrue(fm.createFile(atPath: lane.appendingPathComponent("unit-\(entry)").path, contents: Data("x".utf8)))
            }
        }
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.developer]))
        XCTAssertEqual(debugBuildsRows(in: report).count, 2)
        XCTAssertFalse(report.isPartial)
    }

    /// The whole-lane walk can take 30 seconds against a quick scan's 8, so it belongs
    /// to the clean.  A marker the bounded walk cannot see shows the scan did not run it.
    func testTheScanLeavesTheWholeLaneWalkToTheClean() async throws {
        let lane = try debugBuildsLane("lane-marked")
        let deep = lane.appendingPathComponent("a/b/c/d/e/f/g/h", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: deep.appendingPathComponent(KeepSentinel.fileName).path, contents: Data()))
        XCTAssertFalse(KeepSentinel.containsMarker(url: lane))

        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.developer]))
        let row = try XCTUnwrap(debugBuildsRows(in: report).first)
        XCTAssertFalse(report.isPartial)
        XCTAssertFalse(cleaner.isSafeToDelete(url: lane, category: .developer))
        _ = await cleaner.clean(items: [row], createSnapshot: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lane.path), "the clean still walks the whole lane")
    }

    /// Below the lane's top level, so only the walk can see it: a marker on the lane
    /// itself is found by `isKept` and would pass with the walk gone.
    func testAMarkerTheBoundedWalkCanSeeStillHidesTheRow() async throws {
        let lane = try debugBuildsLane("lane-marked")
        let nested = lane.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appendingPathComponent(KeepSentinel.fileName).path, contents: Data()))
        XCTAssertFalse(KeepSentinel.isKept(url: lane))
        XCTAssertTrue(KeepSentinel.containsMarker(url: lane))
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.developer]))
        XCTAssertEqual(debugBuildsRows(in: report).count, 0)
    }

    /// Asked of the listing and not only the rows, because a listing through the link
    /// can come back empty on its own, and the refusal must not rest on that.
    func testASymlinkedDebugBuildsRootIsNeverListed() throws {
        let elsewhere = try write("elsewhere/lane-a/data.bin").deletingLastPathComponent().deletingLastPathComponent()
        let caches = sandbox.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("HogHunterDerivedData"), withDestinationURL: elsewhere)
        let recorder = ListingRecorder()
        let cleaner = DiskCleaner(fileManager: recorder, scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        XCTAssertFalse(cleaner.scanDeveloper().contains { $0.title == "Hog Hunter Debug Builds" })
        XCTAssertFalse(recorder.listed.contains { $0.hasSuffix("/HogHunterDerivedData") }, "listed \(recorder.listed)")
    }

    /// The rows alone cannot tell: each lane's own measurement would refuse too, but
    /// only after the listing had already read the mounted folder.
    func testADebugBuildsRootTheScanGateRefusesIsNeverListed() throws {
        let root = try debugBuildsLane("lane-a").deletingLastPathComponent()
        let mount = try XCTUnwrap(DirectorySizeWalker.canonicalPath(root.path))
        let recorder = ListingRecorder()
        let cleaner = DiskCleaner(fileManager: recorder, scanUptime: { 0 }, mountPathsProvider: { [mount] }, homeDirectory: sandbox)
        XCTAssertFalse(cleaner.scanDeveloper().contains { $0.title == "Hog Hunter Debug Builds" })
        XCTAssertFalse(recorder.listed.contains { $0.hasSuffix("/HogHunterDerivedData") }, "listed \(recorder.listed)")
    }

    func testDepthLimitRetainsLowerBoundAndCannotProveAge() throws {
        _ = try write("root.bin")
        _ = try write("nested/deeper/data.bin")
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] })
        let partial = cleaner.directoryStats(at: sandbox, maxDepth: 1)
        let complete = cleaner.directoryStats(at: sandbox, maxDepth: 8)
        XCTAssertTrue(partial.isApproximate)
        XCTAssertNil(partial.lastModified)
        XCTAssertEqual(partial.fileCount, 1)
        XCTAssertLessThan(partial.bytes, complete.bytes)
        XCTAssertFalse(complete.isApproximate)
        XCTAssertEqual(complete.fileCount, 2)
        XCTAssertNotNil(complete.lastModified)
    }

    func testEmptyDirectoriesConsumeEntryBudget() throws {
        for index in 0..<8 {
            try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("empty\(index)"), withIntermediateDirectories: true)
        }
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] })
        let partial = cleaner.directoryStats(at: sandbox, fileCap: 2)
        XCTAssertTrue(partial.isApproximate)
        XCTAssertEqual(partial.fileCount, 0)
        XCTAssertNil(partial.lastModified)
    }

    func testPackagesAreMeasuredRatherThanSilentlySkipped() throws {
        _ = try write("Cache.app/Contents/payload.bin")
        let result = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }).directoryStats(at: sandbox)
        XCTAssertFalse(result.isApproximate)
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertGreaterThanOrEqual(result.bytes, 4096)
    }

    func testCooperativeTargetDeadlineProducesUnknownAge() throws {
        _ = try write("payload.bin")
        var reads = 0
        let cleaner = DiskCleaner(scanUptime: { reads += 1; return reads == 1 ? 0 : 1 }, mountPathsProvider: { [] })
        let result = cleaner.directoryStats(at: sandbox)
        XCTAssertTrue(result.isApproximate)
        XCTAssertNil(result.lastModified)
    }

    func testMountAliasIsRejectedBeforeMeasuringItsDestination() throws {
        let target = try write("fake-mount/data.bin").deletingLastPathComponent()
        let alias = sandbox.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let mount = try XCTUnwrap(DirectorySizeWalker.canonicalPath(target.path))
        let result = DiskCleaner(mountPathsProvider: { [mount] }).directoryStats(at: alias)
        XCTAssertTrue(result.isApproximate)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertNil(result.lastModified)
    }

    func testInternalAliasMeasuresTheTargetTree() throws {
        let target = try write("real-cache/data.bin").deletingLastPathComponent()
        let alias = sandbox.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let stats = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }).directoryStats(at: alias)
        XCTAssertFalse(stats.isApproximate)
        XCTAssertEqual(stats.fileCount, 1)
        XCTAssertGreaterThanOrEqual(stats.bytes, 4096)
    }

    func testPartialSimulatorSizeRetainsPrimaryDeviceIdentity() throws {
        let base = sandbox.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        for name in ["Primary", "Secondary"] {
            let path = "Library/Developer/CoreSimulator/Devices/\(name)/" + Array(repeating: "deep", count: 34).joined(separator: "/") + "/data.bin"
            _ = try write(path)
            let plist: [String: Any] = ["name": name, "UDID": name,
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "lastUsedAt": Date(timeIntervalSince1970: name == "Primary" ? 200 : 100)]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: base.appendingPathComponent("\(name)/device.plist"))
        }
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let devices = cleaner.scanSimulatorDevices(at: base)
        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(devices.allSatisfy(\.isApproximate))
        XCTAssertEqual(cleaner.primaryIOS27Simulator(in: devices)?.name, "Primary")
    }

    func testUnreadableSimulatorIdentityCannotInferPrimaryFromSubset() throws {
        let base = sandbox.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let plistURL = try write("Library/Developer/CoreSimulator/Devices/Unknown/device.plist")
        try Data("not a property list".utf8).write(to: plistURL)
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        XCTAssertTrue(cleaner.scanSimulatorDevices(at: base).isEmpty)
    }

    func testEarlierPartialContainerDoesNotHideCompleteSupportFolder() throws {
        _ = try write("Library/Containers/com.removed.partial/root.bin")
        _ = try write("Library/Containers/com.removed.partial/" + Array(repeating: "deep", count: 34).joined(separator: "/") + "/payload.bin")
        _ = try write("Library/Application Support/RemovedProduct/payload.bin")
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let apps = [StorageScanner.InstalledApp(bundleId: "com.fixture.installed", name: "Installed",
            url: sandbox.appendingPathComponent("Installed.app"), groupContainers: [])]
        let items = cleaner.scanOrphanedData(installedApps: apps)
        XCTAssertTrue(items.contains { $0.title == "com.removed.partial" && $0.isApproximate })
        XCTAssertTrue(items.contains { $0.title == "RemovedProduct" })
    }

    func testUnreadableSupportChildCannotEstablishOrphanIdentity() throws {
        _ = try write("Library/Application Support/UnknownProduct/payload.bin")
        let unread = sandbox.appendingPathComponent("Library/Application Support/UnknownProduct/unread-child")
        try FileManager.default.createSymbolicLink(at: unread, withDestinationURL: sandbox.appendingPathComponent("missing-target"))
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let apps = [StorageScanner.InstalledApp(bundleId: "com.fixture.installed", name: "Installed",
            url: sandbox.appendingPathComponent("Installed.app"), groupContainers: [])]
        XCTAssertFalse(cleaner.scanOrphanedData(installedApps: apps).contains { $0.title == "UnknownProduct" })
    }

    func testSyntheticSnapshotRowsSurviveFilesystemPreflight() async {
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] },
            listSnapshots: { _ in ["com.apple.TimeMachine.fixture"] }, purgeableProvider: { _ in 4096 })
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.apfsSnapshots]))
        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.totalBytes, 4096)
        XCTAssertEqual(report.categories.first?.items.count, 1)
    }

    func testUnavailableSnapshotListingIsMarkedPartial() async {
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] },
            listSnapshots: { _ in nil }, purgeableProvider: { _ in 4096 })
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.apfsSnapshots]))
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.incompleteCategories, [.apfsSnapshots])
        XCTAssertEqual(report.categories.first?.items.count, 1)
    }

    func testSelectedCategoriesCannotSpendBudgetOnDisabledDiscovery() async {
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: CleanerExclusions(), categories: [.logsAndDiagnostics])
        XCTAssertEqual(report.categories.map(\.category), [.logsAndDiagnostics])
    }

    func testScanCommandDeadlineStopsAnUnresponsiveChild() {
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(CleanerScanCommand.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testGlobalDeadlineReportsUnvisitedCategories() async {
        var reads = 0
        let cleaner = DiskCleaner(scanUptime: { reads += 1; return reads == 1 ? 0 : 100 },
            mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.userCaches, .logsAndDiagnostics]))
        XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.anyApproximate)
        XCTAssertTrue(report.categories.isEmpty)
        XCTAssertEqual(Set(report.incompleteCategories), Set([.userCaches, .logsAndDiagnostics]))
    }

    func testEachCategoryPublishesBeforeFinalReport() async throws {
        _ = try write("Library/Caches/Example/data.bin")
        _ = try write("Library/Logs/Example/log.bin")
        var partials: [CleanScanReport] = []
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let report = await cleaner.scan(exclusions: exclusions(keeping: [.userCaches, .logsAndDiagnostics]),
            partialReport: { partials.append($0) })
        XCTAssertEqual(partials.count, 2)
        XCTAssertEqual(partials.first?.categories.count, 1)
        XCTAssertTrue(partials.allSatisfy(\.isPartial))
        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.categories.count, 2)
        XCTAssertGreaterThan(report.totalBytes, 0)
    }

    func testNewScanDoesNotReuseOldRootModificationTime() async throws {
        let first = try write("Library/Caches/Example/old.bin")
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let policy = exclusions(keeping: [.userCaches])
        let before = await cleaner.scan(exclusions: policy)
        let root = first.deletingLastPathComponent()
        let oldRootDate = try FileManager.default.attributesOfItem(atPath: root.path)[.modificationDate]
        _ = try write("Library/Caches/Example/new.bin")
        // Directory mtime is not proof that nested sizes stayed the same.
        if let oldRootDate { try FileManager.default.setAttributes([.modificationDate: oldRootDate], ofItemAtPath: root.path) }
        let after = await cleaner.scan(exclusions: policy)
        XCTAssertGreaterThan(after.totalBytes, before.totalBytes)
    }

    func testOldParentCannotMakeAnIncompleteAIArtifactEligible() throws {
        let deepPath = ([".gemini", "antigravity", "brain", "old-session"] + Array(repeating: "deep", count: 34) + ["data.bin"]).joined(separator: "/")
        _ = try write(deepPath)
        let session = sandbox.appendingPathComponent(".gemini/antigravity/brain/old-session")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86400)], ofItemAtPath: session.path)
        let cleaner = DiskCleaner(scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        XCTAssertFalse(cleaner.scanAIArtifacts().contains { $0.url == session })
    }

    func testCancellationIsPartialAndCannotProveAge() async throws {
        _ = try write("payload.bin")
        let cleaner = DiskCleaner(mountPathsProvider: { [] })
        let root = sandbox!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return cleaner.directoryStats(at: root)
        }
        let result = await task.value
        XCTAssertTrue(result.isApproximate)
        XCTAssertNil(result.lastModified)
    }

    func testPartialPrimarySizeDoesNotBlockCleaningAnotherSimulator() async throws {
        let base = sandbox.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let primary = base.appendingPathComponent("Primary")
        let secondary = base.appendingPathComponent("Secondary")
        _ = try write("Library/Developer/CoreSimulator/Devices/Primary/" + Array(repeating: "deep", count: 34).joined(separator: "/") + "/payload.bin")
        _ = try write("Library/Developer/CoreSimulator/Devices/Secondary/payload.bin")
        for (url, used) in [(primary, 200.0), (secondary, 100.0)] {
            let plist: [String: Any] = ["name": url.lastPathComponent, "UDID": url.lastPathComponent,
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "lastUsedAt": Date(timeIntervalSince1970: used)]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("device.plist"))
        }
        let moved = sandbox.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let cleaner = DiskCleaner(freeBytesProvider: { nil }, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: moved.appendingPathComponent(url.lastPathComponent))
        }, scanUptime: { 0 }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        XCTAssertTrue(cleaner.directoryStats(at: primary).isApproximate)
        let item = CleanItem(category: .developer, title: "Other simulators", subtitle: "Fixture",
            url: base, bytes: 999999, fileCount: 2, isApproximate: true, lastModified: nil, isSelected: true)
        let result = await cleaner.clean(items: [item], createSnapshot: false, exclusions: CleanerExclusions())
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.itemsRemoved, 1)
        XCTAssertGreaterThan(result.bytesReclaimed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Secondary").path))
    }

    func testMovingNestedLinkDoesNotCreditItsUntouchedTarget() async throws {
        let target = try write("Library/Caches/C/payload.bin").deletingLastPathComponent()
        let intermediate = sandbox.appendingPathComponent("Library/Caches/B")
        try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: true)
        let childLink = intermediate.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: childLink, withDestinationURL: target)
        let alias = sandbox.appendingPathComponent("Library/Caches/A")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: intermediate)
        let moved = sandbox.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let cleaner = DiskCleaner(freeBytesProvider: { nil }, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: moved.appendingPathComponent(url.lastPathComponent))
        }, mountPathsProvider: { [] }, homeDirectory: sandbox)
        let item = CleanItem(category: .userCaches, title: "Alias", subtitle: "Fixture",
            url: alias, bytes: 999999, fileCount: 1, lastModified: nil, isSelected: true, isSymlink: true)
        let result = await cleaner.clean(items: [item], createSnapshot: false, exclusions: CleanerExclusions())
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.itemsRemoved, 1)
        XCTAssertEqual(result.bytesReclaimed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("payload.bin").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.appendingPathComponent("link").path), target.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), intermediate.path)
    }

    func testSignedFreeSpaceObservationIsSeparateFromMovedBytes() async {
        var reads = 0
        let cleaner = DiskCleaner(freeBytesProvider: { reads += 1; return reads == 1 ? 1000 : 800 },
            makeSnapshot: { XCTFail("No snapshot for an empty clean"); return (false, nil) })
        let result = await cleaner.clean(items: [], createSnapshot: false, exclusions: CleanerExclusions())
        XCTAssertEqual(result.bytesReclaimed, 0)
        XCTAssertEqual(result.observedFreeBytesChange, -200)
        XCTAssertEqual(DiskCleaner.freeSpaceChange(before: 100, after: 150), 50)
        XCTAssertEqual(DiskCleaner.freeSpaceChange(before: 100, after: 100), 0)
        XCTAssertNil(DiskCleaner.freeSpaceChange(before: nil, after: 100))
        XCTAssertNil(DiskCleaner.freeSpaceChange(before: UInt64.max, after: 100))
    }
}
