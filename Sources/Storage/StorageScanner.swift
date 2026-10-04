import Foundation
import Security

/// Reads the on-disk footprint of every installed app and groups the bytes
/// by bundle id.  The scanner is intentionally pure: it takes its inputs
/// (a list of bundle directories and a list of running bundle ids), walks
/// the well-known `Library` and `WebKit` paths plus the .app bundle itself,
/// and returns a deterministic `StorageUsage` per app.  All work runs on
/// the caller's queue, so callers can decide whether to ship the scan to a
/// background `DispatchQueue`.
///
/// Attributions are straightforward and rule-based.  We do not try to
/// compute "true shared" attribution across Chromium-family browsers; each
/// path is owned by a single bundle id and the totals are real (not split).
final class StorageScanner: @unchecked Sendable {
    /// Maximum number of file entries walked inside any one directory tree.
    /// Capped so a runaway `node_modules` or `DerivedData` directory cannot
    /// stall the scan for tens of seconds.
    static let perDirectoryFileCap = 50_000

    /// Maximum wall-clock seconds per scan target.  Past this the scanner
    /// records an approximate total for that target and moves on.
    static let perTargetTimeBudget: TimeInterval = 3.0

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public entry points

    /// Walks every installed `.app` under the standard roots (`/Applications`,
    /// `~/Applications`, `/System/Applications`) and the per-user paths each
    /// app owns.  Returns one `StorageUsage` per unique bundle id.
    ///
    /// `runningBundleIds` is a snapshot of currently-running bundle ids; we
    /// use it to set `isRunning` without spawning NSWorkspace here, so the
    /// scanner stays pure and the UI can refresh cheaply.
    func installedApps(runningBundleIds: Set<String>) -> [StorageUsage] {
        let roots = Self.installedAppRoots()
        var seen: [String: InstalledApp] = [:] // key: bundleId ?? appName
        for root in roots {
            for appURL in appURLs(under: root) {
                let info = readInfo(at: appURL)
                let key = info.bundleId ?? info.executable ?? appURL.path
                if seen[key] == nil {
                    seen[key] = InstalledApp(
                        bundleId: info.bundleId,
                        name: info.name,
                        url: appURL,
                        groupContainers: info.applicationGroups
                    )
                }
            }
        }
        // Some apps are not installed under the standard roots (e.g. an app
        // that lives only in `~/Library` or `/Library`).  Anything running we
        // did not pick up is added so the user sees the row with an empty
        // path.  This is rare; the regression test pings it.
        for bundleId in runningBundleIds where seen[bundleId] == nil {
            seen[bundleId] = InstalledApp(bundleId: bundleId, name: bundleId, url: nil, groupContainers: [])
        }

        return seen.values
            .sorted { lhs, rhs in lhs.idKey < rhs.idKey }
            .map { app in scan(app: app, isRunning: app.bundleId.map { runningBundleIds.contains($0) } ?? false) }
    }

