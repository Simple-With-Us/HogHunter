import AppKit
import XCTest

@testable import HogHunter

/// A stand-in for `NSRunningApplication` that counts how often the resolver
/// reads its properties.  Those reads are the expensive part of a refresh
/// -- measured at 40-50 ms for ~250 running apps -- so the point of these tests
/// is that they happen once per pid, not once per tick.
private final class FakeRunningApp: RunningApplicationInfo {
    let processIdentifier: pid_t
    private let storedBundleId: String?
    private let storedName: String?
    private let storedPolicy: NSApplication.ActivationPolicy
    private let storedURL: URL?
    private let storedIcon: NSImage?
    private(set) var propertyReads = 0
    private(set) var iconReads = 0

    init(
        pid: pid_t,
        bundleId: String?,
        name: String?,
        policy: NSApplication.ActivationPolicy,
        url: URL?,
        icon: NSImage? = nil
    ) {
        self.processIdentifier = pid
        self.storedBundleId = bundleId
        self.storedName = name
        self.storedPolicy = policy
        self.storedURL = url
        self.storedIcon = icon
    }

    var bundleIdentifier: String? {
        propertyReads += 1
        return storedBundleId
    }

    var localizedName: String? {
        propertyReads += 1
        return storedName
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        propertyReads += 1
        return storedPolicy
    }

    var bundleURL: URL? {
        propertyReads += 1
        return storedURL
    }

    var icon: NSImage? {
        iconReads += 1
        return storedIcon
    }
}

final class MetadataResolverTests: XCTestCase {

    private func app(pid: pid_t, bundleId: String? = "com.example.Editor") -> FakeRunningApp {
        FakeRunningApp(
            pid: pid,
            bundleId: bundleId,
            name: "Editor",
            policy: .regular,
            url: URL(fileURLWithPath: "/Applications/Editor.app")
        )
    }

