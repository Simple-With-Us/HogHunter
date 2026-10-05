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
    }

    func testCleanTiers() {
        // Standard tier must only include safe reversible categories
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.userCaches))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.logsAndDiagnostics))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.trash))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.developer))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.apfsSnapshots))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.orphanedData))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.aiArtifacts))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.localAIModels))
        XCTAssertFalse(CleanTier.standard.isCategoryIncluded(.largeAndOldFiles))

        // Extreme tier must include all categories
        for cat in CleanCategory.allCases {
            XCTAssertTrue(CleanTier.extreme.isCategoryIncluded(cat))
        }

        XCTAssertEqual(CleanTier.standard.badge, "Safe / Reversible")
        XCTAssertEqual(CleanTier.extreme.badge, "Deep / AI Artifacts")
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
                XCTAssertFalse(
                    cleaner.isSafeToDelete(url: url, category: category),
                    "Path \(path) must NOT be safe to delete under \(category)"
                )
            }
        }
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
        XCTAssertFalse(CleanCategory.developer.defaultSelected, "Developer category default must be inherited per-item, not flipped here")
        let developer = cleaner.scanDeveloper()
        for item in developer where item.title == "iOS Simulator Devices" || item.title == "Xcode Connected-Device Support" {
            XCTAssertFalse(item.isSelected, "Simulator/CoreDevice items must require explicit opt-in")
            XCTAssertEqual(item.category, .developer)
            XCTAssertGreaterThan(item.bytes, 0)
        }
        // Existing selected-by-default developer targets must stay selected.
        for item in developer where item.title == "Xcode DerivedData" {
            XCTAssertTrue(item.isSelected)
        }
    }
}

