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
    }

    func testCleanTiers() {
        // Standard tier must only include safe reversible categories
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.userCaches))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.logsAndDiagnostics))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.trash))
        XCTAssertTrue(CleanTier.standard.isCategoryIncluded(.developer))
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
}
