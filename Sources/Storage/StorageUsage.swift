import Foundation

/// A category of on-disk bytes that an app can own.  Used both for tagging
/// each walk-target so the user can see where the bytes live, and so the
/// scanner can produce a deterministic breakdown for the UI.
enum StorageCategory: String, CaseIterable, Hashable, Sendable {
    /// The .app bundle itself.  Walked recursively.
    case bundle
    /// `~/Library/Containers/<bundleId>/` — sandbox data on disk.
    case containers
    /// `~/Library/Group Containers/<groupId>.*/` — shared app-group data.
    case groupContainers
    /// `~/Library/Application Support/<bundleId|appName>/`.
    case applicationSupport
    /// `~/Library/Caches/<bundleId|appName>/`.
    case caches
    /// `~/Library/WebKit/<bundleId>/` plus Chromium-family fingerprints.
    case webKit
    /// `~/Library/Preferences/<bundleId>.plist`.
    case preferences
    /// `~/Library/Saved Application State/<bundleId>.savedState/`.
    case savedState
    /// `~/Library/Logs/<bundleId>/`.
    case logs
    /// `~/Library/Cookies/<bundleId>.binarycookies`.
    case cookies
    /// `~/Library/HTTPStorage/<bundleId>/`.
    case httpStorage
    /// `~/Library/Application Scripts/<bundleId>/`.
    case appScripts
    /// Bytes that the scanner caught but could not classify.
    case other

    var displayName: String {
        switch self {
        case .bundle: return "App bundle"
        case .containers: return "Sandbox containers"
        case .groupContainers: return "Group containers"
        case .applicationSupport: return "Application Support"
        case .caches: return "Caches"
        case .webKit: return "WebKit / browser data"
        case .preferences: return "Preferences"
        case .savedState: return "Saved state"
        case .logs: return "Logs"
        case .cookies: return "Cookies"
        case .httpStorage: return "HTTP storage"
        case .appScripts: return "Application scripts"
        case .other: return "Other"
        }
    }

    /// Sort key so the largest categories float to the top of the breakdown.
    func sortOrder() -> Int {
        switch self {
        case .bundle: return 0
        case .containers: return 1
        case .groupContainers: return 2
        case .applicationSupport: return 3
        case .caches: return 4
        case .webKit: return 5
        case .preferences: return 6
        case .cookies: return 7
        case .httpStorage: return 8
        case .savedState: return 9
        case .logs: return 10
        case .appScripts: return 11
        case .other: return 12
        }
    }
}

/// One walked directory or file.  The scanner returns these so the UI can
/// show a category breakdown but the test suite can pin attribution rules
/// without depending on the UI's aggregation.
struct StorageSlice: Equatable, Hashable, Sendable {
    var category: StorageCategory
    var path: String
    /// Allocated bytes — the actual blocks on disk.  Falls back to `.fileSize`
    /// (logical size) when the file system does not report allocation, which
    /// keeps APFS volumes honest and HFS+ / network shares compatible.
    var bytes: UInt64
    /// True when the scanner had to short-circuit the walk (time cap, file cap,
    /// or read error) and the resulting number is therefore a lower bound.
    var approximate: Bool
}

/// One installed app, with the disk it owns.
struct StorageUsage: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identifier for SwiftUI; falls back to `path` when the bundle id
    /// is missing (rare, but seen for "anonymous" Mac App Store placeholders).
    var id: String { bundleId ?? path ?? name }
    var bundleId: String?
    var name: String
    /// Absolute path to the `.app`, or `nil` for a bundle-id-only entry.
    var path: String?
    /// True when the app was running at scan time.  Lets the UI offer a
    /// "running now" filter without re-querying NSWorkspace.
    var isRunning: Bool
    /// The .app bundle itself.
    var bundleBytes: UInt64
    /// Everything that was not the .app bundle.
    var hiddenBytes: UInt64
    /// Per-category walk results.  Sorted by descending size in `topApps`.
    var slices: [StorageSlice]
    /// True when one or more walks had to be capped.  Mirrors the union of
    /// `StorageSlice.approximate`.
    var anyApproximate: Bool

    var totalBytes: UInt64 { bundleBytes &+ hiddenBytes }

    /// The "this app owns way more than its bundle" test: used by the UI to
    /// decide whether to flag the row.  Two conditions so a small app with
    /// a normal-sized cache is not flagged as egregious.
    var isHiddenHeavy: Bool {
        bundleBytes == 0 ? hiddenBytes > 200_000_000 :
        (hiddenBytes >= bundleBytes &* 5) && hiddenBytes > 200_000_000
    }

    /// Why this row is flagged, in words, or `nil` when it is not flagged.
    ///
    /// 2026-10-03 (MINIMAX).  The flag used to be explained only by a `.help()`
    /// tooltip on a 10pt triangle, and the red border around the row carried no
    /// explanation at all, so the user was shown a red box and told nothing.
    /// This is the plain-language reason, shown in the row itself.
    var hiddenHeavyReason: String? {
        guard isHiddenHeavy else { return nil }
        if bundleBytes == 0 {
            return "no .app bundle found — \(HogFormat.memory(hiddenBytes)) of supporting files"
        }
        let ratio = Double(hiddenBytes) / Double(bundleBytes)
        return "supporting files are \(ratio.formatted(.number.precision(.fractionLength(1))))×"
            + " the \(HogFormat.memory(bundleBytes)) bundle"
    }
}

/// A category-level total across all apps.  Useful for UI subtitles ("2.1
/// GB cached by 12 apps") and for tests that pin the categories that exist.
struct StorageCategoryTotal: Equatable, Hashable, Sendable {
    var category: StorageCategory
    var bytes: UInt64
}
