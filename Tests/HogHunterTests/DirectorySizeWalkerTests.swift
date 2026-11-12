import XCTest
import Darwin
@testable import HogHunter

final class DirectorySizeWalkerTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func allocated(_ path: String) throws -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Int64(info.st_blocks) * 512
    }

    private final class MetadataReads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private var starts = 0
        func read(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        func started() { lock.lock(); starts += 1; lock.unlock() }
        var snapshot: ([String], Int) { lock.lock(); defer { lock.unlock() }; return (paths, starts) }
    }

    func testAutomaticPolicyRejectsExternalAndCustomMountsWithoutBlockingSystemData() {
        let allows = DirectorySizeWalker.automaticAccessPolicy(mountPaths: ["/", "/System/Volumes/Data", "/Users/test/mounted", "/Volumes/Backup"])
        for path in ["/Volumes", "/Volumes/Backup", "/Volumes/Backup/lanes", "/Users/test/mounted/Repo"] {
            XCTAssertFalse(allows(path), path)
        }
        for path in ["/Users/test/Code", "/System/Volumes/Data/Users/test", "/Users/test/mounted-other"] {
            XCTAssertTrue(allows(path), path)
        }
    }

    func testRootAliasAndLaneLinkAreGatedBeforeReadingProtectedTarget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = try XCTUnwrap(DirectorySizeWalker.canonicalPath(root.path)) + "/protected"
        let lanes = root.appendingPathComponent("lanes")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: lanes, withIntermediateDirectories: true)
        // The destination intentionally does not exist: no target metadata is needed to gate it.
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: protected + "/missing")
        try FileManager.default.createSymbolicLink(atPath: lanes.appendingPathComponent("external").path, withDestinationPath: protected)
        let reads = MetadataReads()
        let policy = DirectorySizeWalker.automaticAccessPolicy(mountPaths: [protected])
        for path in [alias.path, lanes.path, protected + "/direct"] {
            let walker = DirectorySizeWalker(path: path, startedAt: Date(), allowsPath: policy,
                                             willReadMetadata: { reads.read($0) })
            var result = walker.observation
            for _ in 0..<20 where result.failure == nil && !result.isComplete {
                result = walker.advance(maxEntries: 1, maxDuration: 1)
            }
            XCTAssertEqual(result.failure, DirectorySizeWalker.automaticAccessReason)
            XCTAssertFalse(result.retryAutomatically)
            XCTAssertFalse(result.isComplete)
        }
        XCTAssertFalse(reads.snapshot.0.contains { $0 == protected || $0.hasPrefix(protected + "/") })
    }

    @MainActor
    func testRepeatedTimerRefreshDoesNotRetryProtectedAliasAndManualClickRunsOnlyOnce() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent("protected")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: protected.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
        let reads = MetadataReads()
        let blocked = try XCTUnwrap(DirectorySizeWalker.canonicalPath(protected.path))
        let executor = DirectorySizeExecutor(makeWalker: { path, start, allowExternal in
            reads.started()
            return DirectorySizeWalker(path: path, startedAt: start,
                allowsPath: allowExternal ? { _ in true } : DirectorySizeWalker.automaticAccessPolicy(mountPaths: [blocked]),
                willReadMetadata: { reads.read($0) })
        })
        var now = Date()
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        history.record(host: "test", metric: "directory", path: alias.path, bytes: 123, sampledAt: now)
        let store = DirectoryUsageStore(history: history, candidates: [("Alias", alias.path)], host: "test", now: { now },
                                        pressure: { .normal }, idlePressure: { .normal }, executor: executor)
        for _ in 0..<4 {
            await store.refreshWhenIdle()
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(reads.snapshot.1, 1)
        XCTAssertFalse(reads.snapshot.0.contains { $0 == blocked || $0.hasPrefix(blocked + "/") })
        XCTAssertEqual(store.rows.first?.bytes, 123, "Retain the previous complete measurement")
        XCTAssertTrue(store.rows.first?.isUnavailable == true)
        XCTAssertTrue(store.rows.first?.requiresManualMeasurement == true)
        XCTAssertEqual(store.rows.first?.statusText, DirectorySizeWalker.automaticAccessReason)
        XCTAssertEqual(store.rows.first?.nextAttempt, .distantFuture)
        await store.measureNow(id: alias.path)
        XCTAssertEqual(reads.snapshot.1, 2)
        XCTAssertEqual(store.rows.first?.statusText, "Complete")
        XCTAssertEqual(store.rows.first?.nextAttempt, .distantFuture)
        now = now.addingTimeInterval(3600)
        await store.refreshWhenIdle()
        XCTAssertEqual(reads.snapshot.1, 2, "A manual measurement must never authorize later automatic walks")
    }

    func testResumesWithoutRepeatingPrefixAndCountsPhysicalHardLinksOnce() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data")
        try Data(repeating: 7, count: 8192).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hard-link"))
        let walker = DirectorySizeWalker(path: root.path, startedAt: Date())
        var previous = 0
        var result = walker.observation
        for _ in 0..<20 {
            result = walker.advance(maxEntries: 1, maxDuration: 1)
            XCTAssertGreaterThanOrEqual(result.entries, previous)
            XCTAssertLessThanOrEqual(result.entries - previous, previous == 0 ? 2 : 1)
            previous = result.entries
            if result.isComplete { break }
        }
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries, 2, "A hard-linked file consumes disk blocks once")
        XCTAssertEqual(result.bytes, try allocated(root.path) + allocated(file.path))
        XCTAssertEqual(walker.advance(maxEntries: 1).bytes, result.bytes)
    }

    func testLaneLayoutAliasesAndAncestorTargetsDoNotDoubleCountOrLoop() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = root.appendingPathComponent("lanes")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: lanes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let file = external.appendingPathComponent("data")
        try Data(repeating: 3, count: 4096).write(to: file)
        let first = lanes.appendingPathComponent("one")
        let second = lanes.appendingPathComponent("two")
        let ancestor = lanes.appendingPathComponent("ancestor")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: root)
        let walker = DirectorySizeWalker(path: lanes.path, startedAt: Date())
        var result = walker.observation
        for _ in 0..<30 {
            result = walker.advance(maxEntries: 1, maxDuration: 1)
            if result.isComplete { break }
        }
        XCTAssertTrue(result.isComplete)
        let paths = [lanes, first, second, ancestor, external, file]
        XCTAssertEqual(result.bytes, try paths.reduce(Int64(0)) { try $0 + allocated($1.path) })
    }

    func testParentCoverageDoesNotHideExplicitMountedDescendant() {
        let roots: [String: dev_t] = ["/external/parent": 10]
        XCTAssertTrue(DirectorySizeWalker.isCovered(path: "/external/parent/child", device: 10, roots: roots))
        XCTAssertFalse(DirectorySizeWalker.isCovered(path: "/external/parent/mounted-child", device: 11, roots: roots),
                       "A parent walk stays on device 10, so an explicit device 11 root must still be walked")
        XCTAssertFalse(DirectorySizeWalker.isCovered(path: "/external/parent-other", device: 10, roots: roots))
    }

    func testCanonicalRootIsPhysicalAndRootAliasesCanBeMeasured() throws {
        // Inspect only root metadata on the real Mac; never traverse its temporary files.
        let physical = try XCTUnwrap(DirectorySizeWalker.canonicalPath("/private/tmp"))
        XCTAssertEqual(DirectorySizeWalker.canonicalPath("/tmp"), physical)
        var info = stat()
        XCTAssertEqual(lstat(physical, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)

        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let result = DirectorySizeWalker(path: alias.path, startedAt: Date()).advance(maxDuration: 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.path, DirectorySizeWalker.canonicalPath(target.path))
        XCTAssertEqual(result.bytes, try allocated(target.path))
    }

    func testRenamingOpenedRootInvalidatesIncompleteWalk() throws {
        let root = try fixture()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        for index in 0..<3 {
            try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent(String(index)))
        }
        let walker = DirectorySizeWalker(path: root.path, startedAt: Date())
        XCTAssertFalse(walker.advance(maxEntries: 1, maxDuration: 1).isComplete)
        try FileManager.default.moveItem(at: root, to: moved)
        let result = walker.advance(maxDuration: 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.failure)
        XCTAssertNil(result.finishedAt, "A renamed open root must not enter complete history")
    }

    func testRetargetedSymlinkRootRejectsCompletedWalk() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let target = root.appendingPathComponent("new")
        let link = root.appendingPathComponent("lanes")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(repeating: 1, count: 4096).write(to: old.appendingPathComponent(String(index)))
            try Data(repeating: 2, count: 4096).write(to: target.appendingPathComponent(String(index)))
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        let walker = DirectorySizeWalker(path: link.path, startedAt: Date())
        XCTAssertFalse(walker.advance(maxEntries: 1, maxDuration: 1).isComplete)
        // The alias now names a different tree, yet every open frame still validates by inode.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var result = walker.observation
        for _ in 0..<30 {
            result = walker.advance(maxEntries: 1, maxDuration: 1)
            if result.failure != nil || result.finishedAt != nil { break }
        }
        XCTAssertEqual(result.path, DirectorySizeWalker.canonicalPath(old.path))
        XCTAssertNil(result.finishedAt, "A retargeted alias must not publish the old target's total")
        XCTAssertNotNil(result.failure)
        XCTAssertFalse(result.isComplete)
    }

    func testRetargetedExternalLaneLinkRejectsCompletedAggregate() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = root.appendingPathComponent("lanes")
        let old = root.appendingPathComponent("old")
        let target = root.appendingPathComponent("new")
        for url in [lanes, old, target] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 4096).write(to: old.appendingPathComponent("data"))
        let link = lanes.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        let walker = DirectorySizeWalker(path: lanes.path, startedAt: Date())
        XCTAssertFalse(walker.advance(maxEntries: 1, maxDuration: 1).isComplete)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var result = walker.observation
        for _ in 0..<30 {
            result = walker.advance(maxEntries: 1, maxDuration: 1)
            if result.failure != nil || result.finishedAt != nil { break }
        }
        XCTAssertNotNil(result.failure)
        XCTAssertNil(result.finishedAt)
        XCTAssertFalse(result.isComplete)
    }

    func testCoveredLayoutAliasesAreStillValidatedBeforeCompletion() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = root.appendingPathComponent("lanes")
        let external = root.appendingPathComponent("external")
        let file = root.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: lanes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 8192).write(to: external.appendingPathComponent("data"))
        try Data([1]).write(to: file)
        let link = lanes.appendingPathComponent("alias")
        for target in [lanes, root, file] {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let walker = DirectorySizeWalker(path: lanes.path, startedAt: Date())
            let first = walker.advance(maxEntries: 1, maxDuration: 1)
            XCTAssertNil(first.failure)
            XCTAssertFalse(first.isComplete)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            var result = first
            for _ in 0..<100 where result.failure == nil && !result.isComplete {
                result = walker.advance(maxEntries: 1, maxDuration: 1)
            }
            XCTAssertNotNil(result.failure, target.path)
            XCTAssertFalse(result.isComplete)
            try FileManager.default.removeItem(at: link)
        }
    }

    func testMissingExternalLaneTargetDoesNotPublishSmallerAggregate() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = root.appendingPathComponent("lanes")
        try FileManager.default.createDirectory(at: lanes, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lanes.appendingPathComponent("external"),
                                                 withDestinationURL: root.appendingPathComponent("unavailable"))
        let result = DirectorySizeWalker(path: lanes.path, startedAt: Date()).advance(maxDuration: 1)
        XCTAssertTrue(result.hasResolvedRoot)
        XCTAssertNotNil(result.failure)
        XCTAssertNil(result.finishedAt)
        XCTAssertFalse(result.isComplete)
    }

    func testOverlappingExternalRootPartitionsCountExtraParentDataOnce() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = root.appendingPathComponent("lanes")
        let parent = root.appendingPathComponent("external")
        let child = parent.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: lanes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let data = child.appendingPathComponent("data")
        let extra = parent.appendingPathComponent("extra")
        try Data(repeating: 3, count: 4096).write(to: data)
        try Data(repeating: 4, count: 4096).write(to: extra)
        let childLink = lanes.appendingPathComponent("child")
        let parentLink = lanes.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: childLink, withDestinationURL: child)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parent)
        let walker = DirectorySizeWalker(path: lanes.path, startedAt: Date())
        var result = walker.observation
        for _ in 0..<30 {
            result = walker.advance(maxEntries: 1, maxDuration: 1)
            if result.isComplete { break }
        }
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.bytes, try [lanes, parent, child, data, extra, childLink, parentLink].reduce(Int64(0)) { try $0 + allocated($1.path) })
    }

    @MainActor
    func testCachedLogicalAliasRetainsSourceIdentityAcrossRetargeting() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let target = root.appendingPathComponent("new")
        let link = root.appendingPathComponent("lanes")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let now = Date()
        let logicalAlias = link.path + "/./"
        let history = SizeGrowthHistory(fileURL: nil)
        history.record(host: "mac-local", metric: "directory", path: link.path, bytes: 123,
                       sampledAt: now.addingTimeInterval(-60), sourcePath: old.path)
        let store = DirectoryUsageStore(history: history, candidates: [("Lanes", logicalAlias)], pressure: { .normal })
        XCTAssertEqual(store.rows.first?.bytes, 123)
        XCTAssertEqual(store.rows.first?.path, old.path)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.rows.first?.path, DirectorySizeWalker.canonicalPath(target.path))
        XCTAssertEqual(store.rows.first?.bytes, try allocated(target.path))
        let reopened = DirectoryUsageStore(history: history, candidates: [("Lanes", logicalAlias)], pressure: { .normal })
        XCTAssertEqual(reopened.rows.first?.bytes, try allocated(target.path))
        XCTAssertEqual(reopened.rows.first?.path, DirectorySizeWalker.canonicalPath(target.path))
    }

    func testRepositorySymlinksRemainLeavesAndMissingRootsFailHonestly() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8192).write(to: external.appendingPathComponent("data"))
        let link = tree.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let result = DirectorySizeWalker(path: tree.path, startedAt: Date()).advance(maxDuration: 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.bytes, try allocated(tree.path) + allocated(link.path))
        let missing = DirectorySizeWalker(path: root.appendingPathComponent("missing").path, startedAt: Date()).advance()
        XCTAssertFalse(missing.isComplete)
        XCTAssertNotNil(missing.failure)
    }

    func testRefreshCadenceUsesStartAndSkipsMissedSlotsWithoutOverlap() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(DirectoryUsageStore.nextScheduledAttempt(startedAt: start, now: start.addingTimeInterval(60)), start.addingTimeInterval(900))
        XCTAssertEqual(DirectoryUsageStore.nextScheduledAttempt(startedAt: start, now: start.addingTimeInterval(901)), start.addingTimeInterval(1800))
        XCTAssertEqual(DirectoryUsageStore.nextScheduledAttempt(startedAt: start, now: start.addingTimeInterval(3601)), start.addingTimeInterval(4500))
    }

    func testIdleGateRequiresNormalPressureLowLoadAndAvailableSwap() {
        XCTAssertEqual(DirectoryUsageStore.idlePressure(base: .normal, load: 3.9, swapUsedPercent: 89, processorCount: 8), .normal)
        XCTAssertNotEqual(DirectoryUsageStore.idlePressure(base: .normal, load: 4, swapUsedPercent: 89, processorCount: 8), .normal)
        XCTAssertNotEqual(DirectoryUsageStore.idlePressure(base: .normal, load: 1, swapUsedPercent: 90, processorCount: 8), .normal)
        XCTAssertNotEqual(DirectoryUsageStore.idlePressure(base: .reduced, load: 1, swapUsedPercent: 1, processorCount: 8), .normal)
        XCTAssertNotEqual(DirectoryUsageStore.idlePressure(base: .normal, load: nil, swapUsedPercent: 1, processorCount: 8), .normal)
        XCTAssertEqual(DirectoryUsageStore.idlePressure(base: .paused("Critical"), load: 1, swapUsedPercent: 1, processorCount: 8), .paused("Critical"))
    }

    @MainActor
    func testIdleContinuationAndSamplerStopGateNewWork() async {
        var idle: DirectoryUsageStore.Pressure = .paused("Awaiting an idle Mac; progress retained")
        let store = DirectoryUsageStore(history: SizeGrowthHistory(fileURL: nil), candidates: [("Example", "/example")],
                                        probe: { _ in 321 }, pressure: { .normal }, idlePressure: { idle })
        await store.refreshWhenIdle()
        XCTAssertNil(store.rows.first?.bytes)
        XCTAssertTrue(store.rows.first?.statusText.hasPrefix("Awaiting") == true)
        idle = .normal
        store.setMeasurementEnabled(false)
        await store.refreshWhenIdle()
        XCTAssertNil(store.rows.first?.bytes)
        store.setMeasurementEnabled(true)
        await store.refreshIfNeeded(force: true, background: true)
        XCTAssertEqual(store.rows.first?.bytes, 321)
    }

    @MainActor
    func testCriticalPressureDoesNotStartIOAndKeepsLastCompleteValue() async {
        let now = Date()
        let history = SizeGrowthHistory(fileURL: nil, now: { now })
        history.record(host: "test", metric: "directory", path: "/example", bytes: 123, sampledAt: now)
        let store = DirectoryUsageStore(history: history, candidates: [("Example", "/example")], host: "test", now: { now },
                                        probe: { _ in XCTFail("Pressure must gate all new I/O"); return 999 },
                                        pressure: { .paused("Paused for critical system pressure; progress retained") })
        await store.refreshIfNeeded()
        XCTAssertEqual(store.rows.first?.bytes, 123)
        XCTAssertEqual(store.nextRefreshDelay, 15)
        XCTAssertTrue(store.rows.first?.statusText.hasPrefix("Paused") == true)
    }

    @MainActor
    func testSmallDirectoryFinishesBeforeLargeDirectoryAndPartialNeverEntersHistory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large")
        let small = root.appendingPathComponent("small")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        // Tiny metadata-only fixtures; no production root is traversed by this test.
        for index in 0..<512 { FileManager.default.createFile(atPath: large.appendingPathComponent(String(index)).path, contents: nil) }
        let history = SizeGrowthHistory(fileURL: nil)
        let store = DirectoryUsageStore(history: history, candidates: [("Large", large.path), ("Small", small.path)], pressure: { .reduced })
        await store.refreshIfNeeded()
        XCTAssertNotNil(store.rows.first(where: { $0.title == "Small" })?.bytes)
        XCTAssertNil(store.rows.first(where: { $0.title == "Large" })?.bytes)
        XCTAssertNil(history.latest(host: "mac-local", metric: "directory", path: large.path))
        let progress = store.rows.first(where: { $0.title == "Large" })?.progressEntries ?? 0
        let cancelled = Task { await store.refreshIfNeeded() }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(store.rows.first(where: { $0.title == "Large" })?.progressEntries, progress)
        for _ in 0..<4 where store.rows.first(where: { $0.title == "Large" })?.bytes == nil {
            await store.refreshIfNeeded()
        }
        XCTAssertGreaterThan(store.rows.first(where: { $0.title == "Large" })?.progressEntries ?? 0, progress)
        XCTAssertNotNil(store.rows.first(where: { $0.title == "Large" })?.bytes)
    }
}
