import XCTest
@testable import HogHunter

final class MaintainRegistryTests: XCTestCase {
    private final class ProbeFileManager: FileManager, @unchecked Sendable {
        var executableProbes: [String] = []
        var directoryProbes: [String] = []
        override func isExecutableFile(atPath path: String) -> Bool {
            executableProbes.append(path)
            return super.isExecutableFile(atPath: path)
        }
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            directoryProbes.append(url.path)
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    func testPollingInventoryRejectsExternalScriptAliasesBeforeExecutableProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let blocked = try XCTUnwrap(DirectorySizeWalker.canonicalPath(root.path)) + "/protected"
        let local = scripts.appendingPathComponent("local.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
        try FileManager.default.createSymbolicLink(atPath: scripts.appendingPathComponent("external.sh").path,
                                                 withDestinationPath: blocked + "/absent.sh")
        let manager = ProbeFileManager()
        for _ in 0..<4 {
            let rows = MaintainRegistryStore.loadScripts(baseDirectory: root, fileManager: manager, mountPaths: [blocked])
            XCTAssertEqual(rows.map(\.id), ["local"])
        }
        XCTAssertFalse(manager.executableProbes.contains { $0.hasPrefix(blocked) || $0.hasSuffix("external.sh") })
        // A relocated scripts directory must also be rejected before its directory is listed.
        try FileManager.default.removeItem(at: scripts)
        try FileManager.default.createSymbolicLink(atPath: scripts.path, withDestinationPath: blocked + "/scripts")
        manager.directoryProbes.removeAll()
        for _ in 0..<4 {
            XCTAssertTrue(MaintainRegistryStore.loadScripts(baseDirectory: root, fileManager: manager, mountPaths: [blocked]).isEmpty)
        }
        XCTAssertTrue(manager.directoryProbes.isEmpty)
    }

    private func entry(_ id: String, path: String = "/repo/scripts/maintain.py") -> MaintainScriptEntry {
        MaintainScriptEntry(id: id, path: path, mode: "owned", scope: "local", owner: id, argv: nil)
    }

    func testSchedulerAndManualEntryAppearOnceWithoutChangingCustomEntries() {
        let scheduler = entry("maintain_scheduler")
        let manual = entry("maintain_cli")
        let custom = entry("custom")
        let rows = MaintainRegistryStore.presentationEntries([scheduler, manual, custom])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].displayName, "Hog Hunter Maintenance")
        XCTAssertTrue(rows[0].owner.contains("launchd"))
        XCTAssertTrue(rows[0].owner.contains("CLI"))
        XCTAssertEqual(rows[1], custom)
        XCTAssertEqual(scheduler.id, "maintain_scheduler")
        XCTAssertEqual(manual.id, "maintain_cli")
    }

    func testDifferentPathsOrClassificationsRemainSeparate() {
        let scheduled = entry("maintain_scheduler")
        let movedManual = entry("maintain_cli", path: "/other/maintain.py")
        XCTAssertEqual(MaintainRegistryStore.presentationEntries([scheduled, movedManual]).count, 2)
        var observed = entry("maintain_cli")
        observed.mode = "observed"
        XCTAssertEqual(MaintainRegistryStore.presentationEntries([scheduled, observed]).count, 2)
    }
}
