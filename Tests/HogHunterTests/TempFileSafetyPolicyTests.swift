import XCTest
@testable import HogHunter

final class TempFileSafetyPolicyTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let clock = Date(timeIntervalSince1970: 2_000_000_000)
    private var activity: [String: Date] = [:]
    private var worktrees: Set<String> = []
    private var failedMetadataPaths: Set<String> = []
    private var metadataObserver: ((URL) -> Void)?

    override func setUpWithError() throws {
        suite = "hoghunter.tests.temp-policy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    @discardableResult
    private func file(_ name: String, hours: Double = 96) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: url)
        activity[url.path] = clock.addingTimeInterval(-hours * 3_600)
        return url
    }

    private func cleaner(cap: Int = 25_000, deniedEnumerationPath: String? = nil,
                         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> DiskCleaner {
        DiskCleaner(tempRootDirectory: root, worktreePathsProvider: { self.worktrees },
            tempPolicyProvider: { TempFileSafetyPolicy.load(from: self.defaults) },
            tempMetadataProvider: { url in
                self.metadataObserver?(url)
                if self.failedMetadataPaths.contains(url.path) { throw CocoaError(.fileReadNoPermission) }
                var info = try TempEntryMetadata.read(url)
                info.latestActivity = self.activity[url.path] ?? self.clock.addingTimeInterval(-96 * 3_600)
                return info
            }, tempNow: { self.clock }, tempEntryCap: cap, tempUptime: uptime,
            tempEnumerationProvider: { url, options, handler in
                if url.path == deniedEnumerationPath {
                    _ = handler?(url, CocoaError(.fileReadNoPermission))
                    return nil
                }
                return FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: options, errorHandler: handler)
            })
    }

    func testDefaultOmits24Through71HoursEvenAsUncheckedRows() throws {
        for hour in [24, 48, 71, 72, 96] { try file("age-\(hour).bin", hours: Double(hour)) }
        let items = cleaner().scanTempFiles()
        XCTAssertEqual(Set(items.map(\.title)), ["age-72.bin", "age-96.bin"])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected && $0.detail?.contains("72") == true })
    }

    func testConfiguredHoursApplyBeforeSuggestionsAndDeletion() throws {
        let young = try file("age-48.bin", hours: 48)
        TempFileSafetyPolicy.save(hours: 24, to: defaults)
        XCTAssertEqual(cleaner().scanTempFiles().count, 1)
        TempFileSafetyPolicy.save(hours: 168, to: defaults)
        XCTAssertTrue(cleaner().scanTempFiles().isEmpty)
        XCTAssertFalse(cleaner().isSafeToDelete(url: young, category: .tempFiles))
    }

    func testInvalidOrCorruptValuesUseSafeDefault() {
        XCTAssertEqual(TempFileSafetyPolicy.load(from: defaults).minimumUntouchedHours, 72)
        for value in [0, -1, 8_761, 1.5, Double.nan, Double.infinity, "1", true, Data()] as [Any] {
            defaults.set(value, forKey: TempFileSafetyPolicy.defaultsKey)
            XCTAssertEqual(TempFileSafetyPolicy.load(from: defaults).minimumUntouchedHours, 72)
        }
        XCTAssertEqual(TempFileSafetyPolicy.save(hours: .nan, to: defaults).minimumUntouchedHours, 72)
        XCTAssertEqual(TempFileSafetyPolicy.save(hours: 1, to: defaults).minimumUntouchedHours, 1)
    }

    func testInvalidEditsRetainAnExistingStricterPolicy() {
        TempFileSafetyPolicy.save(hours: 168, to: defaults)
        for invalid in [0, -1, 8_761, 1.5, Double.nan, Double.infinity] {
            XCTAssertEqual(TempFileSafetyPolicy.save(hours: invalid, to: defaults).minimumUntouchedHours, 168)
            XCTAssertEqual(TempFileSafetyPolicy.load(from: defaults).minimumUntouchedHours, 168)
        }
    }

    func testNestedActivityIncludingCopiedAndAccessedFilesBlocksContainer() throws {
        let nested = try file("container/deep/data.bin")
        let engine = cleaner()
        XCTAssertEqual(engine.scanTempFiles().count, 1)
        // The injected activity represents mtime, creation, ctime, or file
        // access, whichever is newest; old parent mtime cannot override it.
        activity[nested.path] = clock
        XCTAssertTrue(engine.scanTempFiles().isEmpty)
        XCTAssertFalse(engine.isSafeToDelete(url: root.appendingPathComponent("container"), category: .tempFiles))
    }

    func testRealMetadataDoesNotTreatFreshlyCopiedOldMtimeAsUntouched() throws {
        let url = try file("copied.bin")
        let old = Date().addingTimeInterval(-100 * 3_600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let info = try TempEntryMetadata.read(url)
        XCTAssertGreaterThan(info.latestActivity, old)
        XCTAssertEqual(info.modified.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
    }

    func testNestedGitProjectsLocksAndStagingStayProtectedAtEveryAge() throws {
        for name in ["a/deep/.git", "b/deep/package.json", "c/deep/main.swift", "d/deep/preview.html",
                     "e/deep/fleet.lock", "f/deep/.batch-active", "g/vc-014/data.bin", "h/demo.xcodeproj/data.bin"] {
            try file(name, hours: 1_000)
        }
        let lane = try file("registered/deep/data.bin", hours: 1_000).deletingLastPathComponent()
        worktrees = [lane.path]
        try file("sentinel.bin", hours: 1_000)
        try file(".sentinel.bin.lock", hours: 1_000)
        XCTAssertTrue(cleaner().scanTempFiles().isEmpty)
    }

    func testNestedSymlinkNeverFollowsOutsideRoot() throws {
        let target = try file("outside.bin")
        let nested = try file("container/deep/data.bin")
        try FileManager.default.createSymbolicLink(at: nested.deletingLastPathComponent().appendingPathComponent("link"), withDestinationURL: target)
        XCTAssertEqual(Set(cleaner().scanTempFiles().map(\.title)), ["outside.bin"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testMetadataFailureAndEntryCapFailClosed() throws {
        let nested = try file("container/deep/data.bin")
        XCTAssertTrue(cleaner(cap: 2).scanTempFiles().isEmpty)
        failedMetadataPaths.insert(nested.path)
        XCTAssertTrue(cleaner().scanTempFiles().isEmpty)
        XCTAssertFalse(cleaner().isSafeToDelete(url: root.appendingPathComponent("container"), category: .tempFiles))
    }

    func testDirectoryListingFailureFailsClosed() throws {
        let nested = try file("container/deep/data.bin")
        let denied = nested.deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertTrue(cleaner(deniedEnumerationPath: denied).scanTempFiles().isEmpty)
    }

    func testElapsedBudgetFailsClosed() throws {
        try file("container/deep/data.bin")
        var ticks: TimeInterval = 0
        XCTAssertTrue(cleaner(uptime: { ticks += 1; return ticks }).scanTempFiles().isEmpty)
    }

    func testProjectMarkerAddedDuringWalkRejectsCandidate() throws {
        try file("container/data.bin")
        let candidate = root.appendingPathComponent("container")
        var reads = 0
        metadataObserver = { url in
            if url == candidate {
                reads += 1
                if reads == 2 {
                    try! Data([1]).write(to: candidate.appendingPathComponent(".git"))
                    self.activity[candidate.path] = self.clock
                }
            }
        }
        XCTAssertTrue(cleaner().scanTempFiles().isEmpty)
    }

    func testMarkerAddedWhileChildrenAreReverifiedIsCaughtByParentLastCheck() throws {
        let nested = try file("container/deep/data.bin")
        let candidate = root.appendingPathComponent("container")
        var reads = 0
        metadataObserver = { entry in
            if entry == nested {
                reads += 1
                if reads == 2 {
                    try! Data([1]).write(to: candidate.appendingPathComponent(".git"))
                    self.activity[candidate.path] = self.clock
                }
            }
        }
        XCTAssertTrue(cleaner().scanTempFiles().isEmpty)
    }

    func testInodeReplacementDuringWalkRejectsCandidate() throws {
        let url = try file("data.bin")
        var reads = 0
        metadataObserver = { entry in
            if entry == url {
                reads += 1
                if reads == 2 {
                    // Atomic replacement retains the path but changes identity.
                    try! Data(repeating: 2, count: 4_096).write(to: url, options: .atomic)
                }
            }
        }
        XCTAssertTrue(cleaner().scanTempFiles().isEmpty)
    }

    func testCancelledTraversalReturnsNoSuggestions() async throws {
        try file("container/deep/data.bin")
        let engine = cleaner()
        let task = Task { () -> [CleanItem] in
            withUnsafeCurrentTask { $0?.cancel() }
            return engine.scanTempFiles()
        }
        let items = await task.value
        XCTAssertTrue(items.isEmpty)
    }

    func testStaleReportRefusesPolicyChangeRecentWriteAndNewProtection() async throws {
        let nested = try file("container/deep/data.bin")
        let engine = cleaner()
        let items = engine.scanTempFiles()
        XCTAssertEqual(items.count, 1)
        TempFileSafetyPolicy.save(hours: 168, to: defaults)
        let policyResult = await engine.clean(items: items, createSnapshot: false, exclusions: CleanerExclusions())
        XCTAssertEqual(policyResult.itemsRemoved, 0)
        TempFileSafetyPolicy.save(hours: 72, to: defaults)
        activity[nested.path] = clock
        let writeResult = await engine.clean(items: items, createSnapshot: false, exclusions: CleanerExclusions())
        XCTAssertEqual(writeResult.itemsRemoved, 0)
        activity[nested.path] = clock.addingTimeInterval(-96 * 3_600)
        try file("container/deep/.git")
        let gitResult = await engine.clean(items: items, createSnapshot: false, exclusions: CleanerExclusions())
        XCTAssertEqual(gitResult.itemsRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testForgedNestedItemCannotBypassParentProject() throws {
        let nested = try file("container/deep/data.bin")
        try file("container/package.json")
        XCTAssertFalse(cleaner().isSafeToDelete(url: nested, category: .tempFiles))
    }

    @MainActor
    func testSettingsChangeInvalidatesHiddenStoreWithoutStartingScan() async {
        let store = DiskCleanerStore(cleaner: cleaner(), historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults, rescanAfterExclusionChange: false)
        store.selectedItemIds = ["stale-selection"]
        store.showConfirmation = true
        TempFileSafetyPolicy.save(hours: 168, to: defaults)
        // Notification delivery runs on the main loop even without a view.
        for _ in 0..<100 where store.tempFilePolicy.minimumUntouchedHours != 168 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.tempFilePolicy.minimumUntouchedHours, 168)
        XCTAssertTrue(store.selectedItemIds.isEmpty)
        XCTAssertNil(store.report)
        XCTAssertFalse(store.showConfirmation)
        XCTAssertEqual(store.state, .idle)
    }
    @MainActor
    func testPolicyRoundTripInvalidatesHiddenStoreBeforeNotificationDelivery() {
        let store = DiskCleanerStore(cleaner: cleaner(), historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults, rescanAfterExclusionChange: false)
        store.selectedItemIds = ["stale-selection"]
        TempFileSafetyPolicy.save(hours: 168, to: defaults)
        TempFileSafetyPolicy.save(hours: 72, to: defaults)
        store.reloadTempFilePolicy()
        XCTAssertTrue(store.selectedItemIds.isEmpty)
        XCTAssertEqual(store.state, .idle)
    }

    @MainActor
    func testCleanDroppedByAPolicyChangeAsksForAScanInsteadOfReturningSilently() {
        let store = DiskCleanerStore(cleaner: cleaner(), historyStore: CleanupHistoryStore(inMemory: true),
            exclusionsDefaults: defaults, rescanAfterExclusionChange: false)
        // The phone edits the policy after the scan; the notification reaches
        // the store on the main loop, so this turn still sees the old report.
        TempFileSafetyPolicy.save(hours: 168, to: defaults)
        store.showConfirmation = true
        store.selectedItemIds = ["stale-selection"]

        store.cleanSelected(createSnapshot: false)

        XCTAssertNil(store.report)
        XCTAssertTrue(store.selectedItemIds.isEmpty)
        guard case .failed(let message) = store.state else {
            return XCTFail("a clean voided by a policy change must report why, not return silently")
        }
        XCTAssertTrue(message.contains("Scan again"))
    }

}
