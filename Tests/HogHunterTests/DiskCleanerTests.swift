import XCTest
@testable import HogHunter

final class DiskCleanerTests: XCTestCase {
    var cleaner: DiskCleaner!
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        cleaner = DiskCleaner()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HogHunterTest_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    func testSharedVendorFoldersAreNotOrphans() {
        for name in ["Google", "Mozilla", "Microsoft", "MobileSync", "CrashReporter", "  google  "] {
            XCTAssertTrue(DiskCleaner.isSharedVendorContainer(name), name)
        }
        XCTAssertFalse(DiskCleaner.isSharedVendorContainer("com.removed.App"))
        XCTAssertFalse(DiskCleaner.isSharedVendorContainer("SomeUninstalledApp"))
        XCTAssertTrue(DiskCleaner.holdsInstalledProduct(
            childNames: ["Chrome"],
            knownBundleIds: ["com.google.chrome"],
            knownNames: ["chrome", "google chrome"]
        ))
        // Vendor/product layout: JetBrains/IntelliJIdea2024.2 and
        // BraveSoftware/Brave-Browser must match after normalization.
        XCTAssertTrue(DiskCleaner.holdsInstalledProduct(
            childNames: ["IntelliJIdea2024.2"],
            knownBundleIds: ["com.jetbrains.intellij"],
            knownNames: ["intellij", "intellij idea"]
        ))
        XCTAssertTrue(DiskCleaner.holdsInstalledProduct(
            childNames: ["Brave-Browser"],
            knownBundleIds: ["com.brave.Browser"],
            knownNames: ["browser", "brave browser"]
        ))
        XCTAssertFalse(DiskCleaner.holdsInstalledProduct(
            childNames: ["OldProduct"],
            knownBundleIds: ["com.google.chrome"],
            knownNames: ["chrome"]
        ))
    }

    func testScanOrphanedDataSkipsVendorAndInstalledProductFolders() {
        // The two `continue` guards in the Application Support scan must be
        // consulted by the scan itself, not just correct in isolation:
        // deleting either one reintroduces the data-loss path from issue #67.
        let fm = FileManager.default
        func makeAppSupportFolder(_ name: String, child: String) {
            let dir = tempDirectory
                .appendingPathComponent("Library/Application Support/\(name)/\(child)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "x".write(to: dir.appendingPathComponent("data.bin"), atomically: true, encoding: .utf8)
        }
        makeAppSupportFolder("Google", child: "Chrome")
        makeAppSupportFolder("JetBrains", child: "IntelliJIdea2024.2")
        makeAppSupportFolder("DefinitelyRemovedApp", child: "OldData")

        let cleaner = DiskCleaner(homeDirectory: tempDirectory)
        let apps = [StorageScanner.InstalledApp(bundleId: "com.jetbrains.intellij",
                                                name: "IntelliJ IDEA",
                                                url: nil,
                                                groupContainers: [])]
        let titles = Set(cleaner.scanOrphanedData(installedApps: apps).map(\.title))
        XCTAssertFalse(titles.contains("Google"), "shared vendor folder must not be listed as an orphan")
        XCTAssertFalse(titles.contains("JetBrains"), "folder holding an installed product must not be listed as an orphan")
        XCTAssertTrue(titles.contains("DefinitelyRemovedApp"), "genuinely removed app leftovers must still surface")
    }

    func testIsSafeToDeleteUsesInjectedHome() {
        // Without routing isSafeToDelete through userHomeURL, scan-and-clean
        // under an injected temp home rejects every orphan (allowlist is the
        // real home) and verification for issue #67 can pass vacuously.
        // The temp folder name still contains "HogHunter" so a naive substring
        // HogHunter path guard would also fail this test — path protection must
        // key off real namespaces, not any occurrence of the product name.
        let fm = FileManager.default
        let orphan = tempDirectory
            .appendingPathComponent("Library/Application Support/DefinitelyRemovedApp", isDirectory: true)
        try? fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        let cleaner = DiskCleaner(homeDirectory: tempDirectory)
        XCTAssertTrue(
            cleaner.isSafeToDelete(url: orphan, category: .orphanedData),
            "orphan under injected home must pass the orphan allowlist"
        )
        XCTAssertFalse(
            cleaner.isSafeToDelete(url: tempDirectory, category: .orphanedData),
            "injected home itself must stay prohibited"
        )
        XCTAssertFalse(
            cleaner.isSafeToDelete(
                url: tempDirectory.appendingPathComponent("Library", isDirectory: true),
                category: .orphanedData
            ),
            "injected Library itself must stay prohibited"
        )
        // Real Hog Hunter namespaces under the injected home stay protected.
        let protected = tempDirectory
            .appendingPathComponent("Library/Application Support/HogHunter", isDirectory: true)
        try? fm.createDirectory(at: protected, withIntermediateDirectories: true)
        XCTAssertFalse(
            cleaner.isSafeToDelete(url: protected, category: .orphanedData),
            "Application Support/HogHunter under injected home must stay protected"
        )
    }

    // MARK: - Category Metadata Tests

    func testCategoryMetadata() {
        for category in CleanCategory.allCases {
            XCTAssertFalse(category.id.isEmpty)
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.description.isEmpty)
            XCTAssertFalse(category.icon.isEmpty)
            XCTAssertGreaterThanOrEqual(category.sortOrder, 0)
        }

        // Verify default selections match safety expectations
        XCTAssertTrue(CleanCategory.userCaches.defaultSelected)
        XCTAssertTrue(CleanCategory.logsAndDiagnostics.defaultSelected)
        XCTAssertTrue(CleanCategory.trash.defaultSelected)
        XCTAssertTrue(CleanCategory.developer.defaultSelected)
        XCTAssertTrue(CleanCategory.orphanedData.defaultSelected)
        XCTAssertFalse(CleanCategory.aiArtifacts.defaultSelected, "AI agent artifacts must require explicit user review")
        XCTAssertFalse(CleanCategory.localAIModels.defaultSelected, "Local AI models must require explicit user review")
        XCTAssertFalse(CleanCategory.largeAndOldFiles.defaultSelected, "Large & old user files must never be selected by default")
        XCTAssertFalse(CleanCategory.apfsSnapshots.defaultSelected, "APFS local snapshots must require explicit user review")
        XCTAssertTrue(CleanCategory.staleBackups.defaultSelected, "Stale tool-made backups clean through Trash plus snapshot")
    }