    private func sample(pid: pid_t, start: UInt64, name: String) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: start),
            ppid: 1,
            uid: 501,
            name: name,
            path: "",
            cpuPercent: 0,
            hasBaseline: true,
            footprintBytes: 0,
            residentBytes: 0,
            threadCount: 1,
            diskReadBytesPerSec: 0,
            diskWriteBytesPerSec: 0,
            idleWakeupsPerSec: 0
        )
    }

    // MARK: - Running-app table

    @MainActor
    func testRunningApplicationPropertiesAreReadOncePerPid() {
        let editor = app(pid: 501)
        let resolver = MetadataResolver(runningApplications: { [editor] }, iconSourceAllowed: { _ in true })

        resolver.refreshRunningApps()
        XCTAssertEqual(editor.propertyReads, 4, "one read of each metadata property on first sight")
        XCTAssertEqual(editor.iconReads, 1, "one icon read for a local running app")
        XCTAssertTrue(resolver.isRegularApp(501))
        XCTAssertEqual(resolver.bundleId(501), "com.example.Editor")

        for _ in 0..<20 { resolver.refreshRunningApps() }
        XCTAssertEqual(editor.propertyReads, 4, "a pid already in the table must not be read again")
        XCTAssertEqual(editor.iconReads, 1, "a cached running app must not reload its icon")
        XCTAssertTrue(resolver.isRegularApp(501), "the memoized entry still answers")
        XCTAssertEqual(resolver.bundleId(501), "com.example.Editor")
    }

    @MainActor
    func testAnAppThatHasNotPublishedItselfYetIsReadAgain() {
        // NSRunningApplication fills these in asynchronously after a launch, so
        // a half-published entry must not be frozen.
        let launching = FakeRunningApp(pid: 777, bundleId: nil, name: nil, policy: .prohibited, url: nil)
        let resolver = MetadataResolver(runningApplications: { [launching] })

        resolver.refreshRunningApps()
        XCTAssertEqual(launching.propertyReads, 4)
        resolver.refreshRunningApps()
        XCTAssertEqual(launching.propertyReads, 8, "an unsettled entry is re-read next tick")
        XCTAssertEqual(launching.iconReads, 0, "an app without a safe bundle URL has no automatic icon read")
    }

    @MainActor
    func testAnIconlessAppIsNotLookedUpAgainOnAForcedRefresh() {
        // A running app can legitimately have no icon.  That nil is a completed
        // lookup, not a missing memo, so a forced refresh must not re-request it.
        let iconless = FakeRunningApp(
            pid: 601,
            bundleId: "com.example.Iconless",
            name: "Iconless",
            policy: .regular,
            url: URL(fileURLWithPath: "/Applications/Iconless.app"),
            icon: nil
        )
        let resolver = MetadataResolver(runningApplications: { [iconless] }, iconSourceAllowed: { _ in true })

        resolver.refreshRunningApps()
        XCTAssertEqual(iconless.iconReads, 1, "one icon read for a local running app without an icon")

        for _ in 0..<20 { resolver.refreshRunningApps(force: true) }
        XCTAssertEqual(iconless.iconReads, 1, "a forced refresh must not re-request a known nil icon")
    }

    @MainActor
    func testPidsThatHaveGoneLeaveTheTable() {
        let editor = app(pid: 501)
        var running: [RunningApplicationInfo] = [editor]
        let resolver = MetadataResolver(runningApplications: { running })

        resolver.refreshRunningApps()
        XCTAssertEqual(resolver.runningApps.count, 1)

        running = []
        resolver.refreshRunningApps()
        XCTAssertTrue(resolver.runningApps.isEmpty)
        XCTAssertNil(resolver.bundleId(501))
    }

    // MARK: - Per-key cache

    @MainActor
    func testPruneDropsMetadataForKeysThatAreGone() {
        let resolver = MetadataResolver(runningApplications: { [] })
        let key = ProcessKey(pid: 900, startTime: 7)

        let first = resolver.resolve([key], samples: [key: sample(pid: 900, start: 7, name: "first")])
        XCTAssertEqual(first[key]?.displayName, "first")

        let cached = resolver.resolve([key], samples: [key: sample(pid: 900, start: 7, name: "second")])
        XCTAssertEqual(cached[key]?.displayName, "first", "a cached key is answered without touching AppKit")

        resolver.prune(live: [])
        let rebuilt = resolver.resolve([key], samples: [key: sample(pid: 900, start: 7, name: "second")])
        XCTAssertEqual(rebuilt[key]?.displayName, "second", "pruning really drops the entry")
    }

    @MainActor
    func testAProvisionalEntryIsReplacedAfterTheAppSettles() {
        // Launching, so `runningApps` holds an unsettled AppInfo (nil bundle
        // id, name and URL) the first time this key is resolved.
        let key = ProcessKey(pid: 777, startTime: 3)
        var running: [RunningApplicationInfo] = [
            FakeRunningApp(pid: 777, bundleId: nil, name: nil, policy: .prohibited, url: nil),
        ]
        let resolver = MetadataResolver(runningApplications: { running })
        resolver.refreshRunningApps()

        let samples = [key: sample(pid: 777, start: 3, name: "Fallback")]
        let provisional = resolver.resolve([key], samples: samples)
        XCTAssertEqual(provisional[key]?.displayName, "Fallback", "an unsettled app falls back to the process name")

        // The app finishes publishing itself.
        running = [app(pid: 777)]
        resolver.refreshRunningApps()

        let settled = resolver.resolve([key], samples: samples)
        XCTAssertEqual(
            settled[key]?.displayName,
            "Editor",
            "a provisional entry must not be served from the cache once the app has settled"
        )
    }

    @MainActor
    func testExternalApplicationAndProcessPathsNeverRequestIcons() {
        let external = FakeRunningApp(
            pid: 842,
            bundleId: "com.example.External",
            name: "External",
            policy: .regular,
            url: URL(fileURLWithPath: "/Volumes/External/External.app"),
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
        let resolver = MetadataResolver(runningApplications: { [external] })
        resolver.refreshRunningApps()

        let key = ProcessKey(pid: 842, startTime: 5)
        let metadata = resolver.resolve([key], samples: [key: sample(pid: 842, start: 5, name: "External")])
        XCTAssertNil(metadata[key]?.icon)
        XCTAssertEqual(external.iconReads, 0)
        XCTAssertNil(resolver.icon(bundleId: "com.example.Missing", path: "/Volumes/External/tool"))
        XCTAssertEqual(resolver.displayName(bundleId: "com.example.Missing", fallback: "Stored"), "Stored")
    }

    @MainActor
    func testLocalRunningAppIconAndNameAreReusedForHistory() {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let local = FakeRunningApp(
            pid: 843,
            bundleId: "com.example.Local",
            name: "Local App",
            policy: .regular,
            url: URL(fileURLWithPath: "/Applications/Local.app"),
            icon: image
        )
        let resolver = MetadataResolver(runningApplications: { [local] }, iconSourceAllowed: { _ in true })
        resolver.refreshRunningApps()

        XCTAssertTrue(resolver.icon(bundleId: "com.example.Local", path: nil) === image)
        XCTAssertEqual(resolver.displayName(bundleId: "com.example.Local", fallback: "Stored"), "Local App")
        XCTAssertEqual(local.iconReads, 1)
        resolver.refreshRunningApps(force: true)
        XCTAssertEqual(local.iconReads, 1, "forced metadata refresh reuses the icon")
    }

    @MainActor
    func testIconPolicyRejectsLocalSymlinkWithoutResolvingItsTarget() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let physicalPath = try XCTUnwrap(DirectorySizeWalker.canonicalPath(root.path))
        let physicalRoot = URL(fileURLWithPath: physicalPath)
        let app = physicalRoot.appendingPathComponent("Local.app")
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(MetadataResolver.isSafeIconSource(app, localRoots: [physicalPath]))
        let alias = physicalRoot.appendingPathComponent("Alias.app")
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: "/Volumes/Unavailable/External.app")
        XCTAssertFalse(MetadataResolver.isSafeIconSource(alias, localRoots: [physicalPath]))
        XCTAssertFalse(MetadataResolver.isSafeIconSource(URL(fileURLWithPath: "/Volumes/Unavailable/External.app")))
        XCTAssertFalse(MetadataResolver.isSafeIconSource(URL(fileURLWithPath: "/Applications/../Volumes/Unavailable/External.app")))
    }

    @MainActor
    func testRecycledPidAtTheSameURLDoesNotReuseAnotherBundleIcon() {
        let originalImage = NSImage(size: NSSize(width: 16, height: 16))
        let nextImage = NSImage(size: NSSize(width: 16, height: 16))
        let url = URL(fileURLWithPath: "/Applications/Shared.app")
        let original = FakeRunningApp(pid: 995, bundleId: "com.example.Original", name: "Original", policy: .regular, url: url, icon: originalImage)
        let replacement = FakeRunningApp(pid: 995, bundleId: "com.example.Replacement", name: "Replacement", policy: .regular, url: url, icon: nextImage)
        var active = [original]
        let resolver = MetadataResolver(runningApplications: { active }, iconSourceAllowed: { _ in true })
        resolver.refreshRunningApps()
        active = [replacement]
        resolver.refreshRunningApps(force: true)
        XCTAssertTrue(resolver.icon(bundleId: "com.example.Replacement", path: nil) === nextImage)
        XCTAssertEqual(replacement.iconReads, 1)
    }

    @MainActor
    func testBundleMemoKeepsRecentHistoryAndEvictsItsOldestEntry() {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let oldest = FakeRunningApp(pid: 996, bundleId: "com.example.Oldest", name: "Oldest", policy: .regular, url: URL(fileURLWithPath: "/Applications/Oldest.app"), icon: image)
        var active = [oldest]
        let resolver = MetadataResolver(runningApplications: { active }, iconSourceAllowed: { _ in true })
        resolver.refreshRunningApps()
        active = []
        resolver.refreshRunningApps()
        XCTAssertTrue(resolver.icon(bundleId: "com.example.Oldest", path: nil) === image)
        active = (0..<MetadataResolver.maximumRememberedBundles).map {
            FakeRunningApp(pid: pid_t(2000 + $0), bundleId: "com.example.New\($0)", name: "New \($0)", policy: .regular, url: URL(fileURLWithPath: "/Applications/New\($0).app"), icon: image)
        }
        resolver.refreshRunningApps()
        XCTAssertNil(resolver.icon(bundleId: "com.example.Oldest", path: nil))
        XCTAssertEqual(resolver.displayName(bundleId: "com.example.Oldest", fallback: "Stored"), "Stored")
        XCTAssertTrue(resolver.icon(bundleId: "com.example.New0", path: nil) === image)
    }
}
