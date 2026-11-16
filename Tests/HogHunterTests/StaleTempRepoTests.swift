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
        XCTAssertFalse(CleanRegimenRunner.scanCategories(for: ["temp-repos"]).contains(.staleTempRepos))
        XCTAssertFalse(CleanRegimen.schedulableRules.contains("temp-repos"))
        XCTAssertFalse(CleanRegimenRunner.scanCategories(for: ["tmp-files"]).contains(.staleTempRepos),
                       "the temp-files rule must not silently sweep repo copies")
        XCTAssertFalse(CleanRegimenRunner.scanCategories(for: ["xcode-artifacts"]).contains(.staleTempRepos))
    }

    // MARK: - Verdict (pure)

    func testVerdictAcceptsVerifiedRedundantCopy() {
        var probe = redundantProbe()
        probe.diffNumstat = "0\t0\tmode-only.sh\n0\t12\tdeleted-file.txt"
        probe.untrackedTopLevelNames = []
        XCTAssertTrue(DiskCleaner.tempRepoIsRedundant(probe),
                      "mode-only churn and pure deletions carry no unique content")
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

    func testArtifactNamesNeverWaiveUntrackedOrIgnoredWork() {
        for path in ["build", "build/notes.txt", "node_modules/unique.txt", ".cache/key", "dist/a\nb"] {
            var probe = redundantProbe()
            probe.untrackedTopLevelNames = [path]
            XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(probe), path)
        }
    }

    func testSuccessfulEmptyCommandIsAnEmptyInventoryNotFailure() {
        XCTAssertEqual(CleanerScanCommand.run(executable: "/usr/bin/true", arguments: []), Data())
        XCTAssertNil(CleanerScanCommand.run(executable: "/usr/bin/false", arguments: []))
    }

    func testDefaultProbeRefusesIgnoredAndUntrackedContentInTrackedArtifactFolders() throws {
        let repo = tempDirectory.appendingPathComponent("git-fixture")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        try git(["init"])
        try git(["config", "user.email", "fixture@invalid.test"])
        try git(["config", "user.name", "Fixture"])
        let build = repo.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "tracked".write(to: build.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "fixture"])
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        XCTAssertTrue(DiskCleaner.tempRepoIsRedundant(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo))))
        try "unique".write(to: build.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo))))
        try FileManager.default.removeItem(at: build.appendingPathComponent("notes.txt"))
        try "unique".write(to: repo.appendingPathComponent("ignored"), atomically: true, encoding: .utf8)
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo))))
    }

    func testDefaultProbeProtectsTagDetachedAndReflogOnlyCommits() throws {
        let repo = tempDirectory.appendingPathComponent("unique-ref-fixture")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        try git(["init"])
        try git(["config", "user.email", "fixture@invalid.test"])
        try git(["config", "user.name", "Fixture"])
        try git(["commit", "--allow-empty", "-m", "remote baseline"])
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        XCTAssertTrue(DiskCleaner.tempRepoIsRedundant(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo))))
        try git(["checkout", "--detach"])
        try git(["commit", "--allow-empty", "-m", "unique detached work"])
        XCTAssertGreaterThan(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo)).unpushedCommitCount, 0)
        try git(["tag", "unique-only-tag"])
        try git(["checkout", "--detach", "refs/remotes/origin/main"])
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo))))
        try git(["tag", "-d", "unique-only-tag"])
        // Even after the tag goes away, HEAD's reflog is recovery content.
        XCTAssertFalse(DiskCleaner.tempRepoIsRedundant(try XCTUnwrap(DiskCleaner.defaultTempRepoProbe(repo))))
    }

    func testNoUnattendedRuleCanConsumeStaleRepoItems() {
        let item = CleanItem(category: .staleTempRepos, title: "fixture", subtitle: "fixture",
                             url: tempDirectory, bytes: 1, fileCount: 1, lastModified: nil, isSelected: false)
        XCTAssertTrue(CleanRegimenRunner.pendingItems(from: [item], rules: ["temp-repos"]).items.isEmpty)
        XCTAssertTrue(CleanRegimenRunner.pendingItems(from: [item], rules: Set(CleanRegimen.schedulableRules)).items.isEmpty)
    }

    func testRecentGitAccessStillRefusesRevalidationRatherThanWaivingActivitySafety() {
        let (cleaner, root) = makeRepoFixture()
        let repo = root.appendingPathComponent("verified-copy")
        XCTAssertTrue(cleaner.isSafeToDelete(url: repo, category: .staleTempRepos))
        // Model the access side effect without reading a live user repository.
        let guarded = DiskCleaner(tempRootDirectory: root, worktreePathsProvider: { [] },
            tempMetadataProvider: { url in
                var info = try Self.fixtureMetadata(url)
                if url.path.contains("/.git") { info.latestActivity = Date() }
                return info
            }, tempRepoProbeProvider: { _ in self.redundantProbe() })
        XCTAssertFalse(guarded.isSafeToDelete(url: repo, category: .staleTempRepos))
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
