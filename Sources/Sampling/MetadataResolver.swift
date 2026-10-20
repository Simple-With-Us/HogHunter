import AppKit
import Darwin
import Foundation

/// The part of `NSRunningApplication` the resolver reads.  It exists so a test
/// can prove the table is read once per pid rather than once per tick.
protocol RunningApplicationInfo {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var localizedName: String? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var bundleURL: URL? { get }
    var icon: NSImage? { get }
}

extension RunningApplicationInfo {
    var icon: NSImage? { nil }
}

extension NSRunningApplication: RunningApplicationInfo {}

/// Turns process keys into names, bundle identifiers and icons.
///
/// Everything here touches AppKit, so it lives on the main actor and is only
/// asked about rows that are about to be drawn.  Names and icons come only
/// from the already-running application table; process paths are never opened.
@MainActor
final class MetadataResolver {
    struct Metadata {
        var displayName: String
        var bundleId: String?
        var icon: NSImage?
        var activationPolicy: NSApplication.ActivationPolicy?
        var isRunningApplication: Bool
        /// True when this entry was built from an `AppInfo` that had not yet
        /// settled (a nil bundle id, name or URL) -- a freshly launched app
        /// publishing itself asynchronously.  A provisional entry is never
        /// served from the cache, so the resolver keeps re-reading it every
        /// call until the app settles, at which point it is overwritten with
        /// a normal, cached entry.
        var isProvisional: Bool = false
    }

    /// What `NSWorkspace.runningApplications` knows about one process.  Reading
    /// these four properties is not free -- measured at 40-50 ms for ~250 apps
    /// on an M5 -- so an entry is built once per pid and reused for as long as
    /// that pid is still running.
    struct AppInfo {
        var bundleId: String?
        var localizedName: String?
        var activationPolicy: NSApplication.ActivationPolicy
        var bundleURL: URL?
        var icon: NSImage?

        /// A freshly launched app publishes these asynchronously, so a partly
        /// filled entry is re-read next tick instead of being frozen.
        var isSettled: Bool { bundleId != nil && localizedName != nil && bundleURL != nil }
    }

    private(set) var runningApps: [pid_t: AppInfo] = [:]
    private var cache: [ProcessKey: Metadata] = [:]
    private var iconByBundle: [String: NSImage] = [:]
    private var nameByBundle: [String: String] = [:]
    private let enumerate: () -> [RunningApplicationInfo]
    private let iconSourceAllowed: (URL?) -> Bool

    init(runningApplications: @escaping () -> [RunningApplicationInfo] = { NSWorkspace.shared.runningApplications },
         iconSourceAllowed: ((URL?) -> Bool)? = nil) {
        self.enumerate = runningApplications
        self.iconSourceAllowed = iconSourceAllowed ?? { Self.isSafeIconSource($0) }
    }

    /// Refreshes the running-application table and returns it.  Enumerating is
    /// cheap; reading each app's properties is not, so a pid already in the
    /// table keeps the entry it had once it is settled.  A recycled pid can
    /// therefore carry the previous app's name for one tick, which is the same
    /// risk the per-key metadata cache already takes and is invisible at a 3 s
    /// cadence.  A settled entry's `activationPolicy` can still legitimately
    /// change later (an accessory helper promoted to regular, and vice versa),
    /// so the caller periodically passes `force: true` to re-read every app
    /// rather than trust the memo forever.
    @discardableResult
    func refreshRunningApps(force: Bool = false) -> [pid_t: AppInfo] {
        var table: [pid_t: AppInfo] = [:]
        table.reserveCapacity(runningApps.count)
        for app in enumerate() {
            let pid = app.processIdentifier
            if !force, let known = runningApps[pid], known.isSettled {
                table[pid] = known
                continue
            }
            let bundleURL = app.bundleURL
            // A forced refresh re-reads the mutable properties, but a running
            // app's icon is stable: reuse the one already fetched so the main
            // actor does not re-request it for every local app on every forced
            // refresh.  Only a genuinely new pid pays the read.  The memo is
            // keyed on the bundle URL rather than on the icon itself, so an app
            // whose icon legitimately reads as nil is memoized too instead of
            // being re-requested on every forced refresh.
            let memoized = runningApps[pid].flatMap { known in
                known.bundleURL == bundleURL ? known : nil
            }
            table[pid] = AppInfo(
                bundleId: app.bundleIdentifier,
                localizedName: app.localizedName,
                activationPolicy: app.activationPolicy,
                bundleURL: bundleURL,
                icon: memoized?.icon ?? (memoized == nil && iconSourceAllowed(bundleURL) ? app.icon : nil)
            )
        }
        runningApps = table
        // The bundle-keyed maps are a session-long memo: an app that quits
        // keeps its icon and name for the history rows that still reference it.
        // Only overwrite, never clear.
        for info in table.values {
            guard let bundleId = info.bundleId else { continue }
            if let icon = info.icon { iconByBundle[bundleId] = icon }
            if let name = info.localizedName { nameByBundle[bundleId] = name }
        }
        return table
    }

