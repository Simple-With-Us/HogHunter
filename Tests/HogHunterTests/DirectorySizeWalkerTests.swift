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