    func testCleanTiers() {
        // Standard tier must only include safe reversible categories
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.userCaches))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.logsAndDiagnostics))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.trash))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.developer))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.apfsSnapshots))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.staleBackups))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.orphanedData))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.aiArtifacts))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.localAIModels))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.largeAndOldFiles))

        // Extreme tier must include all categories
        for cat in CleanCategory.allCases {
            XCTAssertTrue(CleanTier.extreme.isCategoryIncluded(cat))
        }

        XCTAssertEqual(CleanTier.standard.badge, "Reversible")
        XCTAssertEqual(CleanTier.extreme.badge, "Deep / AI Artifacts")
    }

    func testStaleBackupsListsOnlyOldVersionedBackups() throws {
        let fm = FileManager.default
        let storage = tempDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        let live = storage.appendingPathComponent("state.vscdb")
        let old = storage.appendingPathComponent("state.vscdb.bak-old")
        let fresh = storage.appendingPathComponent("state.vscdb.bak-fresh")
        let other = storage.appendingPathComponent("notes.txt")
        for url in [live, old, fresh, other] {
            try Data(repeating: 0x41, count: 1024).write(to: url)
        }
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)

        let cleaner = DiskCleaner(homeDirectory: tempDirectory)
        let items = cleaner.scanStaleBackups()
        XCTAssertEqual(items.map(\.title), ["state.vscdb.bak-old"])
        XCTAssertEqual(items.first?.category, .staleBackups)
    }

    func testStaleBackupsSafetyGuardsTheLiveDatabase() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home + "/Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
        let bak = URL(fileURLWithPath: home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb.bak-old")
        let live = URL(fileURLWithPath: home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        XCTAssertTrue(cleaner.isSafeToDelete(url: bak, category: .staleBackups))
        XCTAssertFalse(cleaner.isSafeToDelete(url: live, category: .staleBackups), "the live database is never listed nor touched")
        XCTAssertFalse(cleaner.isSafeToDelete(url: dir, category: .staleBackups), "the folder itself is never the item")
    }

    func testRollbackGracePeriodHoldsFreshCopies() throws {
        let fm = FileManager.default
        let apps = tempDirectory.appendingPathComponent("apps", isDirectory: true)
        let fresh = apps.appendingPathComponent(".botfleet-server.node_modules.rollback-fresh", isDirectory: true)
        let moved = apps.appendingPathComponent(".botfleet-server.node_modules.rollback-moved", isDirectory: true)
        for dir in [fresh, moved] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 1024).write(to: dir.appendingPathComponent("package.json"))
        }
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: moved.appendingPathComponent("package.json").path)

        let cleaner = DiskCleaner(homeDirectory: tempDirectory)
        let titles = cleaner.scanAIArtifacts().map(\.title)
        XCTAssertFalse(titles.contains(".botfleet-server.node_modules.rollback-fresh"), "a fresh rollback may still be needed")
        // The moved copy holds eight-day-old files, but the directory itself
        // was just created (ctime is now), so it still gets its grace day.  A
        // copy old enough to list cannot be fabricated without waiting out the
        // clock; the listing path is covered by the vacuum rule's mocked-clock
        // test in test-hoghunter-clean.py.
        XCTAssertFalse(titles.contains(".botfleet-server.node_modules.rollback-moved"))
        XCTAssertTrue(DiskCleaner.directoryMovedWithin(moved, within: 24 * 3600))
    }

    // MARK: - Safety Guard Tests

    func testIsSafeToDeleteDisallowsRootAndCriticalPaths() {
        let home = NSHomeDirectory()
        let criticalPaths = [
            "/",
            "/System",
            "/Library",
            "/Applications",
            "/usr",
            "/bin",
            "/sbin",
            "/Users",
            home,
            "\(home)/Library",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Code",
            "\(home)/apps"
        ]

        for path in criticalPaths {
            let url = URL(fileURLWithPath: path)
            for category in CleanCategory.allCases {
                // Root and other critical paths stay denied for every category,
                // including apfsSnapshots.  Thinning hardcodes the mount inside
                // SnapshotSafety; isSafeToDelete must never widen "/" into a
                // pass-through for a future caller that trashes the CleanItem URL.
                XCTAssertFalse(
                    cleaner.isSafeToDelete(url: url, category: category),
                    "Path \(path) must NOT be safe to delete under \(category)"
                )
            }
        }
    }

    /// APFS snapshot rows use synthetic `/.snapshots/<name>` URLs.  Root and
    /// foreign volumes stay denied; only the synthetic snapshot path passes.
    func testAPFSSnapshotSafetyAcceptsOnlySyntheticSnapshotPaths() {
        XCTAssertFalse(
            cleaner.isSafeToDelete(url: URL(fileURLWithPath: "/"), category: .apfsSnapshots),
            "startup volume root must stay denied"
        )
        for volume in ["/Volumes/Backup", "/Volumes/External"] {
            XCTAssertFalse(
                cleaner.isSafeToDelete(url: URL(fileURLWithPath: volume), category: .apfsSnapshots),
                "a thin must never be redirected at \(volume)"
            )
        }
        let synthetic = URL(fileURLWithPath: "/.snapshots/com.apple.TimeMachine.2026-10-05-062128.local")
        XCTAssertTrue(
            cleaner.isSafeToDelete(url: synthetic, category: .apfsSnapshots),
            "synthetic snapshot URLs are the only apfsSnapshots allowlist entries"
        )
    }

    func testIsSafeToDeleteDisallowsHogHunterPaths() {
        let home = NSHomeDirectory()
        let hogHunterPaths = [
            "\(home)/Library/Caches/com.simplewithus.hoghunter.macos",
            "\(home)/Library/Caches/com.jayservices.HogHunter",
            "\(home)/Library/Application Support/HogHunter",
            "\(home)/Library/Logs/HogHunter"
        ]

        for path in hogHunterPaths {
            let url = URL(fileURLWithPath: path)
            for category in CleanCategory.allCases {
                XCTAssertFalse(
                    cleaner.isSafeToDelete(url: url, category: category),
                    "Hog Hunter path \(path) must be protected from deletion"
                )
            }
        }
    }

    func testIsSafeToDeleteDisallowsGitDirectories() {
        let home = NSHomeDirectory()
        let gitPaths = [
            "\(home)/Downloads/some-repo/.git",
            "\(home)/Documents/project/.git/HEAD",
            "\(home)/Desktop/code/.git/objects"
        ]

        for path in gitPaths {
            let url = URL(fileURLWithPath: path)
            XCTAssertFalse(
                cleaner.isSafeToDelete(url: url, category: .largeAndOldFiles),
                "Git internal paths must be strictly protected"
            )
        }
    }

    func testIsSafeToDeleteDisallowsSecretPaths() {
        let home = NSHomeDirectory()
        let secretPaths = [
            "\(home)/.secrets/global-api-keys",
            "\(home)/Downloads/.secrets/keys.env",
            "\(home)/Desktop/repo/.secrets"
        ]

        for path in secretPaths {
            let url = URL(fileURLWithPath: path)
            for category in CleanCategory.allCases {
                XCTAssertFalse(
                    cleaner.isSafeToDelete(url: url, category: category),
                    "Secret paths must never be deleted under any category"
                )
            }
        }
    }

    func testIsSafeToDeleteAllowsValidAIArtifacts() {
        let home = NSHomeDirectory()
        let validPaths = [
            "\(home)/.gemini/antigravity/brain/0d14348f-2810-4924-a793-4acc9417a8e1",
            "\(home)/.grok/sessions/session-1234",
            "\(home)/.codex/archived_sessions/old-session.jsonl",
            "\(home)/.BotFleet.update-60793-1790"
        ]

        for path in validPaths {
            let url = URL(fileURLWithPath: path)
            XCTAssertTrue(
                cleaner.isSafeToDelete(url: url, category: .aiArtifacts),
                "Valid AI artifact \(path) should be permitted for extreme clean"
            )
        }
    }

    func testIsSafeToDeleteAllowsValidCategoryPaths() {
        let home = NSHomeDirectory()

        // Valid User Caches
        let cacheURL = URL(fileURLWithPath: "\(home)/Library/Caches/com.thirdparty.app")
        XCTAssertTrue(cleaner.isSafeToDelete(url: cacheURL, category: .userCaches))

        // Valid Logs
        let logURL = URL(fileURLWithPath: "\(home)/Library/Logs/com.thirdparty.app")
        XCTAssertTrue(cleaner.isSafeToDelete(url: logURL, category: .logsAndDiagnostics))

        // Valid Trash
        let trashURL = URL(fileURLWithPath: "\(home)/.Trash/old-file.txt")
        XCTAssertTrue(cleaner.isSafeToDelete(url: trashURL, category: .trash))

        // Valid Developer
        let derivedURL = URL(fileURLWithPath: "\(home)/Library/Developer/Xcode/DerivedData/MyProject-abcdef")
        XCTAssertTrue(cleaner.isSafeToDelete(url: derivedURL, category: .developer))

        let brewCacheURL = URL(fileURLWithPath: "\(home)/Library/Caches/Homebrew/downloads")
        XCTAssertTrue(cleaner.isSafeToDelete(url: brewCacheURL, category: .developer))

        let orbstackCacheURL = URL(fileURLWithPath: "\(home)/Library/Caches/dev.kdrag0n.MacVirt/data")
        XCTAssertTrue(cleaner.isSafeToDelete(url: orbstackCacheURL, category: .developer))

        let orbstackGroupCacheURL = URL(fileURLWithPath: "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/Library/Caches/data")
        XCTAssertTrue(cleaner.isSafeToDelete(url: orbstackGroupCacheURL, category: .developer))

        let dockerBuildxURL = URL(fileURLWithPath: "\(home)/.docker/buildx/cache/cache.db")
        XCTAssertTrue(cleaner.isSafeToDelete(url: dockerBuildxURL, category: .developer))

        // Valid Orphaned Data
        let orphanContainerURL = URL(fileURLWithPath: "\(home)/Library/Containers/com.uninstalled.company.app")
        XCTAssertTrue(cleaner.isSafeToDelete(url: orphanContainerURL, category: .orphanedData))

        // Valid Large & Old Files
        let largeFileURL = URL(fileURLWithPath: "\(home)/Downloads/big_installer.iso")
        XCTAssertTrue(cleaner.isSafeToDelete(url: largeFileURL, category: .largeAndOldFiles))
    }

    // MARK: - Directory Stats Tests

    func testDirectoryStatsComputesAccurateSize() throws {
        // Create files in temp directory
        let file1 = tempDirectory.appendingPathComponent("test1.txt")
        let file2 = tempDirectory.appendingPathComponent("test2.txt")
        let subDir = tempDirectory.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let file3 = subDir.appendingPathComponent("test3.txt")

        let content1 = Data(repeating: 0x41, count: 2048) // 2 KB
        let content2 = Data(repeating: 0x42, count: 4096) // 4 KB
        let content3 = Data(repeating: 0x43, count: 8192) // 8 KB

        try content1.write(to: file1)
        try content2.write(to: file2)
        try content3.write(to: file3)

        let stats = cleaner.directoryStats(at: tempDirectory)
        XCTAssertEqual(stats.fileCount, 3)
        XCTAssertGreaterThanOrEqual(stats.bytes, 14336) // 2048 + 4096 + 8192
        XCTAssertNotNil(stats.lastModified)
        XCTAssertFalse(stats.isApproximate)
    }

    func testDirectoryStatsFlagsACappedWalkAsApproximate() throws {
        // Ten 1 KB files; a cap of 4 counts 5 files (the file that trips the
        // cap is seen but not sized) and reports a lower bound, flagged.
        for index in 0..<10 {
            try Data(repeating: 0x41, count: 1024).write(to: tempDirectory.appendingPathComponent("file\(index).txt"))
        }

        let full = cleaner.directoryStats(at: tempDirectory)
        XCTAssertFalse(full.isApproximate)
        XCTAssertEqual(full.fileCount, 10)

        let capped = cleaner.directoryStats(at: tempDirectory, fileCap: 4)
        XCTAssertTrue(capped.isApproximate)
        XCTAssertLessThan(capped.bytes, full.bytes)
    }

    // MARK: - Formatting & Report Tests

    func testCleanResultFormatting() {
        let result = CleanResult(
            bytesReclaimed: 1_500_000_000,
            itemsRemoved: 42,
            errors: [],
            cleanedAt: Date()
        )

        XCTAssertEqual(result.formattedBytesReclaimed, "1.4 GB")
        XCTAssertEqual(result.itemsRemoved, 42)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testCleanDeletesNothingWhenTheSnapshotFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoghunter-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)

        let home = NSHomeDirectory()
        let caches = URL(fileURLWithPath: home + "/Library/Caches/HogHunterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: caches) }
        let cacheFile = caches.appendingPathComponent("cache.bin")
        try Data("cache".utf8).write(to: cacheFile)

        let cleaner = DiskCleaner(makeSnapshot: { (false, nil) })
        let item = CleanItem(
            category: .userCaches,
            title: "cache.bin",
            subtitle: cacheFile.path,
            url: cacheFile,
            bytes: 5,
            fileCount: 1,
            lastModified: nil,
            isSelected: true,
            detail: nil
        )
        let result = await cleaner.clean(items: [item], createSnapshot: true)
        XCTAssertEqual(result.itemsRemoved, 0)
        XCTAssertTrue(result.errors.contains { $0.contains("Nothing was deleted") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - APFS / Time Machine Snapshot Category Tests

    func testAPFSSnapshotsCategoryMetadata() {
        let cat = CleanCategory.apfsSnapshots
        XCTAssertEqual(cat.id, "apfsSnapshots")
        XCTAssertEqual(cat.title, "APFS Local Snapshots")
        XCTAssertFalse(cat.description.isEmpty)
        XCTAssertFalse(cat.icon.isEmpty)
        XCTAssertEqual(cat.sortOrder, 8, "Must sort after Large & Old Files")
        XCTAssertFalse(cat.isExtremeOnly, "Snapshot thinning is standard-tier safe")
        XCTAssertFalse(cat.defaultSelected, "APFS local snapshots must require explicit user review")
    }

    func testStandardTierIncludesAPFSSnapshots() {
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.apfsSnapshots))
        XCTAssertTrue(CleanTier.extreme.isCategoryIncluded(.apfsSnapshots))
    }

    func testParseSnapshotNamesStripsHeaderAndWhitespace() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-05-062128.local
        com.apple.TimeMachine.2026-10-04-180002.local

        \t  com.apple.TimeMachine.2026-10-03-221044.local

        """
        let names = SnapshotSafety.parseSnapshotNames(output)
        XCTAssertEqual(names, [
            "com.apple.TimeMachine.2026-10-05-062128.local",
            "com.apple.TimeMachine.2026-10-04-180002.local",
            "com.apple.TimeMachine.2026-10-03-221044.local"
        ])
    }

    func testParseSnapshotNamesToleratesBareInput() {
        XCTAssertEqual(SnapshotSafety.parseSnapshotNames(""), [])
        XCTAssertEqual(SnapshotSafety.parseSnapshotNames("only.one.local"), ["only.one.local"])
    }

    func testScanAPFSSnapshotsSplitsPurgeableEvenly() {
        // 3 snapshots, 60 GB purgeable → 20 GB per row.  Equal split keeps every
        // row honest about the same ceiling -- the UI never claims more bytes
        // than APFS would hand back.
        let cleaner = DiskCleaner(
            listSnapshots: { _ in [
                "com.apple.TimeMachine.2026-10-05-062128.local",
                "com.apple.TimeMachine.2026-10-04-180002.local",
                "com.apple.TimeMachine.2026-10-03-221044.local"
            ] },
            purgeableProvider: { _ in 60 * 1024 * 1024 * 1024 }
        )
        let items = cleaner.scanAPFSSnapshots()
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.category == .apfsSnapshots })
        XCTAssertTrue(items.allSatisfy { !$0.isSelected }, "APFS snapshots require explicit review")
        XCTAssertEqual(items.map(\.bytes), Array(repeating: 20 * 1024 * 1024 * 1024 as UInt64, count: 3))
        XCTAssertEqual(items.first?.title, "com.apple.TimeMachine.2026-10-05-062128.local")
        XCTAssertEqual(items.first?.subtitle, "Time Machine Local Snapshot")
        XCTAssertTrue(items.first?.url.path.hasPrefix("/.snapshots/") ?? false)
    }

    func testScanAPFSSnapshotsFallsBackToAggregateWhenListFails() {
        // nil return means the tmutil call could not start (or the runner is a
        // stub that could not, captured in tests).  A single placeholder row
        // carrying the full purgeable figure keeps the clean actionable.
        let cleaner = DiskCleaner(
            listSnapshots: { _ in nil },
            purgeableProvider: { _ in 47 * 1024 * 1024 * 1024 }
        )
        let items = cleaner.scanAPFSSnapshots()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.bytes, 47 * 1024 * 1024 * 1024)
        XCTAssertEqual(items.first?.title, "Local Time Machine Snapshots")
        XCTAssertFalse(items.first?.isSelected ?? true)
    }

    func testScanAPFSSnapshotsReturnsEmptyWhenNoSnapshotsAndNoPurgeable() {
        let cleaner = DiskCleaner(
            listSnapshots: { _ in [] },
            purgeableProvider: { _ in 0 }
        )
        XCTAssertTrue(cleaner.scanAPFSSnapshots().isEmpty)
    }

    func testIsSafeToDeleteAcceptsSnapshotPathsForAPFSSnapshots() {
        let cleaner = DiskCleaner()
        let url = URL(fileURLWithPath: "/.snapshots/com.apple.TimeMachine.2026-10-05-062128.local")
        XCTAssertTrue(cleaner.isSafeToDelete(url: url, category: .apfsSnapshots))
    }

    func testIsSafeToDeleteRejectsOtherMountsForAPFSSnapshots() {
        let cleaner = DiskCleaner()
        XCTAssertFalse(cleaner.isSafeToDelete(url: URL(fileURLWithPath: "/Volumes/External"), category: .apfsSnapshots))
        XCTAssertFalse(cleaner.isSafeToDelete(url: URL(fileURLWithPath: NSHomeDirectory()), category: .apfsSnapshots))
        XCTAssertFalse(cleaner.isSafeToDelete(url: URL(fileURLWithPath: "/"), category: .apfsSnapshots))
    }

    // MARK: - Developer Target Tests

    func testSimulatorDevicesAndCoreDeviceAreAllowedDevelopers() {
        let home = NSHomeDirectory()
        let validPaths = [
            "\(home)/Library/Developer/CoreSimulator/Devices/ABCD1234-DEAD-BEEF-0000-000000000000",
            "\(home)/Library/Developer/CoreDevice/iOS 17.0"
        ]
        for path in validPaths {
            XCTAssertTrue(
                cleaner.isSafeToDelete(url: URL(fileURLWithPath: path), category: .developer),
                "Developer path \(path) must be permitted now that CoreSimulator/Devices and CoreDevice are inventoried"
            )
        }
    }

    func testSimulatorAndCoreDeviceItemsAreUnselectedByDefault() {
        // Opt-in only: other users may actively develop for iOS.  An auto-clean
        // would force a full re-download of every simulator runtime next launch.
        XCTAssertTrue(CleanCategory.developer.defaultSelected, "Developer category stays default-selected; only Simulator/CoreDevice rows are opt-in")
        let developer = cleaner.scanDeveloper()
        for item in developer where item.title.hasPrefix("iOS Simulator Devices") || item.title.hasPrefix("iOS 27 Simulator Device") || item.title == "Xcode Connected-Device Support" {
            XCTAssertFalse(item.isSelected, "Simulator/CoreDevice items must require explicit opt-in")
            XCTAssertEqual(item.category, .developer)
            XCTAssertGreaterThan(item.bytes, 0)
        }
        // Existing selected-by-default developer targets must stay selected.
        for item in developer where item.title == "Xcode DerivedData" {
            XCTAssertTrue(item.isSelected)
        }
    }

    func testPrimaryIOS27SimulatorPreservationAndSeparateOption() async throws {
        let fm = FileManager.default
        let simBase = tempDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        let primaryDir = simBase.appendingPathComponent("Device-iOS27-Primary", isDirectory: true)
        let secondaryDir = simBase.appendingPathComponent("Device-iOS27-Secondary", isDirectory: true)
        let oldDir = simBase.appendingPathComponent("Device-iOS26", isDirectory: true)

        try fm.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondaryDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)

        let now = Date()
        func writeDevicePlist(dir: URL, name: String, runtime: String, lastUsed: Date) throws {
            let dict: [String: Any] = [
                "UDID": dir.lastPathComponent,
                "name": name,
                "runtime": runtime,
                "lastUsedAt": lastUsed,
                "state": 1
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("device.plist"))
            try "dummy payload data".write(to: dir.appendingPathComponent("data.bin"), atomically: true, encoding: .utf8)
        }

        try writeDevicePlist(dir: primaryDir, name: "Primary iPhone 18", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", lastUsed: now)
        try writeDevicePlist(dir: secondaryDir, name: "Secondary iPhone 17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", lastUsed: now.addingTimeInterval(-3600))
        try writeDevicePlist(dir: oldDir, name: "Legacy iPhone 16", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-0", lastUsed: now.addingTimeInterval(-7200))

        let testCleaner = DiskCleaner(homeDirectory: tempDirectory)
        let items = testCleaner.scanDeveloper()

        let aggregateItem = items.first { $0.title == "iOS Simulator Devices (Except Default iOS 27)" }
        let primaryItem = items.first { $0.title.hasPrefix("iOS 27 Simulator Device (Primary:") }

        XCTAssertNotNil(aggregateItem, "Aggregate item without default iOS 27 must be present")
        XCTAssertNotNil(primaryItem, "Primary iOS 27 simulator item must be present as separate option")

        guard let aggregateItem, let primaryItem else { return }
        XCTAssertFalse(aggregateItem.isSelected, "Aggregate simulator item must be unselected by default")
        XCTAssertFalse(primaryItem.isSelected, "Primary iOS 27 simulator item must be unselected by default")

        // Clean only the aggregate item: the primary iOS 27 device must survive intact
        let result = await testCleaner.clean(items: [aggregateItem], createSnapshot: false)
        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(fm.fileExists(atPath: primaryDir.path), "Primary iOS 27 device must be preserved when cleaning other simulators")
        XCTAssertFalse(fm.fileExists(atPath: secondaryDir.path), "Secondary device must be removed by aggregate clean")
        XCTAssertFalse(fm.fileExists(atPath: oldDir.path), "Legacy device must be removed by aggregate clean")

        // Clean the primary item specifically: now primary is cleaned as well
        let primaryResult = await testCleaner.clean(items: [primaryItem], createSnapshot: false)
        XCTAssertEqual(primaryResult.errors, [])
        XCTAssertFalse(fm.fileExists(atPath: primaryDir.path), "Primary iOS 27 device must be removed when explicitly chosen")
    }

    // MARK: - Temp Files Category (/tmp)

    func testTempFilesCategoryMetadata() {
        let cat = CleanCategory.tempFiles
        XCTAssertEqual(cat.id, "tempFiles")
        XCTAssertEqual(cat.title, "Temp Files")
        XCTAssertFalse(cat.description.isEmpty)
        XCTAssertFalse(cat.icon.isEmpty)
        XCTAssertEqual(cat.sortOrder, 9)
        XCTAssertFalse(cat.defaultSelected, "Temp files must require explicit per-item review — /tmp can hold live pipeline staging")
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(cat), "Temp files belong in the Standard tier (safe, reversible via snapshot + Trash)")
        XCTAssertTrue(CleanTier.extreme.isCategoryIncluded(cat))
    }

    /// Builds a temp-root fixture: stale files/dirs plus every live-fixture
    /// class the scan must exclude.  Returns the injected cleaner and root.
    private func makeTempFixture(worktrees: Set<String> = []) -> (DiskCleaner, URL) {
        let fm = FileManager.default
        let root = tempDirectory.appendingPathComponent("tmproot_\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)

        func write(_ name: String, stale: Bool) {
            let url = root.appendingPathComponent(name)
            try! "payload".write(to: url, atomically: true, encoding: .utf8)
            if stale {
                let old = Date().addingTimeInterval(-2 * 24 * 3600)
                try! fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
        }
        func mkdir(_ name: String, stale: Bool, nestedStale: Bool? = nil) -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try! fm.createDirectory(at: url, withIntermediateDirectories: true)
            let inner = url.appendingPathComponent("inner.bin")
            try! "payload".write(to: inner, atomically: true, encoding: .utf8)
            let old = Date().addingTimeInterval(-2 * 24 * 3600)
            // A genuinely dead directory has dead contents.  `nestedStale:
            // false` models the live case the top-level mtime misses: a
            // directory whose own mtime has gone cold while a file inside it
            // is still being written.
            if nestedStale ?? stale {
                try! fm.setAttributes([.modificationDate: old], ofItemAtPath: inner.path)
            }
            if stale {
                try! fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
            return url
        }

        // Provably dead: stale regular file and stale directory.
        write("dead-stale.txt", stale: true)
        _ = mkdir("dead-dir", stale: true)
        // Live: a cold directory mtime over still-written contents.
        _ = mkdir("active-dir", stale: true, nestedStale: false)
        // Live: fresh file touched just now.
        write("fresh.txt", stale: false)

        // Registered git worktree (injected provider) and a checkout the
        // provider cannot enumerate (top-level .git file).
        let wt = mkdir("lane-worktree", stale: true)
        try! "gitdir: /elsewhere".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        var worktreeSet = worktrees
        worktreeSet.insert(wt.path)

        // Active conversion-batch staging: pipeline name prefix, and a
        // marker file inside an otherwise ordinary directory.
        _ = mkdir("vc-014", stale: true)
        let marked = mkdir("export-job", stale: true)
        try! "{}".write(to: marked.appendingPathComponent("export_state.json"), atomically: true, encoding: .utf8)

        // Fleet locks: adjacent sentinel, and fleet.lock inside a directory.
        write("locked.bin", stale: true)
        try! "".write(to: root.appendingPathComponent("locked.bin.lock"), atomically: true, encoding: .utf8)
        let fleetDir = mkdir("fleet-job", stale: true)
        try! "".write(to: fleetDir.appendingPathComponent("fleet.lock"), atomically: true, encoding: .utf8)

        // Symlink: never followed, even when its target is stale.
        try! fm.createSymbolicLink(at: root.appendingPathComponent("link-to-dead"),
                                  withDestinationURL: root.appendingPathComponent("dead-stale.txt"))

        let cleaner = DiskCleaner(tempRootDirectory: root, worktreePathsProvider: { worktreeSet })
        return (cleaner, root)
    }

    func testScanTempFilesListsOnlyDeadEntries() {
        let (cleaner, _) = makeTempFixture()
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertTrue(titles.contains("dead-stale.txt"), "stale temp file must be listed")
        XCTAssertTrue(titles.contains("dead-dir"), "stale temp directory must be listed")
        XCTAssertFalse(titles.contains("fresh.txt"), "fresh file must not be listed as dead")
    }

    func testScanTempFilesSkipsDirectoryWithLiveNestedContent() {
        let (cleaner, _) = makeTempFixture()
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertFalse(
            titles.contains("active-dir"),
            "a directory whose mtime is old but whose contents are still being written is not stale"
        )
    }

    func testScanTempFilesSkipsWorktrees() {
        let (cleaner, _) = makeTempFixture()
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertFalse(titles.contains("lane-worktree"), "registered worktree must never be listed")
    }

    func testScanTempFilesSkipsBatchStaging() {
        let (cleaner, _) = makeTempFixture()
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertFalse(titles.contains("vc-014"), "pipeline batch prefix must be skipped")
        XCTAssertFalse(titles.contains("export-job"), "directory with a batch marker file must be skipped")
    }

    func testScanTempFilesSkipsLockedFiles() {
        let (cleaner, _) = makeTempFixture()
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertFalse(titles.contains("locked.bin"), "lock-held file must never be listed")
        XCTAssertFalse(titles.contains("fleet-job"), "directory with fleet.lock must never be listed")
    }

    func testScanTempFilesSkipsSymlinks() {
        let (cleaner, _) = makeTempFixture()
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertFalse(titles.contains("link-to-dead"), "symlinks must never be followed or listed")
    }

    func testScanTempFilesItemsCarryDrillDownFields() {
        let (cleaner, root) = makeTempFixture()
        let items = cleaner.scanTempFiles()
        XCTAssertFalse(items.isEmpty)
        // `FileManager.temporaryDirectory` is `/var/folders/...`, a symlink
        // to `/private/var/folders/...`.  Compare the resolved forms so the
        // assertion matches the scan and the safety guard.
        let rootPath = root.resolvingSymlinksInPath().path
        for item in items {
            XCTAssertEqual(item.category, .tempFiles)
            XCTAssertFalse(item.title.isEmpty, "filename must be present")
            let itemPath = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            XCTAssertTrue(itemPath.hasPrefix(rootPath), "full path must be present")
            XCTAssertNotNil(item.lastModified, "modified date must be present")
            XCTAssertGreaterThan(item.bytes, 0, "size must be present")
            XCTAssertFalse(item.isSelected, "temp items must require explicit per-item selection")
        }
    }

    func testIsSafeToDeleteAcceptsOnlyTempRoot() {
        let (cleaner, root) = makeTempFixture()
        XCTAssertTrue(
            cleaner.isSafeToDelete(url: root.appendingPathComponent("dead-stale.txt"), category: .tempFiles),
            "items under the temp root must be deletable"
        )
        XCTAssertFalse(
            cleaner.isSafeToDelete(url: root, category: .tempFiles),
            "the temp root itself must never be deletable"
        )
        XCTAssertFalse(
            cleaner.isSafeToDelete(url: URL(fileURLWithPath: "/tmp/elsewhere.txt"), category: .tempFiles),
            "paths outside the injected temp root must be rejected"
        )
    }

    func testScanTempFilesEmptyRootScansClean() {
        let fm = FileManager.default
        let root = tempDirectory.appendingPathComponent("emptytmp_\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        let cleaner = DiskCleaner(tempRootDirectory: root, worktreePathsProvider: { [] })
        XCTAssertTrue(cleaner.scanTempFiles().isEmpty)
    }

    func testScanTempFilesSkipsDirectoryWithNestedGitCheckout() {
        let fm = FileManager.default
        let root = tempDirectory.appendingPathComponent("nestedgit_\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-2 * 24 * 3600)

        func staleDir(_ name: String, under: URL? = nil) -> URL {
            let parent = under ?? root
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try! fm.createDirectory(at: url, withIntermediateDirectories: true)
            let inner = url.appendingPathComponent("inner.bin")
            try! "payload".write(to: inner, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.modificationDate: old], ofItemAtPath: inner.path)
            try! fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            return url
        }

        _ = staleDir("dead-dir")

        // Stale container holding a nested checkout one level down.
        let container = staleDir("container")
        let nested = staleDir("checkout", under: container)
        try! "gitdir: /elsewhere".write(to: nested.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: old], ofItemAtPath: container.path)

        // Stale container whose child is a registered worktree (no .git file).
        let wrap = staleDir("wrap")
        let lane = staleDir("lane", under: wrap)
        try! fm.setAttributes([.modificationDate: old], ofItemAtPath: wrap.path)

        let worktrees: Set<String> = [(lane.path as NSString).standardizingPath]
        let cleaner = DiskCleaner(tempRootDirectory: root, worktreePathsProvider: { worktrees })
        let titles = Set(cleaner.scanTempFiles().map(\.title))
        XCTAssertTrue(titles.contains("dead-dir"), "a dead directory with no nested git must still be listed")
        XCTAssertFalse(titles.contains("container"), "directory holding a nested git checkout must not be listed")
        XCTAssertFalse(titles.contains("wrap"), "directory holding a nested registered worktree must not be listed")
        XCTAssertFalse(titles.contains("checkout"))
        XCTAssertFalse(titles.contains("lane"))
    }

    func testWorktreePathCacheIsStableAcrossCalls() {
        XCTAssertEqual(DiskCleaner.worktreeCacheTTL, 300)
        let first = DiskCleaner.defaultWorktreePaths()
        let second = DiskCleaner.defaultWorktreePaths()
        XCTAssertEqual(first, second, "a second call must reuse the cached worktree set")
    }

    func testResolvedPathAgreesOnSymlinkedTempRoots() {
        let viaTmp = DiskCleaner.resolvedPath("/tmp")
        let viaPrivate = DiskCleaner.resolvedPath("/private/tmp")
        XCTAssertEqual(viaTmp, viaPrivate)
        XCTAssertFalse(viaTmp.isEmpty)
    }

    // MARK: - Volume Awareness & Symlink Tests

    func testDetectVolumeInternalMacintoshHD() {
        let internalURL = URL(fileURLWithPath: "/Users")
        let (isExternal, volumeName) = DiskCleaner.detectVolume(for: internalURL)
        XCTAssertFalse(isExternal)
        XCTAssertEqual(volumeName, "Macintosh HD")
    }

    func testDetectVolumeExternalDrivePrefix() {
        let externalURL = URL(fileURLWithPath: "/Volumes/External/Cache/test")
        let (isExternal, volumeName) = DiskCleaner.detectVolume(for: externalURL)
        XCTAssertTrue(isExternal)
        XCTAssertEqual(volumeName, "External")
    }

    func testCleanItemAutoDetectsVolumeAndSymlinks() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetDir = tempDir.appendingPathComponent("target_folder")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let symlinkURL = tempDir.appendingPathComponent("symlink_folder")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetDir)

        let normalItem = CleanItem(
            category: .userCaches,
            title: "Normal",
            subtitle: targetDir.path,
            url: targetDir,
            bytes: 1024,
            fileCount: 1,
            lastModified: Date(),
            isSelected: true
        )
        XCTAssertFalse(normalItem.isSymlink)
        XCTAssertFalse(normalItem.isExternal)

        let symlinkItem = CleanItem(
            category: .userCaches,
            title: "Symlink",
            subtitle: symlinkURL.path,
            url: symlinkURL,
            bytes: 2048,
            fileCount: 2,
            lastModified: Date(),
            isSelected: true
        )
        XCTAssertTrue(symlinkItem.isSymlink)
    }

    func testCleaningSymlinkPreservesSymlinkAndCleansContents() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetDir = tempDir.appendingPathComponent("external_target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let dummyFile = targetDir.appendingPathComponent("cache_entry.bin")
        try Data("cache data".utf8).write(to: dummyFile)

        let cachesDir = tempDir.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let symlinkURL = cachesDir.appendingPathComponent("cache_symlink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetDir)

        let cleaner = DiskCleaner(
            makeSnapshot: { (true, "test-snap") },
            homeDirectory: tempDir
        )

        let item = CleanItem(
            category: .userCaches,
            title: "Symlink Cache",
            subtitle: symlinkURL.path,
            url: symlinkURL,
            bytes: 10,
            fileCount: 1,
            lastModified: Date(),
            isSelected: true
        )

        XCTAssertTrue(item.isSymlink)
        let result = await cleaner.clean(items: [item], createSnapshot: false)
        XCTAssertEqual(result.itemsRemoved, 1)

        // The symlink itself MUST still exist!
        let symlinkStillExists = FileManager.default.fileExists(atPath: symlinkURL.path)
        XCTAssertTrue(symlinkStillExists, "Cleaning must preserve the symlink so external offload setup is not broken")

        // The target directory exists, but child file was removed
        let targetContents = try FileManager.default.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(targetContents.isEmpty, "The child files inside target should have been cleaned")
    }
}

