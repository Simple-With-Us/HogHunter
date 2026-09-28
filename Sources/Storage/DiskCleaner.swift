import Foundation

/// Categories of reclaimable disk clutter supported by Hog Hunter's CleanMyMac-grade cleaner.
enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    /// App and user caches under `~/Library/Caches/`.
    case userCaches
    /// System and user logs, crash reports, and diagnostics under `~/Library/Logs/`.
    case logsAndDiagnostics
    /// Files currently residing in the user Trash (`~/.Trash/`).
    case trash
    /// Developer build artifacts and package manager caches (Xcode DerivedData, Archives, iOS DeviceSupport, Homebrew, npm, Yarn, etc.).
    case developer
    /// Residual application support and cache directories left behind by uninstalled applications.
    case orphanedData
    /// Large files (>100 MB) or old files (>6 months) in user working folders (Downloads, Documents, Desktop).
    case largeAndOldFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: return "User Caches"
        case .logsAndDiagnostics: return "Logs & Diagnostics"
        case .trash: return "Trash Bins"
        case .developer: return "Developer Junk"
        case .orphanedData: return "Orphaned App Leftovers"
        case .largeAndOldFiles: return "Large & Old Files"
        }
    }

    var description: String {
        switch self {
        case .userCaches:
            return "Application cache directories that can be safely rebuilt."
        case .logsAndDiagnostics:
            return "Old log files, diagnostic reports, and crash dumps."
        case .trash:
            return "Items sitting in the macOS Trash bin."
        case .developer:
            return "Xcode DerivedData, Archives, iOS DeviceSupport, and package manager caches."
        case .orphanedData:
            return "Support folders remaining from applications no longer installed."
        case .largeAndOldFiles:
            return "Files over 100 MB or untouched for over 6 months."
        }
    }

    var icon: String {
        switch self {
        case .userCaches: return "arrow.triangle.2.circlepath"
        case .logsAndDiagnostics: return "doc.text.magnifyingglass"
        case .trash: return "trash"
        case .developer: return "hammer"
        case .orphanedData: return "app.dashed"
        case .largeAndOldFiles: return "clock.arrow.circlepath"
        }
    }

    var sortOrder: Int {
        switch self {
        case .userCaches: return 0
        case .logsAndDiagnostics: return 1
        case .trash: return 2
        case .developer: return 3
        case .orphanedData: return 4
        case .largeAndOldFiles: return 5
        }
    }

    /// Whether this category is checked by default for one-click clean.
    var defaultSelected: Bool {
        switch self {
        case .userCaches, .logsAndDiagnostics, .trash, .developer, .orphanedData:
            return true
        case .largeAndOldFiles:
            // Large and old files require explicit user review to prevent accidental deletion
            return false
        }
    }
}

/// A single reclaimable item discovered during a scan.
struct CleanItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    var category: CleanCategory
    var title: String
    var subtitle: String
    var url: URL
    var bytes: UInt64
    var fileCount: Int
    var lastModified: Date?
    var isSelected: Bool
    var detail: String?

    var formattedSize: String {
        HogFormat.memory(bytes)
    }
}

/// Summary report for a specific clean category.
struct CleanCategoryReport: Identifiable, Sendable {
    var id: String { category.id }
    var category: CleanCategory
    var items: [CleanItem]
    var totalBytes: UInt64
    var selectedBytes: UInt64
    var itemCount: Int

    var formattedTotalSize: String {
        HogFormat.memory(totalBytes)
    }

    var formattedSelectedSize: String {
        HogFormat.memory(selectedBytes)
    }
}

/// Overall report produced by a disk scan.
struct CleanScanReport: Sendable {
    var categories: [CleanCategoryReport]
    var totalBytes: UInt64
    var totalSelectedBytes: UInt64
    var scannedAt: Date

    var formattedTotalSize: String {
        HogFormat.memory(totalBytes)
    }