    /// Walks a single app's footprint and returns its rows.  Public so tests
    /// and on-demand refresh can target one app at a time.
    func scan(app: InstalledApp, isRunning: Bool) -> StorageUsage {
        var slices: [StorageSlice] = []

        // The bundle itself, walked recursively.  An .app is a directory.
        if let url = app.url {
            let (bytes, approx) = directoryBytes(at: url.appendingPathComponent("Contents"))
            slices.append(StorageSlice(
                category: .bundle,
                path: url.path,
                bytes: bytes,
                approximate: approx
            ))
        }

        if let bundleId = app.bundleId {
            // Container rules: each path is category-keyed and forms a stable
            // list so the UI breakdown is consistent across runs.
            let library = Self.userLibraryURL()

            var targets: [(StorageCategory, URL)] = []
            targets.append((.containers, library.appendingPathComponent("Containers/\(bundleId)", isDirectory: true)))
            for name in Self.libraryDirectoryCandidates(name: app.name, bundleId: bundleId) {
                targets.append((.applicationSupport, library.appendingPathComponent("Application Support/\(name)", isDirectory: true)))
                targets.append((.caches,             library.appendingPathComponent("Caches/\(name)", isDirectory: true)))
            }
            targets.append((.webKit,      library.appendingPathComponent("WebKit/\(bundleId)", isDirectory: true)))
            targets.append((.savedState,  library.appendingPathComponent("Saved Application State/\(bundleId).savedState", isDirectory: true)))
            targets.append((.logs,        library.appendingPathComponent("Logs/\(bundleId)", isDirectory: true)))
            targets.append((.httpStorage, library.appendingPathComponent("HTTPStorage/\(bundleId)", isDirectory: true)))
            targets.append((.appScripts,  library.appendingPathComponent("Application Scripts/\(bundleId)", isDirectory: true)))

            for (category, url) in targets {
                let (bytes, approx) = directoryBytes(at: url)
                guard bytes > 0 else { continue }
                slices.append(StorageSlice(category: category, path: url.path, bytes: bytes, approximate: approx))
            }

            // Preferences plist is a single file.  Look it up under both the
            // standard `Library/Preferences` and the `ByHost` mirror.
            for url in [library.appendingPathComponent("Preferences/\(bundleId).plist"),
                        library.appendingPathComponent("Preferences/ByHost")] {
                let (bytes, approx) = fileOrZeroBytes(at: url)
                guard bytes > 0 else { continue }
                slices.append(StorageSlice(category: .preferences, path: url.path, bytes: bytes, approximate: approx))
            }

            // Cookies file (binary).  Most apps that use NSHTTPCookieStorage
            // do not own their own .binarycookies — Safari and the system
            // WebKit catch-all do — but a few do, and attributing that file
            // helps the user understand a per-app "tracking blob".
            let cookiesURL = library.appendingPathComponent("Cookies/\(bundleId).binarycookies")
            let (cookieBytes, cookieApprox) = fileOrZeroBytes(at: cookiesURL)
            if cookieBytes > 0 {
                slices.append(StorageSlice(
                    category: .cookies,
                    path: cookiesURL.path,
                    bytes: cookieBytes,
                    approximate: cookieApprox
                ))
            }

            // Group containers — on macOS, App Groups are stored in `Library/Group Containers/`.
            // The directory name is either the group ID directly, or prefixed with the Team ID (e.g. `<TeamID>.<groupID>`).
            // We resolve known entitlements first, with fallback to bundle-ID suffix matching for sandboxed apps.
            var checkedGroupContainerURLs: Set<URL> = []
            let groupContainersBase = library.appendingPathComponent("Group Containers", isDirectory: true)

            for groupID in app.groupContainers {
                let directURL = groupContainersBase.appendingPathComponent(groupID, isDirectory: true)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: directURL.path, isDirectory: &isDir), isDir.boolValue {
                    checkedGroupContainerURLs.insert(directURL)
                }
            }

            let candidateSuffixes = app.groupContainers + [app.bundleId].compactMap { $0 }
            if !candidateSuffixes.isEmpty, let contents = try? fileManager.contentsOfDirectory(at: groupContainersBase, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for item in contents {
                    let folderName = item.lastPathComponent
                    for suffix in candidateSuffixes where !suffix.isEmpty {
                        if folderName == suffix || folderName.hasSuffix("." + suffix) {
                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                                checkedGroupContainerURLs.insert(item)
                            }
                        }
                    }
                }
            }

