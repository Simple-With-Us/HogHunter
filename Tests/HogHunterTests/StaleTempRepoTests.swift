import XCTest
@testable import HogHunter

/// Stale temp repo copies: git checkouts in the temp root that are provably
/// redundant.  The verdict is pure and driven here by canned probes; the scan
/// tests use fixture directories with an injected probe provider, mirroring
/// the temp-file fixtures in DiskCleanerTests.
final class StaleTempRepoTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HogHunterTest_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    /// Model old dates the way the temp-file fixtures do: latestActivity is
    /// the (fixture-set) modification date, not the real clock's ctime/atime.
    private static func fixtureMetadata(_ url: URL) throws -> TempEntryMetadata {
        var info = try TempEntryMetadata.read(url)
        info.latestActivity = info.modified
        return info
    }

    private func redundantProbe() -> DiskCleaner.TempRepoProbe {
        DiskCleaner.TempRepoProbe(
            headContainedByRemoteBranch: true,
            unpushedCommitCount: 0,
            diffNumstat: "",
            untrackedTopLevelNames: [])
    }

    // MARK: - Category metadata

    func testStaleTempReposCategoryMetadata() {
        let cat = CleanCategory.staleTempRepos
        XCTAssertEqual(cat.id, "staleTempRepos")
        XCTAssertEqual(cat.title, "Stale Temp Repo Copies")
        XCTAssertFalse(cat.description.isEmpty)
        XCTAssertFalse(cat.icon.isEmpty)
        XCTAssertEqual(cat.sortOrder, 11)
        XCTAssertFalse(cat.defaultSelected, "Repo copies must require explicit per-item review")
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(cat), "Repo copies are Extreme tier only")
        XCTAssertTrue(CleanTier.extreme.isCategoryIncluded(cat))
    }

    func testStaleTempReposRuleMapping() {
        XCTAssertTrue(CleanRegimenRunner.scanCategories(for: ["temp-repos"]).contains(.staleTempRepos))
        XCTAssertFalse(CleanRegimenRunner.scanCategories(for: ["tmp-files"]).contains(.staleTempRepos),
                       "the temp-files rule must not silently sweep repo copies")
        XCTAssertFalse(CleanRegimenRunner.scanCategories(for: ["xcode-artifacts"]).contains(.staleTempRepos))
    }

    // MARK: - Verdict (pure)

    func testVerdictAcceptsVerifiedRedundantCopy() {
        var probe = redundantProbe()
        probe.diffNumstat = "0\t0\tmode-only.sh\n0\t12\tdeleted-file.txt"
        probe.untrackedTopLevelNames = ["node_modules", "dist"]
        XCTAssertTrue(DiskCleaner.tempRepoIsRedundant(probe),
                      "mode-only churn, pure deletions, and build-output untracked dirs carry no unique content")
    }

    func testVerdictRejectsHeadNotOnRemote() {
        var probe = redundantProbe()
        probe.headContainedByRemoteBranch = false
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(probe))
    }

    func testVerdictRejectsUnpushedCommits() {
        var probe = redundantProbe()
        probe.unpushedCommitCount = 1
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(probe))
    }

    func testVerdictRejectsContentChanges() {
        var probe = redundantProbe()
        probe.diffNumstat = "3\t1\tSources/App.swift"
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(probe))
    }

    func testVerdictRejectsBinaryDiffs() {
        var probe = redundantProbe()
        probe.diffNumstat = "-\t-\timage.png"
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(probe),
                       "numstat cannot tell a binary deletion from a binary modification, so it fails closed")
    }

    func testVerdictRejectsStrayUntrackedContent() {
        var probe = redundantProbe()
        probe.untrackedTopLevelNames = ["notes"]
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(probe))
    }

    // MARK: - Scan fixtures

    /// Builds a temp root holding one fixture per exclusion class.  Probes
    /// are keyed by directory name; a missing key models a failed git probe.
    private func makeRepoFixture() -> (DiskCleaner, URL) {
        let fm = FileManager.default
        let root = tempDirectory.appendingPathComponent("reporoot_\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-4 * 24 * 3600)

        func repo(_ name: String, stale: Bool, gitFile: Bool = false) -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try! fm.createDirectory(at: url, withIntermediateDirectories: true)
            if gitFile {
                try! "gitdir: /elsewhere".write(to: url.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            } else {
                try! fm.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
            }
            let payload = url.appendingPathComponent("payload.txt")
            try! "payload".write(to: payload, atomically: true, encoding: .utf8)
            if stale {
                try! fm.setAttributes([.modificationDate: old], ofItemAtPath: payload.path)
                try! fm.setAttributes([.modificationDate: old], ofItemAtPath: url.appendingPathComponent(".git").path)
                try! fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
            return url
        }

        let verified = repo("verified-copy", stale: true)
        _ = repo("fresh-copy", stale: false)
        _ = repo("dirty-copy", stale: true)
        _ = repo("unprobed-copy", stale: true)
        _ = repo("linked-worktree", stale: true, gitFile: true)
        let registered = repo("registered-worktree", stale: true)
        // A plain directory with no git metadata at all.
        let plain = root.appendingPathComponent("plain-dir", isDirectory: true)
        try! fm.createDirectory(at: plain, withIntermediateDirectories: true)

        // Probes are keyed by directory name: the scan enumerates the
        // resolved temp root (`/var` -> `/private/var`), so full-path keys
        // would depend on which path form each side resolved to.
        let probes: [String: DiskCleaner.TempRepoProbe] = [
            "verified-copy": redundantProbe(),
            "fresh-copy": redundantProbe(),
            "dirty-copy": DiskCleaner.TempRepoProbe(
                headContainedByRemoteBranch: true, unpushedCommitCount: 2,
                diffNumstat: "", untrackedTopLevelNames: []),
            "registered-worktree": redundantProbe(),
        ]
        _ = verified
        let cleaner = DiskCleaner(
            tempRootDirectory: root,
            worktreePathsProvider: { [registered.path] },
            tempMetadataProvider: Self.fixtureMetadata,
            tempRepoProbeProvider: { probes[$0.lastPathComponent] })
        return (cleaner, root)
    }

    func testScanStaleTempReposListsOnlyVerifiedStaleCopies() {
        let (cleaner, _) = makeRepoFixture()
        let items = cleaner.scanStaleTempRepos()
        XCTAssertEqual(items.map(\.title), ["verified-copy"])
        XCTAssertEqual(items.first?.category, .staleTempRepos)
        XCTAssertEqual(items.first?.isSelected, false, "repo copies are never pre-selected")
        XCTAssertGreaterThan(items.first?.bytes ?? 0, 0)
    }

    func testScanStaleTempReposEmptyRootScansClean() {
        let root = tempDirectory.appendingPathComponent("emptyreporoot_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleaner = DiskCleaner(tempRootDirectory: root, worktreePathsProvider: { [] },
                                  tempRepoProbeProvider: { _ in nil })
        XCTAssertTrue(cleaner.scanStaleTempRepos().isEmpty)
    }

    // MARK: - Delete-time safety

    func testIsSafeToDeleteRevalidatesStaleTempRepos() {
        let (cleaner, root) = makeRepoFixture()
        let verified = root.appendingPathComponent("verified-copy")
        XCTAssertTrue(cleaner.isSafeToDelete(url: verified, category: .staleTempRepos),
                      "a copy that still passes the verdict at delete time is deletable")
        XCTAssertFalse(cleaner.isSafeToDelete(url: root.appendingPathComponent("dirty-copy"), category: .staleTempRepos),
                       "a copy with unpushed commits is refused at delete time")
        XCTAssertFalse(cleaner.isSafeToDelete(url: root, category: .staleTempRepos),
                       "the temp root itself must never be deletable")
        XCTAssertFalse(cleaner.isSafeToDelete(url: URL(fileURLWithPath: "/tmp/elsewhere"), category: .staleTempRepos),
                       "paths outside the injected temp root must be rejected")
    }
}