    var formattedSelectedSize: String {
        HogFormat.memory(totalSelectedBytes)
    }
}

/// Result returned after performing a clean operation.
struct CleanResult: Sendable {
    var bytesReclaimed: UInt64
    var itemsRemoved: Int
    var errors: [String]
    var cleanedAt: Date

    var formattedBytesReclaimed: String {
        HogFormat.memory(bytesReclaimed)
    }
}

/// Engine responsible for discovering reclaimable files and performing safe cleaning operations.
final class DiskCleaner: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Full Scan

    /// Performs a full scan across all categories.
    func scan(installedApps: [StorageScanner.InstalledApp] = [],
              progress: ((String) -> Void)? = nil) async -> CleanScanReport {
        var reports: [CleanCategoryReport] = []
        var overallTotal: UInt64 = 0
        var overallSelected: UInt64 = 0

        for category in CleanCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            await Task.yield()
            progress?(category.title)
            let items = scanCategory(category, installedApps: installedApps)
            let total = items.reduce(0 as UInt64) { $0 &+ $1.bytes }
            let selected = items.filter(\.isSelected).reduce(0 as UInt64) { $0 &+ $1.bytes }
            overallTotal &+= total
            overallSelected &+= selected

            reports.append(CleanCategoryReport(
                category: category,
                items: items,
                totalBytes: total,
                selectedBytes: selected,
                itemCount: items.count
            ))
        }

        return CleanScanReport(
            categories: reports,
            totalBytes: overallTotal,
            totalSelectedBytes: overallSelected,
            scannedAt: Date()
        )
    }

    /// Scans a single category.
    func scanCategory(_ category: CleanCategory, installedApps: [StorageScanner.InstalledApp] = []) -> [CleanItem] {
        switch category {
        case .userCaches:
            return scanUserCaches()
        case .logsAndDiagnostics:
            return scanLogsAndDiagnostics()
        case .trash:
            return scanTrash()
        case .developer:
            return scanDeveloper()
        case .orphanedData:
            return scanOrphanedData(installedApps: installedApps)
        case .largeAndOldFiles:
            return scanLargeAndOldFiles()
        }
    }

    // MARK: - Category Scanners

    /// Scans `~/Library/Caches/` for user caches (skips Hog Hunter and developer package caches handled elsewhere).
    func scanUserCaches() -> [CleanItem] {
        let cachesURL = userHomeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        // Developer package managers that live in Caches are attributed to Developer category instead
        let developerCacheNames: Set<String> = [
            "Homebrew", "CocoaPods", "Yarn", "pnpm", "go-build", "pip", "com.apple.dt.Xcode"
        ]

        var items: [CleanItem] = []
        for url in contents {
            let name = url.lastPathComponent
            if developerCacheNames.contains(name) { continue }
            if isHogHunterIdentifier(name) { continue }

            let stats = directoryStats(at: url)
            guard stats.bytes > 0 else { continue }

            items.append(CleanItem(
                category: .userCaches,
                title: name,
                subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                url: url,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                lastModified: stats.lastModified,
                isSelected: CleanCategory.userCaches.defaultSelected,
                detail: nil
            ))
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans `~/Library/Logs/` and crash reports for logs and diagnostics.
    func scanLogsAndDiagnostics() -> [CleanItem] {
        var items: [CleanItem] = []
        let logsURL = userHomeURL.appendingPathComponent("Library/Logs", isDirectory: true)

        if let contents = try? fileManager.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                let name = url.lastPathComponent
                if isHogHunterIdentifier(name) { continue }

                let stats = directoryStats(at: url)
                guard stats.bytes > 0 else { continue }

                items.append(CleanItem(
                    category: .logsAndDiagnostics,
                    title: name,
                    subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    url: url,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.logsAndDiagnostics.defaultSelected,
                    detail: "Log files & diagnostic data"
                ))
            }
        }

        // DiagnosticReports folder
        let diagReportsURL = logsURL.appendingPathComponent("DiagnosticReports", isDirectory: true)
        if fileManager.fileExists(atPath: diagReportsURL.path) && !items.contains(where: { $0.url == diagReportsURL }) {
            let stats = directoryStats(at: diagReportsURL)
            if stats.bytes > 0 {
                items.append(CleanItem(
                    category: .logsAndDiagnostics,
                    title: "Diagnostic Reports",
                    subtitle: "~/Library/Logs/DiagnosticReports",
                    url: diagReportsURL,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.logsAndDiagnostics.defaultSelected,
                    detail: "System crash dumps and diagnostic traces"
                ))
            }
        }

        // CrashReporter
        let crashReportsURL = userHomeURL.appendingPathComponent("Library/Application Support/CrashReporter", isDirectory: true)
        if fileManager.fileExists(atPath: crashReportsURL.path) {
            let stats = directoryStats(at: crashReportsURL)
            if stats.bytes > 0 {
                items.append(CleanItem(
                    category: .logsAndDiagnostics,
                    title: "Crash Reporter Logs",
                    subtitle: "~/Library/Application Support/CrashReporter",
                    url: crashReportsURL,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.logsAndDiagnostics.defaultSelected,
                    detail: "Application crash logs"
                ))
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans items in `~/.Trash/`.
    func scanTrash() -> [CleanItem] {
        let trashURL = userHomeURL.appendingPathComponent(".Trash", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }

        var items: [CleanItem] = []
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(".") && name == ".DS_Store" { continue }

            let stats = directoryStats(at: url)
            guard stats.bytes > 0 else { continue }

            items.append(CleanItem(
                category: .trash,
                title: name,
                subtitle: "Trash: \(name)",
                url: url,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                lastModified: stats.lastModified,
                isSelected: CleanCategory.trash.defaultSelected,
                detail: "Sitting in Trash"
            ))
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans developer build artifacts and package manager caches.
    func scanDeveloper() -> [CleanItem] {
        var items: [CleanItem] = []

        let targets: [(name: String, path: String, detail: String)] = [
            ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData", "Intermediate build files and indexing data"),
            ("Xcode Archives", "Library/Developer/Xcode/Archives", "Old build archives and dSYMs"),
            ("Xcode iOS DeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport", "Symbols from connected physical iOS devices"),
            ("Xcode CoreSimulator Caches", "Library/Developer/CoreSimulator/Caches", "Simulator runtime caches and temporary files"),
            ("Homebrew Cache", "Library/Caches/Homebrew", "Downloaded Homebrew bottles and tarballs"),
            ("npm Cache", ".npm/_cacache", "Node.js npm package download cache"),
            ("Yarn Cache", "Library/Caches/Yarn", "Yarn package cache"),
            ("pnpm Cache", "Library/Caches/pnpm", "pnpm package manager cache"),
            ("CocoaPods Cache", "Library/Caches/CocoaPods", "CocoaPods dependency specifications and downloads"),
            ("Gradle Caches", ".gradle/caches", "Java and Kotlin Gradle dependency cache"),
            ("Cargo Registry Cache", ".cargo/registry/cache", "Rust Cargo crate registry cache"),
            ("Go Build Cache", "Library/Caches/go-build", "Golang build compilation cache")
        ]

        for target in targets {
            let url = userHomeURL.appendingPathComponent(target.path, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            let stats = directoryStats(at: url)
            guard stats.bytes > 0 else { continue }

            items.append(CleanItem(
                category: .developer,
                title: target.name,
                subtitle: "~/\(target.path)",
                url: url,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                lastModified: stats.lastModified,
                isSelected: CleanCategory.developer.defaultSelected,
                detail: target.detail
            ))
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans for residual support and cache folders belonging to apps no longer installed.
    func scanOrphanedData(installedApps: [StorageScanner.InstalledApp] = []) -> [CleanItem] {
        // Collect known installed bundle IDs and app names (lowercase for comparison)
        var knownBundleIds: Set<String> = []
        var knownNames: Set<String> = []

        let appRoots = StorageScanner.installedAppRoots()
        let scanner = StorageScanner(fileManager: fileManager)
        let appsToInspect = installedApps.isEmpty ? appRoots.flatMap { scanner.appURLs(under: $0) }.map { url in
            let info = scanner.readInfo(at: url)
            return StorageScanner.InstalledApp(bundleId: info.bundleId, name: info.name, url: url, groupContainers: info.applicationGroups)
        } : installedApps

        for app in appsToInspect {
            if let bid = app.bundleId {
                knownBundleIds.insert(bid.lowercased())
                if let suffix = bid.split(separator: ".").last {
                    knownNames.insert(String(suffix).lowercased())
                }
            }
            knownNames.insert(app.name.lowercased())
        }

        var items: [CleanItem] = []

        // Inspect Containers
        let containersURL = userHomeURL.appendingPathComponent("Library/Containers", isDirectory: true)
        if let contents = try? fileManager.contentsOfDirectory(at: containersURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                let name = url.lastPathComponent
                // Skip Apple system containers
                if name.hasPrefix("com.apple.") || isHogHunterIdentifier(name) { continue }
                if knownBundleIds.contains(name.lowercased()) { continue }

                let stats = directoryStats(at: url)
                guard stats.bytes > 0 else { continue }

                items.append(CleanItem(
                    category: .orphanedData,
                    title: name,
                    subtitle: "~/Library/Containers/\(name)",
                    url: url,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.orphanedData.defaultSelected,
                    detail: "Uninstalled application container"
                ))
            }
        }

        // Inspect Application Support
        let appSupportURL = userHomeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        if let contents = try? fileManager.contentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                let name = url.lastPathComponent
                if isAppleOrSystemFolder(name) || isHogHunterIdentifier(name) { continue }
                if knownBundleIds.contains(name.lowercased()) || knownNames.contains(name.lowercased()) { continue }

                let stats = directoryStats(at: url)
                guard stats.bytes > 0 else { continue }

                items.append(CleanItem(
                    category: .orphanedData,
                    title: name,
                    subtitle: "~/Library/Application Support/\(name)",
                    url: url,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.orphanedData.defaultSelected,
                    detail: "Leftover application data from removed app"
                ))
            }
        }

        // Inspect Saved Application State
        let savedStateURL = userHomeURL.appendingPathComponent("Library/Saved Application State", isDirectory: true)
        if let contents = try? fileManager.contentsOfDirectory(at: savedStateURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                let name = url.lastPathComponent
                let bundleId = name.replacingOccurrences(of: ".savedState", with: "")
                if bundleId.hasPrefix("com.apple.") || isHogHunterIdentifier(bundleId) { continue }
                if knownBundleIds.contains(bundleId.lowercased()) { continue }

                let stats = directoryStats(at: url)
                guard stats.bytes > 0 else { continue }

                items.append(CleanItem(
                    category: .orphanedData,
                    title: name,
                    subtitle: "~/Library/Saved Application State/\(name)",
                    url: url,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.orphanedData.defaultSelected,
                    detail: "Saved state from uninstalled app"
                ))
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans user folders (Downloads, Documents, Desktop) for files >100 MB or untouched >6 months.
    func scanLargeAndOldFiles() -> [CleanItem] {
        var items: [CleanItem] = []
        let searchDirectories = ["Downloads", "Documents", "Desktop"]
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        let largeThreshold: UInt64 = 100 * 1024 * 1024 // 100 MB

        let keys: Set<URLResourceKey> = [
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey
        ]

        for folder in searchDirectories {
            let dirURL = userHomeURL.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: dirURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var count = 0
            for case let fileURL as URL in enumerator {
                count += 1
                if count > 20_000 { break } // Protect against runaway directories

                // Never scan into git repos
                if fileURL.lastPathComponent == ".git" {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true && values.isPackage != true { continue }

                let allocated = values.fileAllocatedSize ?? 0
                let logical = values.fileSize ?? 0
                let size = allocated > 0 ? UInt64(allocated) : UInt64(logical)
                let modDate = values.contentModificationDate

                let isLarge = size >= largeThreshold
                let isOld = (modDate != nil && modDate! < sixMonthsAgo)

                if isLarge || isOld {
                    var reasons: [String] = []
                    if isLarge { reasons.append(">100 MB (\(HogFormat.memory(size)))") }
                    if isOld, let mod = modDate {
                        let df = DateFormatter()
                        df.dateStyle = .medium
                        reasons.append("Last modified: \(df.string(from: mod))")
                    }

                    items.append(CleanItem(
                        category: .largeAndOldFiles,
                        title: fileURL.lastPathComponent,
                        subtitle: fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                        url: fileURL,
                        bytes: size,
                        fileCount: 1,
                        lastModified: modDate,
                        isSelected: false, // Never auto-select user files
                        detail: reasons.joined(separator: ", ")
                    ))
                }
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Cleaning Execution

    /// Deletes the selected items safely.  Non-trash items are sent to the macOS Trash (`trashItem`).
    /// Trash items are removed permanently from `~/.Trash/`.
    func clean(items: [CleanItem],
               progress: ((Double, String) -> Void)? = nil) async -> CleanResult {
        var reclaimed: UInt64 = 0
        var removedCount = 0
        var errors: [String] = []

        let totalItems = max(1, items.count)

        for (index, item) in items.enumerated() {
            await Task.yield()
            let progressFraction = Double(index) / Double(totalItems)
            progress?(progressFraction, item.title)

            guard isSafeToDelete(url: item.url, category: item.category) else {
                errors.append("Safety check failed for path: \(item.url.path)")
                continue
            }

            do {
                if item.category == .trash {
                    // Item is already in the trash, so remove it permanently
                    try fileManager.removeItem(at: item.url)
                } else {
                    // Safe removal: move to macOS Trash
                    var trashedURL: NSURL?
                    try fileManager.trashItem(at: item.url, resultingItemURL: &trashedURL)
                }
                reclaimed &+= item.bytes
                removedCount += 1
            } catch {
                errors.append("Failed to clean \(item.title): \(error.localizedDescription)")
            }
        }

        progress?(1.0, "Complete")

        return CleanResult(
            bytesReclaimed: reclaimed,
            itemsRemoved: removedCount,
            errors: errors,
            cleanedAt: Date()
        )
    }

    // MARK: - Safety Guard

    /// Validates whether a file or directory is safe to clean.
    func isSafeToDelete(url: URL, category: CleanCategory) -> Bool {
        let path = (url.path as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath

        // Disallow root or critical system directories
        let prohibitedPrefixes = [
            "/System", "/Library", "/usr", "/bin", "/sbin", "/Applications", "/Users",
            home,
            home + "/Library",
            home + "/Desktop",
            home + "/Documents",
            home + "/Downloads",
            home + "/Code",
            home + "/apps"
        ]

        if prohibitedPrefixes.contains(path) {
            return false
        }

        // Never touch Hog Hunter itself
        if isHogHunterIdentifier(path) {
            return false
        }

        // Never touch git repositories
        if path.contains("/.git/") || path.hasSuffix("/.git") {
            return false
        }

        // Category-specific bounds
        switch category {
        case .userCaches:
            let cachesPrefix = home + "/Library/Caches/"
            return path.hasPrefix(cachesPrefix) && path != cachesPrefix

        case .logsAndDiagnostics:
            let logsPrefix = home + "/Library/Logs/"
            let crashPrefix = home + "/Library/Application Support/CrashReporter/"
            return (path.hasPrefix(logsPrefix) && path != logsPrefix) ||
                   (path.hasPrefix(crashPrefix) && path != crashPrefix)

        case .trash:
            let trashPrefix = home + "/.Trash/"
            return path.hasPrefix(trashPrefix) && path != trashPrefix

        case .developer:
            let allowedDeveloperPrefixes = [
                home + "/Library/Developer/Xcode/DerivedData/",
                home + "/Library/Developer/Xcode/Archives/",
                home + "/Library/Developer/Xcode/iOS DeviceSupport/",
                home + "/Library/Developer/CoreSimulator/Caches/",
                home + "/Library/Caches/Homebrew/",
                home + "/.npm/_cacache/",
                home + "/Library/Caches/Yarn/",
                home + "/.cache/yarn/",
                home + "/Library/Caches/pnpm/",
                home + "/.local/share/pnpm/store/",
                home + "/Library/Caches/CocoaPods/",
                home + "/.gradle/caches/",
                home + "/.cargo/registry/cache/",
                home + "/Library/Caches/go-build/"
            ]
            return allowedDeveloperPrefixes.contains { path.hasPrefix($0) }

        case .orphanedData:
            let allowedOrphanPrefixes = [
                home + "/Library/Containers/",
                home + "/Library/Application Support/",
                home + "/Library/Saved Application State/",
                home + "/Library/WebKit/",
                home + "/Library/HTTPStorage/"
            ]
            guard allowedOrphanPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
            // Ensure it's not the directory itself
            return !allowedOrphanPrefixes.contains { path == $0 || path == ($0 as NSString).substring(to: $0.count - 1) }

        case .largeAndOldFiles:
            let allowedUserPrefixes = [
                home + "/Downloads/",
                home + "/Documents/",
                home + "/Desktop/"
            ]
            return allowedUserPrefixes.contains { path.hasPrefix($0) && path != $0 }
        }
    }

    // MARK: - Directory Stats Helper

    /// Computes allocated bytes, file count, and last modification date of a directory or file.
    func directoryStats(at url: URL, maxDepth: Int = 10, fileCap: Int = 25_000) -> (bytes: UInt64, fileCount: Int, lastModified: Date?) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return (0, 0, nil)
        }

        let keys: Set<URLResourceKey> = [
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .contentModificationDateKey
        ]

        if !isDir.boolValue {
            guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0, nil) }
            let allocated = values.fileAllocatedSize ?? 0
            let logical = values.fileSize ?? 0
            let bytes = allocated > 0 ? UInt64(allocated) : UInt64(logical)
            return (bytes, 1, values.contentModificationDate)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return (0, 0, nil)
        }

        var totalBytes: UInt64 = 0
        var totalCount = 0
        var latestDate: Date?

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true { continue }

            totalCount += 1
            if totalCount > fileCap { break }

            let allocated = values.fileAllocatedSize ?? 0
            let logical = values.fileSize ?? 0
            totalBytes &+= allocated > 0 ? UInt64(allocated) : UInt64(logical)

            if let date = values.contentModificationDate {
                if latestDate == nil || date > latestDate! {
                    latestDate = date
                }
            }
        }

        return (totalBytes, totalCount, latestDate)
    }

    // MARK: - Internal Helpers

    private var userHomeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private func isHogHunterIdentifier(_ string: String) -> Bool {
        let lower = string.lowercased()
        return lower.contains("hoghunter") || lower.contains("simplewithus.hoghunter") || lower.contains("jayservices.hoghunter")
    }

    private func isAppleOrSystemFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("com.apple.") || lower == "apple" || lower == "icloud" { return true }
        let systemNames: Set<String> = [
            "addressbook", "callhistorydb", "callhistorytransactions", "cloudkit",
            "coreparsec", "dock", "dvd player", "knowledge", "quick look", "syncservices"
        ]
        return systemNames.contains(lower)
    }
}