    /// A running app may live on an external volume.  Asking AppKit for that
    /// icon can touch the bundle, so automatic icon reads use local app roots.
    static func isSafeIconSource(_ url: URL?, localRoots: [String]? = nil) -> Bool {
        guard let url, url.isFileURL else { return false }
        // Normalize lexically before touching the filesystem.  realpath or URL symlink
        // resolution here would itself visit an external target and request access.
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        guard components.count <= 64 else { return false }
        let path = "/" + components.joined(separator: "/")
        let roots = localRoots ?? ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/", NSHomeDirectory() + "/Applications/"]
        guard roots.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return false }
        // Check local components without following links.  A local alias to an external
        // bundle is rejected at the link itself, before any target is inspected.
        var prefix = ""
        for component in components {
            prefix += "/" + component
            var info = stat()
            guard lstat(prefix, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    func isRegularApp(_ pid: pid_t) -> Bool {
        runningApps[pid]?.activationPolicy == .regular
    }

    func bundleId(_ pid: pid_t) -> String? {
        runningApps[pid]?.bundleId
    }

    /// Reads both bundle id and the localized display name for a running pid.
    /// Returns `"pid <n>"` as the name when the process is not in the cached
    /// table (system daemons, jail helpers, briefly-launching children).
    func lookup(_ pid: pid_t) -> (bundleId: String?, name: String) {
        if let app = runningApps[pid] {
            return (bundleId: app.bundleId, name: app.localizedName ?? "pid \(pid)")
        }
        return (bundleId: nil, name: "pid \(pid)")
    }

    /// Snapshot of every pid currently in the running-apps table.  Used by the
    /// Storage pane to flag rows as "running now" cheaply.
    func runningBundleIds() -> [String] {
        runningApps.values.compactMap(\.bundleId)
    }

    /// Resolves only the keys asked for.  Anything already cached is returned
    /// without touching AppKit again -- unless that entry is `isProvisional`,
    /// in which case the cache is bypassed and the key is re-read until the
    /// app it belongs to settles.  Without this, a key first resolved while
    /// its app was still launching would keep serving that half-published
    /// entry (often just "pid 1234") forever, never picking up the real name
    /// once `NSRunningApplication` finishes publishing it.
    func resolve(_ keys: [ProcessKey], samples: [ProcessKey: ProcessSample]) -> [ProcessKey: Metadata] {
        var out: [ProcessKey: Metadata] = [:]
        out.reserveCapacity(keys.count)
        for key in keys {
            if let cached = cache[key], !cached.isProvisional {
                out[key] = cached
                continue
            }
            let sample = samples[key]
            let app = runningApps[key.pid]
            let bundle = app?.bundleId
            let name = app?.localizedName ?? sample?.name ?? "pid \(key.pid)"
            let metadata = Metadata(
                displayName: name,
                bundleId: bundle,
                icon: app?.icon ?? icon(bundleId: bundle, path: sample?.path),
                activationPolicy: app?.activationPolicy,
                isRunningApplication: app != nil,
                isProvisional: app?.isSettled == false
            )
            cache[key] = metadata
            out[key] = metadata
        }
        return out
    }

    /// Icons are available only for safe, currently running application bundles.
    /// `path` remains in the API for callers with process samples, but is never read.
    func icon(bundleId: String?, path _: String?) -> NSImage? {
        guard let bundleId else { return nil }
        return iconByBundle[bundleId]
    }

    /// History rows use the live app name when available and their stored name
    /// otherwise.  Neither case opens a bundle on disk.
    func displayName(bundleId: String?, fallback: String) -> String {
        guard let bundleId else { return fallback }
        return nameByBundle[bundleId] ?? fallback
    }

    /// Drops cache entries for keys that no longer exist.  The caller schedules
    /// this every 60 ticks; it does not throttle itself, so building the live
    /// set is only paid on the ticks that actually prune.
    func prune(live: Set<ProcessKey>) {
        cache = cache.filter { live.contains($0.key) }
    }
}