            for url in checkedGroupContainerURLs {
                let (bytes, approx) = directoryBytes(at: url)
                guard bytes > 0 else { continue }
                slices.append(StorageSlice(category: .groupContainers, path: url.path, bytes: bytes, approximate: approx))
            }
        }

        // Bucket the slices into totals.
        var bundleBytes: UInt64 = 0
        var hiddenBytes: UInt64 = 0
        var anyApprox = false
        var collapsed: [StorageCategory: StorageSlice] = [:]
        for slice in slices {
            collapsed[slice.category] = StorageSlice(
                category: slice.category,
                path: slice.path,
                bytes: (collapsed[slice.category]?.bytes ?? 0) &+ slice.bytes,
                approximate: (collapsed[slice.category]?.approximate ?? false) || slice.approximate
            )
            if slice.category == .bundle {
                bundleBytes &+= slice.bytes
            } else {
                hiddenBytes &+= slice.bytes
            }
            if slice.approximate { anyApprox = true }
        }
        let ordered = collapsed.values.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.category.sortOrder() < rhs.category.sortOrder()
        }

        return StorageUsage(
            bundleId: app.bundleId,
            name: app.name,
            path: app.url?.path,
            isRunning: isRunning,
            bundleBytes: bundleBytes,
            hiddenBytes: hiddenBytes,
            slices: ordered,
            anyApproximate: anyApprox
        )
    }

    // MARK: - Discovery

    /// A bundle the scanner knows about, ready to be walked.
    struct InstalledApp: Hashable, Sendable {
        var bundleId: String?
        var name: String
        var url: URL?
        /// `com.apple.security.application-groups` values pulled from the
        /// bundle's `Info.plist`.
        var groupContainers: [String]

        /// Stable key for the internal dedupe map.
        var idKey: String { bundleId ?? name }
    }

    /// Standard install roots.  Each is enumerated for `.app` directories.
    static func installedAppRoots() -> [URL] {
        var roots: [URL] = []
        for path in [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            NSHomeDirectory() + "/Applications"
        ] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots.append(url)
            }
        }
        return roots
    }

    /// Recursively enumerates `.app` bundles under `root`.  Skips symlinks to
    /// avoid double-counting the same `.app` under multiple parents.
    func appURLs(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if let isLink = values?.isSymbolicLink, isLink { continue }
                if values?.isDirectory == true {
                    out.append(url)
                }
            }
        }
        return out
    }

    /// Reads `Info.plist` and Mach-O code-signing entitlements for the bundle id,
    /// display name, executable name, and application-group identifiers.  Returns
    /// sensible fallbacks when the plist is missing or the bundle is malformed.
    func readInfo(at url: URL) -> (bundleId: String?, name: String, executable: String?, applicationGroups: [String]) {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            // Bundle-shaped directory without an Info.plist is rare.  Use the
            // directory name as a fallback so the row still appears.
            let fallback = url.deletingPathExtension().lastPathComponent
            return (bundleId: nil, name: fallback, executable: nil, applicationGroups: [])
        }
        let bundleId = plist["CFBundleIdentifier"] as? String
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let executable = plist["CFBundleExecutable"] as? String

        var groups: [String] = []
        // On macOS, App Groups are code-signing entitlements embedded in the Mach-O binary
        var staticCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
           let code = staticCode {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let dict = info as? [String: Any],
               let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
               let codeGroups = entitlements["com.apple.security.application-groups"] as? [String] {
                groups.append(contentsOf: codeGroups)
            }
        }
        // Augment or fallback from Info.plist
        if let plistGroups = plist["com.apple.security.application-groups"] as? [String] {
            for g in plistGroups where !groups.contains(g) {
                groups.append(g)
            }
        }

        return (bundleId: bundleId, name: name, executable: executable, applicationGroups: groups)
    }

    // MARK: - Walking

    /// Sums the allocated bytes under `directory`.  Returns 0 bytes (and no
    /// slice) when the path is missing or is a plain file — the caller maps
    /// missing files to `nil` and skips them.
    func directoryBytes(at directory: URL) -> (bytes: UInt64, approximate: Bool) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return (0, false)
        }
        let keys: Set<URLResourceKey> = [
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isDirectoryKey
        ]

        let deadline = Date().addingTimeInterval(Self.perTargetTimeBudget)
        var bytes: UInt64 = 0
        var count = 0
        var hitCap = false
        var hitDeadline = false

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return (0, false)
        }

        for case let url as URL in enumerator {
            if Date() >= deadline { hitDeadline = true; break }
            count += 1
            if count > Self.perDirectoryFileCap { hitCap = true; break }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true { continue }
            if values.isRegularFile != true { continue }
            let allocated = (values.fileAllocatedSize ?? 0)
            let logical = (values.fileSize ?? 0)
            bytes &+= allocated > 0 ? UInt64(allocated) : UInt64(logical)
        }

        return (bytes, hitCap || hitDeadline)
    }

    /// Bytes for a single file (used for `Preferences/*.plist` and
    /// `Cookies/*.binarycookies`, which are individual files).
    func fileOrZeroBytes(at url: URL) -> (bytes: UInt64, approximate: Bool) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return (0, false)
        }
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, false) }
        if let allocated = values.fileAllocatedSize, allocated > 0 { return (UInt64(allocated), false) }
        if let logical = values.fileSize { return (UInt64(logical), false) }
        return (0, false)
    }

    // MARK: - Helpers

    static func userLibraryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    /// Apps frequently write to either a bundle-id-keyed or app-name-keyed
    /// directory under `Library/Application Support` and `Library/Caches`,
    /// depending on which API the developer reached for (`URL.applicationSupportDirectory`
    /// vs `FileManager.url(for: .applicationSupportDirectory, …)`).  We try
    /// the bundle id first and fall back to the app name.
    /// Apps can land in `Library/Application Support/<dir>` or
    /// `Library/Caches/<dir>` keyed by either the bundle id (sandboxed apps
    /// and most SwiftUI/AppKit code) or the human-readable name
    /// (Chromium-family browsers write to
    /// `Application Support/Google/Chrome/`; many Electron apps write to
    /// `Application Support/<ProductName>/`).  We scan both forms because
    /// matching either-or forces the user to dig in Finder, which is exactly
    /// what this pane exists to avoid.
    static func libraryDirectoryCandidates(name: String, bundleId: String) -> [String] {
        var out: [String] = []
        if !bundleId.isEmpty { out.append(bundleId) }
        if !name.isEmpty, !out.contains(name) { out.append(name) }
        // Chromium fingerprint: `Library/Application Support/<Vendor>/<Browser>/`
        // is reachable because the vendor dir is shared by every Chromium
        // product of the same vendor.  We do not attribute that to a single
        // bundle here; the per-app breakdown under `webKit` catches the
        // per-app `Library/WebKit/<bundleId>/` instead.
        let bundleSuffix = bundleId.split(separator: ".").last.map(String.init) ?? ""
        if !bundleSuffix.isEmpty, !out.contains(bundleSuffix) { out.append(bundleSuffix) }
        return out
    }
}
