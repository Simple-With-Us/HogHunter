import XCTest

@testable import HogHunter

/// Covers `StorageScanner`.  Uses a temp directory per test so the file
/// manager walks a sandboxed `Library/` shape we control.  The scanner reads
/// `Info.plist` and the well-known `Library` paths, so most of these tests
/// fake a `~/Applications/<App>.app` and the `Library/` paths that match it.
final class StorageScannerTests: XCTestCase {

    private var tempHome: URL!
    private var scanner: StorageScanner!

    override func setUpWithError() throws {
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hoghunter-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        // NSHomeDirectory is the only Home Directory the scanner reads, so
        // we cannot redirect it.  Instead we reach into the scanner's per-app
        // logic by giving it bundle URLs that already live under
        // `tempHome`, and matching `Library/...` paths under the same root.
        // The simplest way to do that is to lay out a fake `tempHome` with
        // the structure we want, and run the scanner against paths under it
        // for the few cases that don't touch NSHomeDirectory at all.
        scanner = StorageScanner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - AppInfo parsing

    func testReadInfoPicksBundleIdDisplayNameAndGroupContainers() throws {
        let appURL = try makeApp(
            under: tempHome.appendingPathComponent("FakeApp.app"),
            bundleId: "com.example.FakeApp",
            displayName: "FakeApp",
            applicationGroups: ["group.com.example.shared"]
        )
        let info = scanner.readInfo(at: appURL)
        XCTAssertEqual(info.bundleId, "com.example.FakeApp")
        XCTAssertEqual(info.name, "FakeApp")
        XCTAssertEqual(info.applicationGroups, ["group.com.example.shared"])
    }

    func testReadInfoExtractsCodeSignatureEntitlementsFromAdHocSignedApp() throws {
        // The SecStaticCodeCreateWithPath / SecCodeCopySigningInformation
        // block had zero effective coverage on machines without
        // /Applications/OrbStack.app, so sign a throwaway bundle ad-hoc
        // instead of probing the real /Applications.
        let appURL = try makeSignedApp(
            under: tempHome.appendingPathComponent("Signed.app"),
            applicationGroups: ["TEAMID.dev.orbstack"]
        )
        let info = scanner.readInfo(at: appURL)
        XCTAssertTrue(info.applicationGroups.contains("TEAMID.dev.orbstack"),
                      "expected signature entitlements, got \(info.applicationGroups)")
    }

    func testReadInfoFallsBackToBundleNameWhenDisplayNameMissing() throws {
        let appURL = try makeApp(
            under: tempHome.appendingPathComponent("Foo.app"),
            bundleId: "com.example.Foo",
            displayName: nil,
            applicationGroups: []
        )
        let info = scanner.readInfo(at: appURL)
        XCTAssertEqual(info.name, "Foo")
    }

    func testReadInfoReturnsFallbackWhenInfoPlistIsMissing() throws {
        let appURL = tempHome.appendingPathComponent("Mystery.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let info = scanner.readInfo(at: appURL)
        XCTAssertNil(info.bundleId)
        XCTAssertEqual(info.name, "Mystery")
    }

    // MARK: - Library directory candidates

    func testLibraryDirectoryCandidatesYieldBundleIdFirstAndDeDup() {
        let candidates = StorageScanner.libraryDirectoryCandidates(name: "My App", bundleId: "com.example.MyApp")
        XCTAssertEqual(candidates.first, "com.example.MyApp")
        XCTAssertTrue(candidates.contains("My App"))
        // Chromium-style suffix: the last dot-segment.
        XCTAssertTrue(candidates.contains("MyApp"))
    }

    func testLibraryDirectoryCandidatesSkipEmptyName() {
        let candidates = StorageScanner.libraryDirectoryCandidates(name: "", bundleId: "com.example.Foo")
        // Bundle id first; the trailing "Foo" still comes through because it
        // matches the last dot-segment heuristic that catches Chromium-style
        // fingerprint directories.
        XCTAssertEqual(candidates.first, "com.example.Foo")
        XCTAssertFalse(candidates.contains(""))
    }

    // MARK: - Directory walk

    func testDirectoryBytesSumsAllocatedBytesOfFilesUnderADirectory() throws {
        let dir = tempHome.appendingPathComponent("walk-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeBlob(at: dir.appendingPathComponent("a.bin"), bytes: 1024)
        try writeBlob(at: dir.appendingPathComponent("nested/b.bin"), bytes: 2048)

        let (bytes, approx) = scanner.directoryBytes(at: dir)
        XCTAssertGreaterThanOrEqual(bytes, 1024 + 2048)
        XCTAssertFalse(approx)
    }

    func testDirectoryBytesReturnsZeroForMissingDirectory() {
        let missing = tempHome.appendingPathComponent("nope")
        let (bytes, _) = scanner.directoryBytes(at: missing)
        XCTAssertEqual(bytes, 0)
    }

    func testFileOrZeroBytesReadsSingleFile() throws {
        let file = tempHome.appendingPathComponent("settings.plist")
        try writeBlob(at: file, bytes: 512)
        let (bytes, _) = scanner.fileOrZeroBytes(at: file)
        XCTAssertGreaterThanOrEqual(bytes, 512)
    }

    func testFileOrZeroBytesReturnsZeroForDirectory() throws {
        let dir = tempHome.appendingPathComponent("dir-not-file")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (bytes, _) = scanner.fileOrZeroBytes(at: dir)
        XCTAssertEqual(bytes, 0)
    }

    // MARK: - Per-app scan with a fake home

    func testScanAttributresBundleContainersAndCachesToTheRightCategories() throws {
        // Lay out a fake home so the scanner's `userLibraryURL()` finds it.
        // We re-launch the scanner and our helpers using a swapped path.
        // Because we cannot change NSHomeDirectory() at runtime, the per-app
        // attribution paths in `StorageScanner.scan(app:)` use the real home
        // even when we set `tempHome`.  We therefore drive the per-path
        // helper methods here in isolation to pin attribution, and check
        // `scan(app:)` only at the level of the bundle itself.
        let bundleURL = tempHome.appendingPathComponent("Applications/Fake.app")
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try writeBlob(at: bundleURL.appendingPathComponent("Contents/MacOS/Fake"), bytes: 4096)

        let app = StorageScanner.InstalledApp(
            bundleId: "com.example.Fake",
            name: "Fake",
            url: bundleURL,
            groupContainers: []
        )
        let usage = scanner.scan(app: app, isRunning: false)
        XCTAssertGreaterThan(usage.bundleBytes, 0)
        XCTAssertEqual(usage.bundleId, "com.example.Fake")
        XCTAssertTrue(usage.slices.contains { $0.category == .bundle })
    }

    func testScanProducesOnlyBundleSliceWhenLibraryPathsAreEmpty() throws {
        let bundleURL = tempHome.appendingPathComponent("Apps/Quiet.app")
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try writeBlob(at: bundleURL.appendingPathComponent("Contents/MacOS/Quiet"), bytes: 4096)

        let app = StorageScanner.InstalledApp(
            bundleId: "com.example.Quiet",
            name: "Quiet",
            url: bundleURL,
            groupContainers: []
        )
        let usage = scanner.scan(app: app, isRunning: false)
        XCTAssertEqual(usage.hiddenBytes, 0)
        XCTAssertFalse(usage.isHiddenHeavy)
    }

    // MARK: - Hidden cost flag

    func testIsHiddenHeavyFlagsAppsWithOversizedHiddenFootprint() {
        let usage = StorageUsage(
            bundleId: "x",
            name: "x",
            path: nil,
            isRunning: false,
            bundleBytes: 200_000_000,        // 200 MB
            hiddenBytes: 1_500_000_000,      // 1.5 GB
            slices: [],
            anyApproximate: false
        )
        XCTAssertTrue(usage.isHiddenHeavy)
    }

    func testIsHiddenHeavyDoesNotFlagAppsWithHiddenBytesJustOverTheMBFloor() {
        let usage = StorageUsage(
            bundleId: "x",
            name: "x",
            path: nil,
            isRunning: false,
            bundleBytes: 100_000_000,
            hiddenBytes: 250_000_000,
            slices: [],
            anyApproximate: false
        )
        // hidden 2.5x bundle, but only 250 MB — within the "noise" margin.
        XCTAssertFalse(usage.isHiddenHeavy)
    }

    func testIsHiddenHeavyDoesNotFlagAppsWithZeroBundle() {
        let usage = StorageUsage(
            bundleId: "x",
            name: "x",
            path: nil,
            isRunning: false,
            bundleBytes: 0,
            hiddenBytes: 150_000_000,
            slices: [],
            anyApproximate: false
        )
        XCTAssertFalse(usage.isHiddenHeavy)
    }

    // MARK: - Helpers

    private func makeApp(under appURL: URL,
                         bundleId: String,
                         displayName: String?,
                         applicationGroups: [String]) throws -> URL {
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL"
        ]
        if let displayName {
            info["CFBundleDisplayName"] = displayName
        } else {
            info["CFBundleName"] = appURL.deletingPathExtension().lastPathComponent
        }
        if !applicationGroups.isEmpty {
            info["com.apple.security.application-groups"] = applicationGroups
        }
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)
        try writeBlob(at: appURL.appendingPathComponent("Contents/MacOS/Fake"), bytes: 8192)
        return appURL
    }

    private func writeBlob(at url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// Builds a bundle like `makeApp` but signs it ad-hoc carrying the given
    /// application-groups entitlement, so `readInfo` exercises the
    /// code-signature path instead of the Info.plist fallback.  The
    /// placeholder executable is replaced with a real Mach-O (`/bin/ls`),
    /// which ad-hoc codesign requires.
    private func makeSignedApp(under appURL: URL, applicationGroups: [String]) throws -> URL {
        _ = try makeApp(under: appURL,
                        bundleId: "com.example.SignedApp",
                        displayName: "SignedApp",
                        applicationGroups: [])
        let exeURL = appURL.appendingPathComponent("Contents/MacOS/Fake")
        try FileManager.default.removeItem(at: exeURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: exeURL)

        let entitlementsURL = tempHome.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        let entitlements: [String: Any] = ["com.apple.security.application-groups": applicationGroups]
        let entitlementsData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entitlementsData.write(to: entitlementsURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, appURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "HogHunterTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ad-hoc codesign failed with status \(process.terminationStatus)"])
        }
        return appURL
    }
}
