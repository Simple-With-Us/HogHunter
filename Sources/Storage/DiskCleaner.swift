import Foundation
import Darwin

/// Categories of reclaimable disk clutter supported by Hog Hunter's disk cleaner.
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
    /// AI agent transcripts, model download temp files, and BotFleet update installers.
    case aiArtifacts
    /// Local AI and LLM model weights (.gguf, .safetensors, .bin) from Ollama, Hugging Face, LM Studio, Whisper.
    case localAIModels
    /// Large files (>100 MB) or old files (>6 months) in user working folders (Downloads, Documents, Desktop).
    case largeAndOldFiles
    /// APFS local Time Machine snapshots pinning deleted storage blocks.
    case apfsSnapshots
    /// Temporary files meeting the local untouched-age policy, excluding
    /// worktrees, source projects, conversion staging, locks, and symlinks.
    case tempFiles
    /// Stale tool-made backups an agent left behind (Cursor database backups
    /// `state.vscdb.bak-*`), older than 7 days.  The live files are never listed.
    case staleBackups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: return "User Caches"
        case .logsAndDiagnostics: return "Logs & Diagnostics"
        case .trash: return "Trash Bins"
        case .developer: return "Developer Junk"
        case .orphanedData: return "Orphaned App Leftovers"
        case .aiArtifacts: return "AI & Agent Junk"
        case .localAIModels: return "Local AI & LLM Models"
        case .largeAndOldFiles: return "Large & Old Files"
        case .apfsSnapshots: return "APFS Local Snapshots"
        case .tempFiles: return "Temp Files"
        case .staleBackups: return "Stale Backups"
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
            return "Coding app caches, Xcode build artifacts, and package manager caches."
        case .orphanedData:
            return "Support folders remaining from applications no longer installed."
        case .aiArtifacts:
            return "Inactive AI agent session transcripts (>7 days) and temporary update downloads."
        case .localAIModels:
            return "Downloaded LLM and model weights (.gguf, .safetensors, .bin) from Ollama, Hugging Face, LM Studio, and Whisper."
        case .largeAndOldFiles:
            return "Files over 100 MB, or over 20 MB untouched for 6+ months."
        case .apfsSnapshots:
            return "Local Time Machine backup snapshots pinning deleted disk blocks on APFS containers."
        case .tempFiles:
            return "Temporary files in /tmp meeting the configured untouched time.\u{00A0} Preserves Git checkouts, source projects, staging, locks, and links."
        case .staleBackups:
            return "Tool-made backups older than 7 days (Cursor database backups).\u{00A0} Live files are never listed."
        }
    }

    var icon: String {
        switch self {
        case .userCaches: return "arrow.triangle.2.circlepath"
        case .logsAndDiagnostics: return "doc.text.magnifyingglass"
        case .trash: return "trash"
        case .developer: return "hammer"
        case .orphanedData: return "app.dashed"
        case .aiArtifacts: return "sparkles"
        case .localAIModels: return "brain.head.profile"
        case .largeAndOldFiles: return "clock.arrow.circlepath"
        case .apfsSnapshots: return "camera.metering.matrix"
        case .tempFiles: return "timer"
        case .staleBackups: return "archivebox"
        }
    }

    var sortOrder: Int {
        switch self {
        case .userCaches: return 0
        case .logsAndDiagnostics: return 1
        case .trash: return 2
        case .developer: return 3
        case .orphanedData: return 4
        case .aiArtifacts: return 5
        case .localAIModels: return 6
        case .largeAndOldFiles: return 7
        case .apfsSnapshots: return 8
        case .tempFiles: return 9
        case .staleBackups: return 10
        }
    }

    /// Whether this category is restricted to the Extreme Clean tier.
    var isExtremeOnly: Bool {
        switch self {
        case .userCaches, .logsAndDiagnostics, .trash, .developer, .apfsSnapshots, .tempFiles, .staleBackups:
            return false
        case .orphanedData, .aiArtifacts, .localAIModels, .largeAndOldFiles:
            return true
        }
    }

    /// Whether this category is checked by default for one-click clean.
    var defaultSelected: Bool {
        switch self {
        case .userCaches, .logsAndDiagnostics, .trash, .developer, .orphanedData, .staleBackups:
            return true
        case .aiArtifacts, .localAIModels, .largeAndOldFiles, .apfsSnapshots, .tempFiles:
            // Large/old files, AI agent artifacts, local snapshots, and temp
            // files require explicit user review to prevent accidental deletion
            return false
        }
    }
}

/// Degrees of disk cleaning supported by Hog Hunter.
enum CleanTier: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Safe major clutter removal: caches, logs, trash, developer junk, and stale temp files.
    /// Preserves full recoverability via APFS snapshot & Trash Put-Back.
    case standard
    /// Aggressive deep clean: everything in standard PLUS orphaned app leftovers,
    /// stale AI agent transcripts/models (>7 days), and large/old files.
    case extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard Clean"
        case .extreme: return "Extreme Clean"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "Safe major clutter removal. Protected by APFS snapshot & Trash Put-Back."
        case .extreme: return "Deep scan of AI agent bloat, leftovers & large files."
        }
    }

    var badge: String {
        switch self {
        case .standard: return "Reversible"
        case .extreme: return "Deep / AI Artifacts"
        }
    }

    func isCategoryIncluded(_ category: CleanCategory) -> Bool {
        switch self {
        case .standard:
            return !category.isExtremeOnly
        case .extreme:
            return true
        }
    }
}

/// User exclusions for disk scanning and cleaning.
struct CleanerExclusions: Codable, Equatable, Sendable {
    var excludedCategories: Set<String> = [CleanCategory.apfsSnapshots.rawValue]
    var excludedPaths: [String] = []

    static let defaultsKey = "hoghunter.cleaner.exclusions"
    static let suiteName = "group.com.simplewithus.hoghunter"

    func isCategoryExcluded(_ category: CleanCategory) -> Bool {
        excludedCategories.contains(category.rawValue)
    }

    func isPathExcluded(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        for excluded in excludedPaths {
            let normalizedExcluded = (excluded as NSString).standardizingPath
            if normalized == normalizedExcluded || normalized.hasPrefix(normalizedExcluded + "/") {
                return true
            }
        }
        return false
    }

    mutating func toggleCategory(_ category: CleanCategory) {
        if excludedCategories.contains(category.rawValue) {
            excludedCategories.remove(category.rawValue)
        } else {
            excludedCategories.insert(category.rawValue)
        }
    }

    mutating func addPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !excludedPaths.contains(trimmed) {
            excludedPaths.append(trimmed)
        }
    }

    mutating func removePath(_ path: String) {
        excludedPaths.removeAll { $0 == path }
    }

    static func load() -> CleanerExclusions {
        load(from: sharedDefaults)
    }

    static func load(from defaults: UserDefaults) -> CleanerExclusions {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(CleanerExclusions.self, from: data) else {
            return CleanerExclusions()
        }
        return decoded
    }

    func save() {
        save(to: CleanerExclusions.sharedDefaults)
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: CleanerExclusions.defaultsKey)
        }
    }

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Serializes every read-modify-write of the stored exclusions.  The Mac
    /// panel, the Settings window and the phone's `/v1/exclusions` route all
    /// edit the same stored value from different threads.  Each used to load
    /// once and later save its own copy, so the last writer silently undid an
    /// edit made elsewhere in the meantime.
    private static let updateLock = NSLock()

    /// Loads the stored value, applies `mutate`, saves, and returns the result.
    /// Always edit through this, never through a copy held from an earlier load.
    @discardableResult
    static func update(in defaults: UserDefaults? = nil, _ mutate: (inout CleanerExclusions) -> Void) -> CleanerExclusions {
        updateLock.lock()
        defer { updateLock.unlock() }
        let target = defaults ?? sharedDefaults
        var current = load(from: target)
        mutate(&current)
        current.save(to: target)
        return current
    }
}

/// Small read-only scan commands use a deadline and file output so neither a
/// full pipe nor a child ignoring TERM can indefinitely hold discovery open.
enum CleanerScanCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 1) -> Data? {
        guard !Task.isCancelled, timeout > 0 else { return nil }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("hh-scan-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { return nil }
        guard let output = try? FileHandle(forWritingTo: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if exited.wait(timeout: .now() + 0.02) == .success {
                guard process.terminationStatus == 0,
                      let input = try? FileHandle(forReadingFrom: outputURL) else { return nil }
                defer { try? input.close() }
                // Refuse truncated inventory rather than treating its prefix as complete.
                guard let data = try? input.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
                return data
            }
        }
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 0.1) != .success, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 0.1)
        }
        return nil
    }
}

/// Helper that manages Apple APFS local snapshots for safe rollback before disk cleaning operations.
enum SnapshotSafety {
    /// Attempts to create an APFS local snapshot via `tmutil localsnapshot`.
    /// Returns the snapshot date/identifier on success, or nil if unavailable.
    static func createLocalSnapshot() -> (success: Bool, snapshotName: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["localsnapshot"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                if let line = output.components(separatedBy: .newlines).first(where: { $0.contains("Created local snapshot with date:") }) {
                    let parts = line.components(separatedBy: ": ")
                    return (true, parts.last?.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return (true, "APFS Local Snapshot")
            }
            return (false, nil)
        } catch {
            return (false, nil)
        }
    }

    /// Lists active APFS local Time Machine snapshots on the system.
    static func listLocalSnapshots() -> [String]? {
        guard let data = CleanerScanCommand.run(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"]) else { return nil }
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    /// Holds the in-flight `tmutil thinlocalsnapshots` child so a cancelled clean can terminate it.
    private static let thinProcessLock = NSLock()
    private static var activeThinProcess: Process?

    /// Terminates any in-flight thin child.  Safe to call from a cancellation handler.
    static func cancelActiveThin() {
        thinProcessLock.lock()
        let process = activeThinProcess
        activeThinProcess = nil
        thinProcessLock.unlock()
        process?.terminate()
    }

    /// Safely thins local Time Machine snapshots to reclaim space pinned by deleted files.
    /// Uses tmutil thinlocalsnapshots with urgency level 4 (most aggressive reclamation).
    /// Observes cooperative cancellation by registering the child Process so
    /// `cancelActiveThin()` can terminate it mid-flight.
    static func thinLocalSnapshots(amountInBytes: Int64 = 999_999_999_999, urgency: Int = 4) -> (success: Bool, thinnedCount: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["thinlocalsnapshots", "/", String(amountInBytes), String(urgency)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            thinProcessLock.lock()
            activeThinProcess = process
            thinProcessLock.unlock()
            defer {
                thinProcessLock.lock()
                if activeThinProcess === process {
                    activeThinProcess = nil
                }
                thinProcessLock.unlock()
            }
            try process.run()
            // Drain before waiting and close the read end: a child that fills
            // the ~64 KB pipe buffer blocks on write(2), and an unclosed handle
            // leaks across every thin call.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            let thinned = output.components(separatedBy: .newlines)
                .filter { $0.contains("com.apple.TimeMachine.") }
            // SIGTERM from cancelActiveThin yields a non-zero status; treat as cancelled failure.
            return (process.terminationStatus == 0, process.terminationStatus == 0 ? max(1, thinned.count) : thinned.count)
        } catch {
            try? pipe.fileHandleForReading.close()
            return (false, 0)
        }
    }

    /// Parse the `tmutil listlocalsnapshots` line format.
    ///
    /// Real output looks like:
    ///     com.apple.TimeMachine.2026-10-05-062128.local
    /// Older snapshots and test fixtures sometimes drop the trailing `.local`.
    /// The header line `Snapshots for disk /` is filtered by the call site, but
    /// we still defend against it here so tests can hand us raw output.
    static func parseSnapshotNames(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") }
    }

    /// The bytes that APFS counts as purgeable on the startup disk.
    ///
    /// `volumeAvailableCapacity` is what the Finder shows as free and *does not*
    /// include purgeable space; `volumeAvailableCapacityForImportantUsage`
    /// counts purgeable as available, which is the same number the panel's
    /// Storage card uses (`DiskSpace.current()` in `Models.swift`).  The
    /// difference is the high-water figure we can show next to a list of
    /// snapshots — we never thin more than the volume can reclaim, and we
    /// never claim a snapshot holds more bytes than the volume has free.
    static func purgeableBytes(at mount: String = "/") -> UInt64 {
        let url = URL(fileURLWithPath: mount)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return 0 }
        let free = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        // purgeable >= 0 is the only constraint here: APFS never reports the
        // "important" number as smaller than the literal free number, but if
        // something exotic ever makes it so, clamp rather than wrap.
        return important >= free ? important - free : 0
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
    /// True when a bounded size walk is incomplete; `bytes` is a measured
    /// lower bound ("at least N"), not an exact size.
    var isApproximate: Bool = false
    var lastModified: Date?
    var isSelected: Bool
    var detail: String?
    var isExternal: Bool
    var volumeName: String
    var isSymlink: Bool

    init(
        category: CleanCategory,
        title: String,
        subtitle: String,
        url: URL,
        bytes: UInt64,
        fileCount: Int,
        isApproximate: Bool = false,
        lastModified: Date?,
        isSelected: Bool,
        detail: String? = nil,
        isExternal: Bool? = nil,
        volumeName: String? = nil,
        isSymlink: Bool? = nil
    ) {
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.bytes = bytes
        self.fileCount = fileCount
        self.isApproximate = isApproximate
        self.lastModified = lastModified
        self.isSelected = isSelected
        self.detail = detail

        let detectedSymlink = isSymlink ?? ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false)
        self.isSymlink = detectedSymlink

        if let isExternal = isExternal, let volumeName = volumeName {
            self.isExternal = isExternal
            self.volumeName = volumeName
        } else {
            let (ext, vol) = DiskCleaner.detectVolume(for: url)
            self.isExternal = isExternal ?? ext
            self.volumeName = volumeName ?? vol
        }
    }

    var path: String { url.path }

    var canRevealInFinder: Bool {
        category != .apfsSnapshots && FileManager.default.fileExists(atPath: url.path)
    }

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

    var internalSelectedBytes: UInt64 {
        items.filter { $0.isSelected && !$0.isExternal }.reduce(0 as UInt64) { $0 &+ $1.bytes }
    }

    var externalSelectedBytes: UInt64 {
        items.filter { $0.isSelected && $0.isExternal }.reduce(0 as UInt64) { $0 &+ $1.bytes }
    }

    var formattedTotalSize: String {
        HogFormat.memory(totalBytes)
    }

    /// True when any item's size walk hit its file cap, so the category
    /// total is a lower bound, not an exact size.
    var anyApproximate: Bool {
        items.contains { $0.isApproximate }
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
    var tier: CleanTier
    var isPartial: Bool = false
    var incompleteCategories: [CleanCategory] = []

    init(categories: [CleanCategoryReport], totalBytes: UInt64, totalSelectedBytes: UInt64, scannedAt: Date, tier: CleanTier = .standard, isPartial: Bool = false, incompleteCategories: [CleanCategory] = []) {
        self.isPartial = isPartial
        self.incompleteCategories = incompleteCategories
        self.categories = categories
        self.totalBytes = totalBytes
        self.totalSelectedBytes = totalSelectedBytes
        self.scannedAt = scannedAt
        self.tier = tier
    }

    var totalSelectedInternalBytes: UInt64 {
        categories.reduce(0 as UInt64) { $0 &+ $1.internalSelectedBytes }
    }

    var totalSelectedExternalBytes: UInt64 {
        categories.reduce(0 as UInt64) { $0 &+ $1.externalSelectedBytes }
    }

    var formattedTotalSize: String {
        HogFormat.memory(totalBytes)
    }

    /// True when any item's size walk hit its file cap, so totals built from
    /// this report are lower bounds, not exact sizes.
    var anyApproximate: Bool {
        isPartial || categories.contains { $0.anyApproximate }
    }

    var formattedSelectedSize: String {
        HogFormat.memory(totalSelectedBytes)
    }

    var formattedSelectedInternalSize: String {
        HogFormat.memory(totalSelectedInternalBytes)
    }

    var formattedSelectedExternalSize: String {
        HogFormat.memory(totalSelectedExternalBytes)
    }
}

/// Result returned after performing a clean operation.
struct CleanResult: Sendable {
    /// Estimated allocated bytes of successfully moved/removed items, not a free-space gain.
    var bytesReclaimed: UInt64
    /// Signed startup-volume available-space change observed during this run; concurrent writes affect it.
    var observedFreeBytesChange: Int64?
    var itemsRemoved: Int
    var errors: [String]
    var cleanedAt: Date
    var snapshotName: String?
    var tier: CleanTier
    /// Titles of items that actually succeeded (not merely selected).  Caps
    /// at 50 in the history writer; the engine keeps the full success list so
    /// a partial clean cannot credit untouched rows in the "Last cleanup" line.
    var removedItemTitles: [String]
    /// Category ids that had at least one successful removal, in first-success order.
    var removedCategoryIds: [String]

    init(bytesReclaimed: UInt64,
         itemsRemoved: Int,
         errors: [String],
         cleanedAt: Date,
         snapshotName: String? = nil,
         tier: CleanTier = .standard,
         removedItemTitles: [String] = [],
         removedCategoryIds: [String] = [],
         observedFreeBytesChange: Int64? = nil) {
        self.observedFreeBytesChange = observedFreeBytesChange
        self.bytesReclaimed = bytesReclaimed
        self.itemsRemoved = itemsRemoved
        self.errors = errors
        self.cleanedAt = cleanedAt
        self.snapshotName = snapshotName
        self.tier = tier
        self.removedItemTitles = removedItemTitles
        self.removedCategoryIds = removedCategoryIds
    }

    var formattedBytesReclaimed: String {
        HogFormat.memory(bytesReclaimed)
    }
}

/// Engine responsible for discovering reclaimable files and performing safe cleaning operations.
final class DiskCleaner: @unchecked Sendable {
    /// Rebuildable caches for IDEs, editors, and coding assistants.  Keep this
    /// list to cache roots only; session history and application state live in
    /// separate locations and are intentionally not included.
    private static let codingPlatformCacheTargets: [(name: String, path: String, detail: String)] = [
        ("Cursor Cache", "Library/Caches/com.todesktop.230313mzl4w4u92", "Cursor editor cache"),
        ("Cursor Update Cache", "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt", "Cursor updater staging"),
        ("Cursor Compile Cache", "Library/Caches/cursor-compile-cache", "Cursor compilation cache"),
        ("Cursor Sandbox Cache", "Library/Caches/com.anysphere.sand", "Cursor sandbox cache"),
        ("Visual Studio Code Cache", "Library/Caches/Code", "Visual Studio Code editor cache"),
        ("Visual Studio Code Cache", "Library/Caches/com.microsoft.VSCode", "Visual Studio Code editor cache"),
        ("Claude Desktop Cache", "Library/Caches/com.anthropic.claudefordesktop", "Claude desktop app cache"),
        ("Claude CLI Cache", "Library/Caches/claude-cli-nodejs", "Claude CLI package cache"),
        ("Codex Cache", "Library/Caches/Codex", "Codex app cache"),
        ("Antigravity Cache", "Library/Caches/com.google.antigravity", "Antigravity IDE cache"),
        ("Antigravity IDE Cache", "Library/Caches/com.google.antigravity-ide", "Antigravity IDE cache"),
        ("OpenCode Cache", "Library/Caches/ai.opencode.desktop", "OpenCode coding assistant cache"),
        ("Kimi Code Cache", "Library/Caches/kimi-code", "Kimi Code app cache"),
        ("Clutch Cache", "Library/Caches/codes.clutch.macos", "Clutch app cache"),
        ("BotFleet Cache", "Library/Caches/app.botfleet.control.macos", "BotFleet app cache"),
        ("SwiftPM Cache", "Library/Caches/org.swift.swiftpm", "Swift package downloads and build artifacts"),
        ("Swift Compiler Cache", "Library/Caches/swift-frontend", "Swift compiler cache"),
        ("Node Headers Cache", "Library/Caches/node-gyp", "Node.js native module headers"),
        ("Electron Cache", "Library/Caches/electron", "Electron runtime downloads"),
        ("Electron Builder Cache", "Library/Caches/electron-builder", "Electron packaging cache"),
        ("Deno Cache", "Library/Caches/deno", "Deno package and compilation cache"),
        ("Copilot Cache", "Library/Caches/copilot", "Copilot toolchain cache"),
        ("Playwright Cache", "Library/Caches/ms-playwright", "Playwright browser downloads"),
        ("Puppeteer Cache", "Library/Caches/puppeteer", "Puppeteer browser downloads"),
    ]

    enum ScanDepth: Sendable {
        case quick, deeper
        var duration: TimeInterval { self == .quick ? 8 : 45 }
        var targetDuration: TimeInterval { self == .quick ? 0.15 : 0.8 }
        var entries: Int { self == .quick ? 30_000 : 150_000 }
        var maxDepth: Int { self == .quick ? 10 : 32 }
    }

    /// One task owns this context, including its per-run memoization.  No filesystem
    /// timestamps are used to reuse observations across scans.
    private final class ScanContext: @unchecked Sendable {
        let depth: ScanDepth
        let deadline: TimeInterval
        let mountPaths: [String]
        var remaining: Int
        var incomplete = false
        var memo: [String: DirectoryStats] = [:]
        init(depth: ScanDepth, now: TimeInterval, mountPaths: [String]) {
            self.depth = depth
            deadline = now + depth.duration
            remaining = depth.entries
            self.mountPaths = mountPaths
        }
    }
    @TaskLocal private static var scanContext: ScanContext?

    private func withScanBudget<T>(_ operation: () -> T) -> T {
        let context = ScanContext(depth: .quick, now: scanUptime(), mountPaths: mountPathsProvider())
        return Self.$scanContext.withValue(context, operation: operation)
    }

    private func scanShouldStop() -> Bool {
        if Task.isCancelled { Self.scanContext?.incomplete = true; return true }
        guard let context = Self.scanContext else { return false }
        if context.remaining <= 0 || scanUptime() >= context.deadline {
            context.incomplete = true
            return true
        }
        return false
    }

    private func markScanIncomplete() { Self.scanContext?.incomplete = true }

    /// Gate symlink destinations before Foundation can read their metadata.
    private func scanAllows(_ url: URL) -> Bool { scanURL(url) != nil }

    private func scanURL(_ url: URL) -> URL? {
        guard !scanShouldStop() else { return nil }
        let mounts = Self.scanContext?.mountPaths ?? mountPathsProvider()
        guard let path = DirectorySizeWalker.automaticCanonicalPath(url.path, mountPaths: mounts) else {
            // Missing roots are normal; unknown/access-denied roots cannot prove completeness.
            if errno != ENOENT { markScanIncomplete() }
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func scanSubpaths(at root: URL) throws -> [String] {
        guard scanAllows(root), let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { [self] _, _ in markScanIncomplete(); return false }) else { return [] }
        let deadline = scanUptime() + (Self.scanContext?.depth.targetDuration ?? 0.15)
        var paths: [String] = []
        while !scanShouldStop() {
            guard paths.count < 25_000, scanUptime() < deadline else { markScanIncomplete(); break }
            guard let entry = enumerator.nextObject() as? URL else { break }
            Self.scanContext?.remaining -= 1
            guard scanAllows(entry) else { enumerator.skipDescendants(); continue }
            if enumerator.level >= (Self.scanContext?.depth.maxDepth ?? 10) { markScanIncomplete(); enumerator.skipDescendants() }
            paths.append(String(entry.path.dropFirst(root.path.count + 1)))
        }
        return paths
    }

    private func scanFileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>? = nil) -> Bool {
        guard scanAllows(URL(fileURLWithPath: path)) else { return false }
        return fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    /// Enumerate without eager resource prefetch: the entry must pass the mount/link
    /// preflight before any resourceValues call.  Listings count directories as work.
    private func scanContentsOfDirectory(at url: URL, includingPropertiesForKeys: [URLResourceKey]?,
                                         options: FileManager.DirectoryEnumerationOptions = [],
                                         requireComplete: Bool = false) throws -> [URL] {
        guard scanAllows(url) else {
            if requireComplete { throw CocoaError(.fileReadUnknown) }
            return []
        }
        var incomplete = false
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil,
            options: options.union(.skipsSubdirectoryDescendants), errorHandler: { [self] _, _ in
                incomplete = true; markScanIncomplete(); return false
            }) else {
                markScanIncomplete()
                if requireComplete { throw CocoaError(.fileReadUnknown) }
                return []
            }
        let deadline = scanUptime() + (Self.scanContext?.depth.targetDuration ?? 0.15)
        var urls: [URL] = []
        while true {
            guard !scanShouldStop(), urls.count < 25_000, scanUptime() < deadline else {
                incomplete = true; markScanIncomplete(); break
            }
            guard let entry = enumerator.nextObject() as? URL else { break }
            Self.scanContext?.remaining -= 1
            if scanAllows(entry) { urls.append(entry) } else { incomplete = true }
        }
        if incomplete && requireComplete { throw CocoaError(.fileReadUnknown) }
        return urls
    }

    private let fileManager: FileManager
    private let freeBytesProvider: () -> UInt64?
    private let moveToTrash: (URL) throws -> Void
    private let scanUptime: () -> TimeInterval
    private let mountPathsProvider: () -> [String]
    /// Tests substitute a closure that does not call `tmutil`.
    private let makeSnapshot: () -> (success: Bool, snapshotName: String?)
    /// Tests substitute a closure that does not call `tmutil`.
    private let listSnapshots: (_ mount: String) -> [String]?
    /// Tests substitute a closure that does not call `URL.resourceValues`.
    private let purgeableProvider: (_ mount: String) -> UInt64
    /// Tests inject a temp home so scan-level behavior is verifiable without
    /// touching the real home directory.
    private let homeDirectory: URL?
    /// Tests inject a temp root so the temp-file scan is verifiable without
    /// touching the real `/tmp`.
    private let tempRootDirectory: URL?
    /// Tests inject a fixed worktree set; the default shells out to
    /// `git worktree list --porcelain`.
    private let worktreePathsProvider: () -> Set<String>
    private let tempPolicyProvider: () -> TempFileSafetyPolicy
    private let tempMetadataProvider: (URL) throws -> TempEntryMetadata
    private let tempNow: () -> Date
    private let tempEntryCap: Int
    private let tempUptime: () -> TimeInterval
    private let tempWalkTimeLimit: TimeInterval
    typealias TempEnumerationProvider = (URL, FileManager.DirectoryEnumerationOptions, ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
    private let tempEnumerationProvider: TempEnumerationProvider

    init(fileManager: FileManager = .default,
         freeBytesProvider: @escaping () -> UInt64? = { DiskSpace.current()?.freeBytes },
         moveToTrash: ((URL) throws -> Void)? = nil,
         scanUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         mountPathsProvider: @escaping () -> [String] = { MountedDriveStore.cachedMountRecords().map(\.path) },
         makeSnapshot: @escaping () -> (success: Bool, snapshotName: String?) = { SnapshotSafety.createLocalSnapshot() },
         listSnapshots: @escaping (String) -> [String]? = { _ in SnapshotSafety.listLocalSnapshots() },
         purgeableProvider: @escaping (String) -> UInt64 = { SnapshotSafety.purgeableBytes(at: $0) },
         homeDirectory: URL? = nil,
         tempRootDirectory: URL? = nil,
         worktreePathsProvider: (() -> Set<String>)? = nil,
         tempPolicyProvider: @escaping () -> TempFileSafetyPolicy = { TempFileSafetyPolicy.load() },
         tempMetadataProvider: @escaping (URL) throws -> TempEntryMetadata = TempEntryMetadata.read,
         tempNow: @escaping () -> Date = { Date() },
         tempEntryCap: Int = 25_000,
         tempUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         tempWalkTimeLimit: TimeInterval = 2,
         tempEnumerationProvider: TempEnumerationProvider? = nil) {
        self.mountPathsProvider = mountPathsProvider
        self.scanUptime = scanUptime
        self.freeBytesProvider = freeBytesProvider
        self.moveToTrash = moveToTrash ?? { url in
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        }
        self.fileManager = fileManager
        self.makeSnapshot = makeSnapshot
        self.listSnapshots = listSnapshots
        self.purgeableProvider = purgeableProvider
        self.homeDirectory = homeDirectory
        self.tempRootDirectory = tempRootDirectory
        self.worktreePathsProvider = worktreePathsProvider ?? Self.defaultWorktreePaths
        self.tempPolicyProvider = tempPolicyProvider
        self.tempMetadataProvider = tempMetadataProvider
        self.tempNow = tempNow
        self.tempEntryCap = tempEntryCap
        self.tempUptime = tempUptime
        self.tempWalkTimeLimit = tempWalkTimeLimit
        self.tempEnumerationProvider = tempEnumerationProvider ?? { url, options, handler in
            fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: options, errorHandler: handler)
        }
    }

    // MARK: - Full Scan

    /// Cooperative bounded scan; one kernel metadata call can still block beyond a budget.
    func scan(installedApps: [StorageScanner.InstalledApp] = [],
              tier: CleanTier = .standard,
              exclusions: CleanerExclusions = CleanerExclusions.load(),
              depth: ScanDepth = .quick,
              categories selectedCategories: Set<CleanCategory>? = nil,
              partialReport: ((CleanScanReport) -> Void)? = nil,
              progress: ((String) -> Void)? = nil) async -> CleanScanReport {
        let context = ScanContext(depth: depth, now: scanUptime(), mountPaths: mountPathsProvider())
        return await Self.$scanContext.withValue(context) {
            var reports: [CleanCategoryReport] = []
            var incomplete: [CleanCategory] = []
            let categories = CleanCategory.allCases
                .filter { (selectedCategories?.contains($0) ?? true) && tier.isCategoryIncluded($0) && !exclusions.isCategoryExcluded($0) }
                .sorted { $0.sortOrder < $1.sortOrder }
            func report(inFlight: Bool = false) -> CleanScanReport {
                CleanScanReport(categories: reports,
                    totalBytes: reports.reduce(0) { $0 &+ $1.totalBytes },
                    totalSelectedBytes: reports.reduce(0) { $0 &+ $1.selectedBytes },
                    scannedAt: Date(), tier: tier,
                    isPartial: inFlight || !incomplete.isEmpty || reports.count < categories.count,
                    incompleteCategories: incomplete)
            }
            for category in categories {
                guard !scanShouldStop() else {
                    incomplete.append(contentsOf: categories.filter { candidate in !reports.contains { $0.category == candidate } })
                    break
                }
                await Task.yield()
                context.incomplete = false
                progress?(category.title)
                let items = scanCategory(category, installedApps: installedApps)
                    .filter { !scanShouldStop() && !exclusions.isPathExcluded($0.path) && ($0.category == .apfsSnapshots || scanAllows($0.url)) && !isHandsOff($0.url) }
                if context.incomplete || items.contains(where: \.isApproximate) { incomplete.append(category) }
                reports.append(CleanCategoryReport(category: category, items: items,
                    totalBytes: items.reduce(0) { $0 &+ $1.bytes },
                    selectedBytes: items.filter(\.isSelected).reduce(0) { $0 &+ $1.bytes }, itemCount: items.count))
                partialReport?(report(inFlight: true))
            }
            return report()
        }
    }

    /// Scans a single category.
    func scanCategory(_ category: CleanCategory, installedApps: [StorageScanner.InstalledApp] = []) -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanCategory(category, installedApps: installedApps) } }
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
        case .aiArtifacts:
            return scanAIArtifacts()
        case .localAIModels:
            return scanLocalAIModels()
        case .largeAndOldFiles:
            return scanLargeAndOldFiles()
        case .apfsSnapshots:
            return scanAPFSSnapshots()
        case .tempFiles:
            return scanTempFiles()
        case .staleBackups:
            return scanStaleBackups()
        }
    }

    /// Scans for active APFS Time Machine local snapshots pinning deleted storage blocks.
    /// Per-snapshot sizes are not exposed by `tmutil`, so the bytes for each row
    /// come from the volume's purgeable high-water mark divided by the snapshot
    /// count.  When listing fails or returns empty, a single placeholder row is
    /// emitted carrying the full purgeable figure so the panel still has
    /// something to show and the clean can still thin.
    func scanAPFSSnapshots() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanAPFSSnapshots() } }
        let listed = listSnapshots("/")
        if listed == nil { markScanIncomplete() }
        let snapshotNames = listed ?? []
        let purgeable = purgeableProvider("/")

        if snapshotNames.isEmpty {
            guard purgeable > 0 else { return [] }
            return [CleanItem(
                category: .apfsSnapshots,
                title: "Local Time Machine Snapshots",
                subtitle: "Thin purgeable space on /",
                url: URL(fileURLWithPath: "/.snapshots/com.apple.TimeMachine.aggregate"),
                bytes: purgeable,
                fileCount: 0,
                lastModified: nil,
                isSelected: CleanCategory.apfsSnapshots.defaultSelected,
                detail: "Purgeable space held by local snapshots"
            )]
        }

        let bytesPer = purgeable / UInt64(snapshotNames.count)
        return snapshotNames.map { name in
            CleanItem(
                category: .apfsSnapshots,
                title: name,
                subtitle: "Time Machine Local Snapshot",
                url: URL(fileURLWithPath: "/.snapshots/\(name)"),
                bytes: bytesPer,
                fileCount: 1,
                lastModified: nil,
                isSelected: CleanCategory.apfsSnapshots.defaultSelected,
                detail: "Local Time Machine snapshot — thinning is safe"
            )
        }
    }

    // MARK: - Category Scanners

    /// Age is a minimum eligibility boundary, never proof of abandonment.
    static let tempFileStaleThreshold = TempFileSafetyPolicy().minimumUntouchedInterval

    /// Marker files whose presence inside a directory means an active
    /// conversion batch owns it.  Batch staging is pipeline-owned; the
    /// pipeline cleans up after itself, so the cleaner never touches it.
    static let batchActiveMarkerNames: Set<String> = [
        ".batch-active", "BATCH_ACTIVE", "export_state.json",
        ".converting", ".export-in-progress"
    ]

    /// Directory name prefixes owned by the video conversion pipeline's
    /// batch staging (e.g. `vc-012`).  Always skipped, even without markers.
    static let batchStagingNamePrefixes = ["vc-"]

    /// One bounded walk checks age, protections, and size together.  Incomplete
    /// walks produce no suggestion, including unchecked rows.  Temp items still
    /// require explicit review: idle plain files have no inferred backup status.
    func scanTempFiles() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanTempFiles() } }
        var enumerationFailed = false
        guard scanAllows(tempRootURL) else { return [] }
        guard let entries = tempEnumerationProvider(tempRootURL,
            [.skipsSubdirectoryDescendants], { _, _ in enumerationFailed = true; return false }) else { return [] }
        let policy = tempPolicyProvider()
        let cutoff = tempNow().addingTimeInterval(-policy.minimumUntouchedInterval)
        let worktrees = Set(worktreePathsProvider().map(Self.resolvedPath))
        let deadline = tempUptime() + min(10, Self.scanContext?.depth.targetDuration ?? 10)
        var visited = 0
        var items: [CleanItem] = []
        while let entry = entries.nextObject() {
            guard !scanShouldStop(), !enumerationFailed, visited < tempEntryCap,
                  tempUptime() < deadline, let url = entry as? URL else { markScanIncomplete(); return [] }
            visited += 1
            Self.scanContext?.remaining -= 1
            guard scanAllows(url) else { continue }
            guard let stats = eligibleTempEntry(url, cutoff: cutoff, worktrees: worktrees),
                  stats.bytes > 0 else { continue }
            let itemURL = URL(fileURLWithPath: Self.resolvedPath(url.path))
            items.append(CleanItem(
                category: .tempFiles, title: url.lastPathComponent, subtitle: itemURL.path,
                url: itemURL, bytes: stats.bytes, fileCount: stats.fileCount,
                lastModified: stats.lastModified, isSelected: false,
                detail: "Temporary file — untouched for at least \(policy.hoursLabel) hours; review before cleaning"
            ))
        }
        guard !enumerationFailed, !scanShouldStop(), policy == tempPolicyProvider() else { return [] }
        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Protect recognizable project material even when Git metadata was never
    /// created or was lost.  Never ask a network service whether work is backed up.
    static let tempProjectMarkers: Set<String> = [
        ".git", ".hg", ".svn", ".project_root", ".hoghunter-keep", ".keep",
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "package.swift", "project.yml", "cmakelists.txt", "makefile", "dockerfile",
        "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "setup.py",
        "pom.xml", "build.gradle", "gemfile", "composer.json", "tsconfig.json",
        "src", "sources"
    ]
    static let tempSourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py",
        "js", "jsx", "ts", "tsx", "vue", "svelte", "html", "css", "scss",
        "java", "kt", "kts", "rb", "php", "cs", "fs", "sh", "bash", "zsh",
        "sql", "ipynb", "xcodeproj", "xcworkspace", "sln", "csproj",
        "md", "rst", "tex", "r", "jl", "pl", "lua", "ex", "exs", "dart"
    ]

    private func protectedTempName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return Self.tempProjectMarkers.contains(name)
            || Self.tempSourceExtensions.contains(url.pathExtension.lowercased())
            || name.hasSuffix(".lock")
            || Self.batchActiveMarkerNames.contains(url.lastPathComponent)
            || Self.batchStagingNamePrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// nil means protected, recent, or unverified.  Do not skip packages or
    /// hidden entries: a checkout, lock, or new write at any depth protects all
    /// of its enclosing candidate.  Symlinks protect the container without being
    /// followed.  Every directory listing and metadata failure fails closed.
    private func eligibleTempEntry(_ url: URL, cutoff: Date, worktrees: Set<String>) -> DirectoryStats? {
        let root = tempRootURL.path
        let path = Self.resolvedPath(url.path)
        // Candidates are direct children only; a forged report cannot clean a
        // nested file while sidestepping a parent's project/lock protection.
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == root,
              path.hasPrefix(root + "/"), path != root,
              !worktrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }),
              !hasAdjacentTempLock(url) else { return nil }
        let deadline = tempUptime() + min(tempWalkTimeLimit, Self.scanContext?.depth.targetDuration ?? tempWalkTimeLimit)
        var observations: [(URL, TempEntryMetadata)] = []
        var bytes: UInt64 = 0
        var count = 0
        var latestModified: Date?
        func inspect(_ entry: URL) -> TempEntryMetadata? {
            guard scanAllows(entry), !scanShouldStop(), observations.count < tempEntryCap,
                  tempUptime() < deadline, !protectedTempName(entry),
                  let info = try? tempMetadataProvider(entry), !info.isSymbolicLink,
                  info.isDirectory || info.isRegularFile,
                  info.latestActivity.timeIntervalSince1970.isFinite,
                  info.latestActivity <= cutoff else { return nil }
            Self.scanContext?.remaining -= 1
            observations.append((entry, info))
            latestModified = max(latestModified ?? info.modified, info.modified)
            if info.isRegularFile { bytes &+= info.bytes; count += 1 }
            return info
        }
        guard let rootInfo = inspect(url) else { return nil }
        if rootInfo.isDirectory {
            var enumerationFailed = false
            guard let entries = tempEnumerationProvider(url,
                [], { _, _ in enumerationFailed = true; return false }) else { return nil }
            while let entry = entries.nextObject() {
                guard !enumerationFailed, let child = entry as? URL, inspect(child) != nil else { return nil }
            }
            guard !enumerationFailed else { return nil }
        }
        // A second metadata read (no second directory traversal) detects
        // changes visible at these observations, including inode replacement
        // and directory activity since enumeration.  Later writes/replacements
        // are not atomically excluded from the path-based Trash operation.
        // Enumeration records each parent before its descendants.  Reversing
        // that order verifies every containing directory after its children.
        for (entry, observed) in observations.reversed() {
            guard !scanShouldStop(), tempUptime() < deadline,
                  let current = try? tempMetadataProvider(entry), current == observed else { return nil }
        }
        guard !hasAdjacentTempLock(url) else { return nil }
        return DirectoryStats(bytes: bytes, fileCount: count, lastModified: latestModified)
    }

    /// lstat sees even dangling lock symlinks.  Permission and I/O failures
    /// count as locked; only a missing sentinel allows the candidate through.
    private func hasAdjacentTempLock(_ url: URL) -> Bool {
        for name in [url.lastPathComponent + ".lock", "." + url.lastPathComponent + ".lock"] {
            let lock = url.deletingLastPathComponent().appendingPathComponent(name)
            do { _ = try TempEntryMetadata.read(lock); return true }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { continue }
            catch { return true }
        }
        return false
    }

    /// Fresh local policy and metadata checks are shared by all deletion paths,
    /// including native regimen and companion cleans of an older report.
    private func isTempEntrySafeNow(_ url: URL) -> Bool {
        let policy = tempPolicyProvider()
        let cutoff = tempNow().addingTimeInterval(-policy.minimumUntouchedInterval)
        return eligibleTempEntry(url, cutoff: cutoff,
            worktrees: Set(worktreePathsProvider().map(Self.resolvedPath))) != nil
            && policy == tempPolicyProvider()
    }

    /// Registered git worktree paths, via `git worktree list --porcelain`
    /// across the likely repo parents.  A failing git (not a repo, git
    /// missing) contributes nothing; the scan's top-level `.git` check still
    /// catches checkouts the provider misses.  Cached for `worktreeCacheTTL`
    /// so a scan does not fork git three times on every pass.
    private static let worktreeCacheLock = NSLock()
    private static var cachedWorktreePaths: (fetchedAt: Date, paths: Set<String>)?
    static let worktreeCacheTTL: TimeInterval = 300

    static func defaultWorktreePaths() -> Set<String> {
        worktreeCacheLock.lock()
        if let cached = cachedWorktreePaths,
           Date().timeIntervalSince(cached.fetchedAt) < worktreeCacheTTL {
            let paths = cached.paths
            worktreeCacheLock.unlock()
            return paths
        }
        worktreeCacheLock.unlock()

        let home = NSHomeDirectory()
        let roots = [home,
                     (home as NSString).appendingPathComponent("apps"),
                     (home as NSString).appendingPathComponent("Code")]
        let paths = roots.reduce(into: Set<String>()) { $0.formUnion(worktreePaths(in: $1)) }

        worktreeCacheLock.lock()
        cachedWorktreePaths = (Date(), paths)
        worktreeCacheLock.unlock()
        return paths
    }

    private static func worktreePaths(in root: String) -> Set<String> {
        guard let data = CleanerScanCommand.run(executable: "/usr/bin/git",
            arguments: ["-c", "core.fsmonitor=false", "-C", root, "worktree", "list", "--porcelain"]) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("worktree ") else { return nil }
                return resolvedPath(String(line.dropFirst("worktree ".count)))
            }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Known high-churn caches where deletion causes immediate large re-downloads over the network.
    /// These are unselected by default to prevent wasteful bandwidth and disk wear.
    static let highChurnCacheIdentifiers: [(pattern: String, reason: String)] = [
        ("com.spotify.client", "Spotify streaming & offline media cache (immediately re-downloads when played)"),
        ("com.apple.music", "Apple Music streaming audio cache (immediately re-downloads when played)"),
        ("com.apple.podcasts", "Apple Podcasts episode download cache"),
        ("com.apple.itunescloudd", "iTunes Cloud media streaming cache"),
        ("com.apple.applemediaservices", "Apple Media Services streaming cache"),
        ("com.google.googledrive", "Google Drive cloud file streaming cache (immediately re-downloads when accessed)"),
        ("dropbox", "Dropbox cloud file cache"),
        ("onedrive", "Microsoft OneDrive cloud file cache"),
        ("com.apple.safari", "Safari active web session & site cache"),
        ("google", "Chrome active web session & service worker cache"),
        ("huggingface", "Hugging Face AI model weights repository"),
        ("ollama", "Ollama local LLM model weights library")
    ]

    /// Scans `~/Library/Caches/` for user caches (skips Hog Hunter and developer package caches handled elsewhere).
    func scanUserCaches() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanUserCaches() } }
        let cachesURL = userHomeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        guard let contents = try? scanContentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        // Developer package managers that live in Caches are attributed to Developer category instead
        let developerCacheNames = Set([
            "Homebrew", "CocoaPods", "Yarn", "pnpm", "go-build", "pip", "com.apple.dt.Xcode",
            "dev.kdrag0n.MacVirt", "com.docker.docker"
        ] + Self.codingPlatformCacheTargets.compactMap { target -> String? in
            let components = target.path.split(separator: "/")
            guard components.count == 3, components[0] == "Library", components[1] == "Caches" else { return nil }
            return String(components[2])
        })

        var items: [CleanItem] = []
        for url in contents {
            if scanShouldStop() { break }
            let name = url.lastPathComponent
            if developerCacheNames.contains(name) { continue }
            if isHogHunterIdentifier(name) { continue }

            let stats = directoryStats(at: url)
            guard stats.bytes > 0 else { continue }

            let lowerName = name.lowercased()
            let highChurnMatch = Self.highChurnCacheIdentifiers.first { lowerName.contains($0.pattern) }
            let isHighChurn = highChurnMatch != nil
            let itemDetail = highChurnMatch?.reason

            items.append(CleanItem(
                category: .userCaches,
                title: name,
                subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                url: url,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                isApproximate: stats.isApproximate,
                lastModified: stats.lastModified,
                isSelected: isHighChurn ? false : CleanCategory.userCaches.defaultSelected,
                detail: itemDetail
            ))
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans `~/Library/Logs/` and crash reports for logs and diagnostics.
    func scanLogsAndDiagnostics() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanLogsAndDiagnostics() } }
        var items: [CleanItem] = []
        let logsURL = userHomeURL.appendingPathComponent("Library/Logs", isDirectory: true)

        if let contents = try? scanContentsOfDirectory(at: logsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                if scanShouldStop() { break }
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
                    isApproximate: stats.isApproximate,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.logsAndDiagnostics.defaultSelected,
                    detail: "Log files & diagnostic data"
                ))
            }
        }

        if scanShouldStop() { return items.sorted { $0.bytes > $1.bytes } }

        // DiagnosticReports folder
        let diagReportsURL = logsURL.appendingPathComponent("DiagnosticReports", isDirectory: true)
        if scanFileExists(atPath: diagReportsURL.path) && !items.contains(where: { $0.url == diagReportsURL }) {
            let stats = directoryStats(at: diagReportsURL)
            if stats.bytes > 0 {
                items.append(CleanItem(
                    category: .logsAndDiagnostics,
                    title: "Diagnostic Reports",
                    subtitle: "~/Library/Logs/DiagnosticReports",
                    url: diagReportsURL,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    isApproximate: stats.isApproximate,
                    lastModified: stats.lastModified,
                    isSelected: CleanCategory.logsAndDiagnostics.defaultSelected,
                    detail: "System crash dumps and diagnostic traces"
                ))
            }
        }

        if scanShouldStop() { return items.sorted { $0.bytes > $1.bytes } }

        // CrashReporter
        let crashReportsURL = userHomeURL.appendingPathComponent("Library/Application Support/CrashReporter", isDirectory: true)
        if scanFileExists(atPath: crashReportsURL.path) {
            let stats = directoryStats(at: crashReportsURL)
            if stats.bytes > 0 {
                items.append(CleanItem(
                    category: .logsAndDiagnostics,
                    title: "Crash Reporter Logs",
                    subtitle: "~/Library/Application Support/CrashReporter",
                    url: crashReportsURL,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    isApproximate: stats.isApproximate,
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
        if Self.scanContext == nil { return withScanBudget { scanTrash() } }
        let trashURL = userHomeURL.appendingPathComponent(".Trash", isDirectory: true)
        guard let contents = try? scanContentsOfDirectory(at: trashURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }

        var items: [CleanItem] = []
        for url in contents {
            if scanShouldStop() { break }
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
                isApproximate: stats.isApproximate,
                lastModified: stats.lastModified,
                isSelected: CleanCategory.trash.defaultSelected,
                detail: "Sitting in Trash"
            ))
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans developer build artifacts and package manager caches.
    func scanDeveloper() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanDeveloper() } }
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
            ("Go Build Cache", "Library/Caches/go-build", "Golang build compilation cache"),
            ("OrbStack Cache", "Library/Caches/dev.kdrag0n.MacVirt", "OrbStack temporary and network caches"),
            ("OrbStack Engine Cache", "Library/Group Containers/HUAQ24HBR6.dev.orbstack/Library/Caches", "OrbStack container engine caches"),
            ("Docker Buildx Cache", ".docker/buildx/cache", "Docker buildx local build cache"),
            ("Docker Desktop Cache", "Library/Caches/com.docker.docker", "Docker desktop temporary cache")
        ] + Self.codingPlatformCacheTargets

        for target in targets {
            if scanShouldStop() { break }
            let url = userHomeURL.appendingPathComponent(target.path, isDirectory: true)
            var isDir: ObjCBool = false
            guard scanFileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            let stats = directoryStats(at: url)
            guard stats.bytes > 0 else { continue }

            let highChurn = Self.highChurnCacheIdentifiers.first {
                url.lastPathComponent.lowercased().contains($0.pattern)
            }
            items.append(CleanItem(
                category: .developer,
                title: target.name,
                subtitle: "~/\(target.path)",
                url: url,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                isApproximate: stats.isApproximate,
                lastModified: stats.lastModified,
                isSelected: highChurn == nil && CleanCategory.developer.defaultSelected,
                detail: highChurn?.reason ?? target.detail
            ))
        }

        if !scanShouldStop() {
            // iOS Simulator Devices — installed simulators + runtimes.  Opt-in only:
            // other users may actively develop for iOS, and an auto-clean would force
            // a full re-download of every runtime on next boot.
            // By default, one primary iOS 27 simulator is preserved so BitRig and test
            // suites can run simulators without a forced re-download, with a separate option
            // to clean that primary iOS 27 simulator as well.
            let simDevicesURL = userHomeURL.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            var isDir: ObjCBool = false
            if scanFileExists(atPath: simDevicesURL.path, isDirectory: &isDir), isDir.boolValue {
                let deviceMetas = scanSimulatorDevices(at: simDevicesURL)
                let primary = primaryIOS27Simulator(in: deviceMetas)

                if let primary = primary {
                    let otherDevices = deviceMetas.filter { $0.url.path != primary.url.path }
                    let otherBytes = otherDevices.reduce(0) { $0 + $1.bytes }
                    let otherCount = otherDevices.reduce(0) { $0 + $1.fileCount }

                    if otherBytes > 0 || !otherDevices.isEmpty {
                        items.append(CleanItem(
                            category: .developer,
                            title: "iOS Simulator Devices (Except Default iOS 27)",
                            subtitle: "~/Library/Developer/CoreSimulator/Devices",
                            url: simDevicesURL,
                            bytes: otherBytes,
                            fileCount: otherCount,
                            isApproximate: otherDevices.contains { $0.isApproximate },
                            lastModified: otherDevices.contains { $0.isApproximate } ? nil : otherDevices.compactMap(\.lastUsedAt).max(),
                            isSelected: false,
                            detail: "Installed iOS simulator devices except the primary iOS 27 simulator (\(primary.name)), which is preserved by default for BitRig and testing.\u{00a0} Xcode re-downloads runtimes on demand."
                        ))
                    }

                    if primary.bytes > 0 {
                        items.append(CleanItem(
                            category: .developer,
                            title: "iOS 27 Simulator Device (Primary: \(primary.name))",
                            subtitle: "~/Library/Developer/CoreSimulator/Devices/\(primary.udid)",
                            url: primary.url,
                            bytes: primary.bytes,
                            fileCount: primary.fileCount,
                            isApproximate: primary.isApproximate,
                            lastModified: primary.isApproximate ? nil : primary.lastUsedAt,
                            isSelected: false,
                            detail: "The primary iOS 27 simulator (\(primary.name)), preserved by default so BitRig and local test lanes can run without re-downloading.\u{00a0} Select this option to clean it also."
                        ))
                    }
                } else {
                    let stats = directoryStats(at: simDevicesURL)
                    if stats.bytes > 0 {
                        items.append(CleanItem(
                            category: .developer,
                            title: "iOS Simulator Devices",
                            subtitle: "~/Library/Developer/CoreSimulator/Devices",
                            url: simDevicesURL,
                            bytes: stats.bytes,
                            fileCount: stats.fileCount,
                            isApproximate: stats.isApproximate,
                            lastModified: stats.lastModified,
                            isSelected: false,
                            detail: "All installed iOS simulator devices.\u{00A0} Removing them deletes every simulator; Xcode re-downloads runtimes on demand."
                        ))
                    }
                }
            }
        }

        if !scanShouldStop() {
            // Xcode Connected-Device Support — symbols pulled down when an iOS
            // device is plugged in.  Opt-in: re-downloads when a device is next
            // connected, which is a no-op for anyone who isn't actively
            // developing on physical hardware.
            let coreDeviceURL = userHomeURL.appendingPathComponent("Library/Developer/CoreDevice", isDirectory: true)
            var isDir: ObjCBool = false
            if scanFileExists(atPath: coreDeviceURL.path, isDirectory: &isDir) {
                let stats = directoryStats(at: coreDeviceURL)
                if stats.bytes > 0 {
                    items.append(CleanItem(
                        category: .developer,
                        title: "Xcode Connected-Device Support",
                        subtitle: "~/Library/Developer/CoreDevice",
                        url: coreDeviceURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: false,
                        detail: "Symbols and support files from connected iOS devices.\u{00A0} Re-downloads when a device is connected."
                    ))
                }
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans for residual support and cache folders belonging to apps no longer installed.
    func scanOrphanedData(installedApps: [StorageScanner.InstalledApp] = []) -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanOrphanedData(installedApps: installedApps) } }
        // Collect known installed bundle IDs and app names (lowercase for comparison)
        var knownBundleIds: Set<String> = []
        var knownNames: Set<String> = []

        let appRoots = StorageScanner.installedAppRoots()
        let scanner = StorageScanner(fileManager: fileManager)
        var appsToInspect = installedApps
        if installedApps.isEmpty {
            for root in appRoots {
                if scanShouldStop() { return [] }
                let subpaths = (try? scanSubpaths(at: root)) ?? []
                for subpath in subpaths where subpath.hasSuffix(".app") {
                    if scanShouldStop() { return [] }
                    let url = root.appendingPathComponent(subpath)
                    guard scanAllows(url.appendingPathComponent("Contents/Info.plist")) else { markScanIncomplete(); continue }
                    let info = scanner.readInfo(at: url)
                    guard info.bundleId != nil else { markScanIncomplete(); continue }
                    appsToInspect.append(StorageScanner.InstalledApp(bundleId: info.bundleId, name: info.name,
                        url: url, groupContainers: info.applicationGroups))
                }
            }
            // An incomplete app inventory cannot establish that an app was uninstalled.
            guard Self.scanContext?.incomplete != true else { return [] }
        }

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
        if !scanShouldStop() {
            let containersURL = userHomeURL.appendingPathComponent("Library/Containers", isDirectory: true)
            if let contents = try? scanContentsOfDirectory(at: containersURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for url in contents {
                    if scanShouldStop() { break }
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
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: CleanCategory.orphanedData.defaultSelected,
                        detail: "Uninstalled application container"
                    ))
                }
            }
        }

        // Inspect Application Support
        if !scanShouldStop() {
            let appSupportURL = userHomeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            if let contents = try? scanContentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for url in contents {
                    if scanShouldStop() { break }
                    let name = url.lastPathComponent
                    if isAppleOrSystemFolder(name) || isHogHunterIdentifier(name) { continue }
                    if Self.isSharedVendorContainer(name) { continue }
                    if knownBundleIds.contains(name.lowercased()) || knownNames.contains(name.lowercased()) { continue }
                    // An unread installed-product child must never become an orphan suggestion.
                    // Completeness belongs to this folder, not an earlier category target.
                    guard let children = try? scanContentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles], requireComplete: true) else { continue }
                    let childNames = children.map(\.lastPathComponent)
                    if Self.holdsInstalledProduct(childNames: childNames, knownBundleIds: knownBundleIds, knownNames: knownNames) { continue }

                    let stats = directoryStats(at: url)
                    guard stats.bytes > 0 else { continue }

                    items.append(CleanItem(
                        category: .orphanedData,
                        title: name,
                        subtitle: "~/Library/Application Support/\(name)",
                        url: url,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: CleanCategory.orphanedData.defaultSelected,
                        detail: "Leftover application data from removed app"
                    ))
                }
            }
        }

        // Inspect Saved Application State
        if !scanShouldStop() {
            let savedStateURL = userHomeURL.appendingPathComponent("Library/Saved Application State", isDirectory: true)
            if let contents = try? scanContentsOfDirectory(at: savedStateURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for url in contents {
                    if scanShouldStop() { break }
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
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: CleanCategory.orphanedData.defaultSelected,
                        detail: "Saved state from uninstalled app"
                    ))
                }
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans for stale AI agent transcripts (>7 days) across Gemini/Antigravity, Grok, Codex,
    /// stale BotFleet update installers, and old AI model temporary caches.
    func scanAIArtifacts() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanAIArtifacts() } }
        var items: [CleanItem] = []
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        // 1. Antigravity brain sessions (~/.gemini/antigravity/brain)
        let brainURL = userHomeURL.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
        if let brainContents = try? scanContentsOfDirectory(at: brainURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            for folderURL in brainContents {
                if scanShouldStop() { break }
                let name = folderURL.lastPathComponent
                if name == "tempmediaStorage" { continue }
                guard let values = try? folderURL.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                      values.isDirectory == true,
                      let modDate = values.contentModificationDate,
                      modDate < sevenDaysAgo else { continue }

                let stats = directoryStats(at: folderURL)
                guard !stats.isApproximate, stats.bytes > 0 else { continue }
                items.append(CleanItem(
                    category: .aiArtifacts,
                    title: "Antigravity Session (\(name.prefix(8)))",
                    subtitle: "~/.gemini/antigravity/brain/\(name)",
                    url: folderURL,
                    bytes: stats.bytes,
                    fileCount: stats.fileCount,
                    isApproximate: stats.isApproximate,
                    lastModified: modDate,
                    isSelected: false,
                    detail: "Agent session older than 7 days"
                ))
            }
        }

        // 2. Grok sessions (~/.grok/sessions)
        if !scanShouldStop() {
            let grokURL = userHomeURL.appendingPathComponent(".grok/sessions", isDirectory: true)
            if let grokContents = try? scanContentsOfDirectory(at: grokURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                for folderURL in grokContents {
                    if scanShouldStop() { break }
                    guard let values = try? folderURL.resourceValues(forKeys: [.contentModificationDateKey]),
                          let modDate = values.contentModificationDate,
                          modDate < sevenDaysAgo else { continue }
                    let stats = directoryStats(at: folderURL)
                    guard !stats.isApproximate, stats.bytes > 0 else { continue }
                    items.append(CleanItem(
                        category: .aiArtifacts,
                        title: "Grok Session (\(folderURL.lastPathComponent.prefix(8)))",
                        subtitle: "~/.grok/sessions/\(folderURL.lastPathComponent)",
                        url: folderURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: modDate,
                        isSelected: false,
                        detail: "Grok transcript older than 7 days"
                    ))
                }
            }
        }

        // 3. Codex archived sessions (~/.codex/archived_sessions)
        if !scanShouldStop() {
            let codexURL = userHomeURL.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
            if let codexContents = try? scanContentsOfDirectory(at: codexURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for fileURL in codexContents {
                    if scanShouldStop() { break }
                    let stats = directoryStats(at: fileURL)
                    guard !stats.isApproximate, stats.bytes > 0 else { continue }
                    items.append(CleanItem(
                        category: .aiArtifacts,
                        title: "Codex Archived Session (\(fileURL.lastPathComponent.prefix(16)))",
                        subtitle: "~/.codex/archived_sessions/\(fileURL.lastPathComponent)",
                        url: fileURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: false,
                        detail: "Archived Codex transcript"
                    ))
                }
            }
        }

        // 4. Stale BotFleet update installers & temporary downloads (~/.BotFleet.update-*)
        if !scanShouldStop() {
            if let homeContents = try? scanContentsOfDirectory(at: userHomeURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                for url in homeContents {
                    if scanShouldStop() { break }
                    let name = url.lastPathComponent
                    if name.hasPrefix(".BotFleet.update-") {
                        let stats = directoryStats(at: url)
                        guard !stats.isApproximate, stats.bytes > 0 else { continue }
                        items.append(CleanItem(
                            category: .aiArtifacts,
                            title: name,
                            subtitle: "~/\(name)",
                            url: url,
                            bytes: stats.bytes,
                            fileCount: stats.fileCount,
                            isApproximate: stats.isApproximate,
                            lastModified: stats.lastModified,
                            isSelected: false,
                            detail: "Stale BotFleet update package"
                        ))
                    }
                }
            }
        }

        // 5. Abandoned BotFleet update/rollback node_modules (~/apps/.botfleet-server.node_modules.*)
        if !scanShouldStop() {
            let appsURL = userHomeURL.appendingPathComponent("apps", isDirectory: true)
            if let appsContents = try? scanContentsOfDirectory(at: appsURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                for url in appsContents {
                    if scanShouldStop() { break }
                    let name = url.lastPathComponent
                    if name.hasPrefix(".botfleet-server.node_modules.") {
                        let stats = directoryStats(at: url)
                        guard !stats.isApproximate, stats.bytes > 0 else { continue }
                        // A fresh rollback may still be needed: the new copy
                        // gets a day to prove itself before the old one is listed.
                        if let modified = stats.lastModified,
                           Date().timeIntervalSince(modified) < 24 * 3600 {
                            continue
                        }
                        // A moved-in old tree keeps its file mtimes, so the
                        // file gate above cannot see the move.  The directory's
                        // own ctime is refreshed by the rename, and only the
                        // move proves the copy just arrived.
                        if Self.directoryMovedWithin(url, within: 24 * 3600) {
                            continue
                        }
                        items.append(CleanItem(
                            category: .aiArtifacts,
                            title: name,
                            subtitle: "~/apps/\(name)",
                            url: url,
                            bytes: stats.bytes,
                            fileCount: stats.fileCount,
                            isApproximate: stats.isApproximate,
                            lastModified: stats.lastModified,
                            isSelected: true,
                            detail: "Abandoned BotFleet update/rollback package (zero re-download penalty)"
                        ))
                    }
                }
            }
        }

        // 6. Rotated BotFleet agent transcript logs (~/.botfleet/native/*.ndjson.1)
        if !scanShouldStop() {
            let bfNativeURL = userHomeURL.appendingPathComponent(".botfleet/native", isDirectory: true)
            if let nativeContents = try? scanContentsOfDirectory(at: bfNativeURL, includingPropertiesForKeys: [.fileSizeKey], options: []) {
                for url in nativeContents {
                    if scanShouldStop() { break }
                    let name = url.lastPathComponent
                    if name.hasSuffix(".ndjson.1") {
                        let stats = directoryStats(at: url)
                        guard !stats.isApproximate, stats.bytes > 0 else { continue }
                        items.append(CleanItem(
                            category: .aiArtifacts,
                            title: name,
                            subtitle: "~/.botfleet/native/\(name)",
                            url: url,
                            bytes: stats.bytes,
                            fileCount: 1,
                            lastModified: stats.lastModified,
                            isSelected: false,
                            detail: "Rotated agent transcript log dump"
                        ))
                    }
                }
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Scans local AI model weights (.gguf, .safetensors, .bin) from Ollama, Hugging Face, LM Studio, and Whisper.
    func scanLocalAIModels() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanLocalAIModels() } }
        var items: [CleanItem] = []
        let home = userHomeURL

        // 1. Ollama Models (~/.ollama/models)
        if !scanShouldStop() {
            let manifestsURL = home.appendingPathComponent(".ollama/models/manifests", isDirectory: true)
            if let manifestContents = try? scanSubpaths(at: manifestsURL) {
                for subpath in manifestContents {
                    if scanShouldStop() { break }
                    let fileURL = manifestsURL.appendingPathComponent(subpath)
                    var isDir: ObjCBool = false
                    if scanFileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                        let name = subpath.replacingOccurrences(of: "registry.ollama.ai/", with: "")
                        let stats = directoryStats(at: fileURL)
                        items.append(CleanItem(
                            category: .localAIModels,
                            title: "Ollama: \(name)",
                            subtitle: "~/.ollama/models/manifests/\(subpath)",
                            url: fileURL,
                            bytes: stats.bytes,
                            fileCount: stats.fileCount,
                            isApproximate: stats.isApproximate,
                            lastModified: stats.lastModified,
                            isSelected: false,
                            detail: "Ollama Model Manifest"
                        ))
                    }
                }
            }

            let blobsURL = home.appendingPathComponent(".ollama/models/blobs", isDirectory: true)
            if let blobContents = try? scanContentsOfDirectory(at: blobsURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for blobURL in blobContents {
                    if scanShouldStop() { break }
                    let stats = directoryStats(at: blobURL)
                    guard stats.bytes >= 10_000_000 else { continue }
                    items.append(CleanItem(
                        category: .localAIModels,
                        title: "Ollama Blob (\(blobURL.lastPathComponent.prefix(19)))",
                        subtitle: "~/.ollama/models/blobs/\(blobURL.lastPathComponent)",
                        url: blobURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: false,
                        detail: "Ollama Model Weights (\(stats.isApproximate ? "at least " : "")\(HogFormat.memory(stats.bytes)))"
                    ))
                }
            }
        }

        // 2. Hugging Face Hub Models (~/.cache/huggingface/hub)
        if !scanShouldStop() {
            let hfURL = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            if let hfContents = try? scanContentsOfDirectory(at: hfURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                for repoURL in hfContents {
                    if scanShouldStop() { break }
                    let name = repoURL.lastPathComponent
                    guard name.hasPrefix("models--") else { continue }
                    let readableName = name.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/")
                    let stats = directoryStats(at: repoURL)
                    guard stats.bytes > 0 else { continue }
                    items.append(CleanItem(
                        category: .localAIModels,
                        title: "Hugging Face: \(readableName)",
                        subtitle: "~/.cache/huggingface/hub/\(name)",
                        url: repoURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: false,
                        detail: "Hugging Face Model Snapshot (\(stats.isApproximate ? "at least " : "")\(HogFormat.memory(stats.bytes)))"
                    ))
                }
            }
        }

        // 3. LM Studio Models (~/.cache/lm-studio/models and ~/.lmstudio/models)
        let lmStudioPaths = [".cache/lm-studio/models", ".lmstudio/models"]
        for lmPath in lmStudioPaths {
            if scanShouldStop() { break }
            let lmURL = home.appendingPathComponent(lmPath, isDirectory: true)
            if let lmContents = try? scanContentsOfDirectory(at: lmURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                for modelURL in lmContents {
                    if scanShouldStop() { break }
                    let stats = directoryStats(at: modelURL)
                    guard stats.bytes > 0 else { continue }
                    items.append(CleanItem(
                        category: .localAIModels,
                        title: "LM Studio: \(modelURL.lastPathComponent)",
                        subtitle: "~/\(lmPath)/\(modelURL.lastPathComponent)",
                        url: modelURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: false,
                        detail: "LM Studio Model Weights (\(stats.isApproximate ? "at least " : "")\(HogFormat.memory(stats.bytes)))"
                    ))
                }
            }
        }

        // 4. Whisper Models (~/.cache/whisper)
        if !scanShouldStop() {
            let whisperURL = home.appendingPathComponent(".cache/whisper", isDirectory: true)
            if let whisperContents = try? scanContentsOfDirectory(at: whisperURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for modelURL in whisperContents {
                    if scanShouldStop() { break }
                    let stats = directoryStats(at: modelURL)
                    guard stats.bytes > 0 else { continue }
                    items.append(CleanItem(
                        category: .localAIModels,
                        title: "Whisper: \(modelURL.lastPathComponent)",
                        subtitle: "~/.cache/whisper/\(modelURL.lastPathComponent)",
                        url: modelURL,
                        bytes: stats.bytes,
                        fileCount: stats.fileCount,
                        isApproximate: stats.isApproximate,
                        lastModified: stats.lastModified,
                        isSelected: false,
                        detail: "Whisper Model Weights (\(stats.isApproximate ? "at least " : "")\(HogFormat.memory(stats.bytes)))"
                    ))
                }
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    private static let itemDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df
    }()

    /// Scans user folders (Downloads, Documents, Desktop) for files >100 MB or untouched >6 months (>=20 MB).
    func scanLargeAndOldFiles() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanLargeAndOldFiles() } }
        var items: [CleanItem] = []
        let searchDirectories = ["Downloads", "Documents", "Desktop"]
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        let largeThreshold: UInt64 = 100 * 1024 * 1024 // 100 MB
        let oldThreshold: UInt64 = 20 * 1024 * 1024    // 20 MB minimum for old files

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
            if scanShouldStop() { break }
            let dirURL = userHomeURL.appendingPathComponent(folder, isDirectory: true)
            guard scanAllows(dirURL), let enumerator = fileManager.enumerator(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var count = 0
            let deadline = scanUptime() + (Self.scanContext?.depth.targetDuration ?? 0.15)
            for case let fileURL as URL in enumerator {
                if scanShouldStop() { break }
                count += 1
                if count > 20_000 || scanUptime() >= deadline { markScanIncomplete(); break }
                Self.scanContext?.remaining -= 1
                guard scanAllows(fileURL) else { enumerator.skipDescendants(); continue }
                if enumerator.level >= (Self.scanContext?.depth.maxDepth ?? 10) { markScanIncomplete(); enumerator.skipDescendants() }

                // Never scan into code repositories or package/build trees
                if [".git", "node_modules", ".build", "Pods", ".venv", "venv", ".next", ".cache", "DerivedData"].contains(fileURL.lastPathComponent) {
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
                let isOld = size >= oldThreshold && (modDate != nil && modDate! < sixMonthsAgo)

                if isLarge || isOld {
                    var reasons: [String] = []
                    if isLarge { reasons.append(">100 MB (\(HogFormat.memory(size)))") }
                    if isOld, let mod = modDate {
                        reasons.append("Last modified: \(Self.itemDateFormatter.string(from: mod))")
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


    /// Scans for stale tool-made backups an agent left behind: Cursor database
    /// backups (`state.vscdb.bak-*`) older than 7 days.  The live `state.vscdb`
    /// is never listed and never touched.
    func scanStaleBackups() -> [CleanItem] {
        if Self.scanContext == nil { return withScanBudget { scanStaleBackups() } }
        let backupDir = userHomeURL
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
        guard let contents = try? scanContentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let staleCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var items: [CleanItem] = []
        for url in contents {
            if scanShouldStop() { break }
            let name = url.lastPathComponent
            // The live database has no .bak- suffix; only versioned backups match.
            guard name.hasPrefix("state.vscdb.bak-") else { continue }
            let stats = directoryStats(at: url)
            guard stats.bytes > 0 else { continue }
            guard let modified = stats.lastModified, modified < staleCutoff else { continue }
            items.append(CleanItem(
                category: .staleBackups,
                title: name,
                subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                url: url,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                lastModified: stats.lastModified,
                isSelected: CleanCategory.staleBackups.defaultSelected,
                detail: "Stale Cursor database backup"
            ))
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// True when the directory itself was created, renamed, or had its metadata
    /// changed within the window.  Reads the ctime (not mtime or birth time):
    /// moving an old tree preserves every file mtime inside, and only the move
    /// refreshes the directory's own ctime.  Fails closed: an unreadable path
    /// reads as just moved, so it keeps its grace period.
    static func directoryMovedWithin(_ url: URL, within interval: TimeInterval, now: Date = Date()) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return true }
        let changed = Date(
            timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)
                + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000
        )
        return now.timeIntervalSince(changed) < interval
    }

    // MARK: - Cleaning Execution

    /// What `clean` starts its error with when the safety snapshot could not be
    /// made.  The unattended runner reads it to stop a run that has no rollback
    /// point, so the text lives in one place.
    static let snapshotFailedPrefix = "APFS snapshot failed."

    /// What `clean` records for an item it did not delete because the run was
    /// stopped.  It is a sentinel and not a failure: the item was not refused,
    /// the run was cancelled.  The unattended runner filters it out before it
    /// counts failures, so a stop never hides a real failure that happened
    /// before it.
    static let cancelledMessage = "Cleanup cancelled"

    static func freeSpaceChange(before: UInt64?, after: UInt64?) -> Int64? {
        guard let before, let after, before <= UInt64(Int64.max), after <= UInt64(Int64.max) else { return nil }
        return Int64(after) - Int64(before)
    }

    /// Deletes the selected items safely.  Non-trash items are sent to the macOS Trash (`trashItem`).
    /// Trash items are removed permanently from `~/.Trash/`.
    /// When `createSnapshot` is true, takes an APFS local snapshot first.
    /// A failed snapshot stops further deletes.  APFS local snapshots already
    /// thinned before the failed safety snapshot are still reported.
    func clean(items: [CleanItem],
               tier: CleanTier = .standard,
               createSnapshot: Bool = true,
               exclusions: CleanerExclusions = CleanerExclusions.load(),
               progress: ((Double, String) -> Void)? = nil) async -> CleanResult {
        let freeBefore = freeBytesProvider()
        var reclaimed: UInt64 = 0
        var removedCount = 0
        var errors: [String] = []
        var snapshotCreatedName: String?
        var removedTitles: [String] = []
        var removedCategoryIds: [String] = []
        var seenCategories: Set<String> = []

        func noteSuccess(_ item: CleanItem) {
            removedTitles.append(item.title)
            let cat = item.category.rawValue
            if seenCategories.insert(cat).inserted {
                removedCategoryIds.append(cat)
            }
        }

        func resultSoFar(bytes: UInt64 = 0, removed: Int, snapshot: String? = nil) -> CleanResult {
            CleanResult(
                bytesReclaimed: bytes,
                itemsRemoved: removed,
                errors: errors,
                cleanedAt: Date(),
                snapshotName: snapshot,
                tier: tier,
                removedItemTitles: removedTitles,
                removedCategoryIds: removedCategoryIds,
                observedFreeBytesChange: Self.freeSpaceChange(before: freeBefore, after: freeBytesProvider())
            )
        }

        let activeItems = items.filter {
            !exclusions.isCategoryExcluded($0.category)
                && !exclusions.isPathExcluded($0.path)
                && !isHandsOff($0.url)
        }
        let snapshotItems = activeItems.filter { $0.category == .apfsSnapshots }
        let hasSnapshotItems = !snapshotItems.isEmpty

        // Track thinning completed before the safety snapshot so a failed
        // localsnapshot still reports any irreversible thin accurately.
        var thinnedCount = 0

        if hasSnapshotItems {
            guard !Task.isCancelled else {
                errors.append(Self.cancelledMessage)
                return resultSoFar(removed: 0)
            }
            progress?(0.0, "Thinning APFS local snapshots…")
            // Offload the blocking tmutil wait to a utility task, but wire
            // cancellation so cancelAll()/stop() terminate the child instead of
            // awaiting a multi-minute thinlocalsnapshots run.
            let (thinned, count) = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    SnapshotSafety.thinLocalSnapshots()
                }.value
            } onCancel: {
                SnapshotSafety.cancelActiveThin()
            }
            if thinned {
                thinnedCount = count
                removedCount += count
                for item in snapshotItems {
                    noteSuccess(item)
                }
            } else if Task.isCancelled {
                errors.append(Self.cancelledMessage)
                progress?(1.0, "Stopped")
                return resultSoFar(removed: thinnedCount)
            } else {
                errors.append("Failed to thin APFS local snapshots")
            }
            if Task.isCancelled {
                errors.append(Self.cancelledMessage)
                progress?(1.0, "Stopped")
                return resultSoFar(removed: removedCount)
            }
        }

        if createSnapshot && !activeItems.isEmpty {
            progress?(0.0, "Creating APFS safety snapshot…")
            let (success, name) = makeSnapshot()
            if success {
                snapshotCreatedName = name
            } else {
                // Thinning already ran (destructive).  Report it; do not claim
                // "Nothing was deleted" after local snapshots were thinned.
                errors.append(thinnedCount > 0
                    ? "\(Self.snapshotFailedPrefix)  APFS local snapshots were already thinned; no other data was deleted."
                    : "\(Self.snapshotFailedPrefix)  Nothing was deleted.")
                progress?(1.0, "Stopped")
                return resultSoFar(removed: thinnedCount)
            }
        }

        let totalItems = max(1, activeItems.count)

        for (index, item) in activeItems.enumerated() {
            if Task.isCancelled {
                errors.append(Self.cancelledMessage)
                break
            }
            await Task.yield()
            if Task.isCancelled {
                errors.append(Self.cancelledMessage)
                break
            }
            let progressFraction = Double(index) / Double(totalItems)
            progress?(progressFraction, item.title)

            // Resolve a symlink target before the category-prefix and
            // exclusion checks: a link inside an allowed prefix must not
            // smuggle deletes outside it (e.g. a Caches link into Documents).
            // A trash resident is deleted by unlinking the link itself, which
            // never touches the target, so the target-scope check below is
            // skipped for it: every trash link points outside the trash by
            // definition, and checking the target would refuse the whole
            // category.  The link's own trash location is still validated by
            // the guard that follows.
            let linkTarget = item.url.resolvingSymlinksInPath()
            let itemIsLink = item.isSymlink
                || ((try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false)
            if itemIsLink, item.category != .trash, linkTarget.path != item.url.path {
                let targetPath = denormalizedCleanPath(linkTarget.path)
                let targetURL = URL(fileURLWithPath: targetPath)
                if exclusions.isPathExcluded(targetPath) || isHandsOff(targetURL) {
                    errors.append("Safety check failed for path: \(item.url.path) (symlink target is excluded or hands off)")
                    continue
                }
                guard isSafeToDelete(url: targetURL, category: item.category) else {
                    errors.append("Safety check failed for path: \(item.url.path) (symlink target \(targetPath) is outside the \(item.category.rawValue) scope)")
                    continue
                }
            }

            guard isSafeToDelete(url: item.url, category: item.category) else {
                errors.append("Safety check failed for path: \(item.url.path)")
                continue
            }

            do {
                if item.category == .apfsSnapshots {
                    // Handled upfront before safety snapshot creation to preserve reversibility.
                    continue
                } else if item.category == .trash {
                    // Item is already in the trash, so remove it permanently
                    try fileManager.removeItem(at: item.url)
                    reclaimed &+= item.bytes
                    removedCount += 1
                    noteSuccess(item)
                } else if itemIsLink {
                    // Safe removal for symlinks: preserve the symlink itself, clean its target contents.
                    // Moving the symlink itself to Trash would sever the external offload link.
                    // Every child is re-checked: an exclusion, a hands-off marker, or a
                    // category-scope escape on any child keeps that child in place.
                    // The gate above uses the same live link test, so a link the
                    // scan missed (stale isSymlink flag) still takes this branch.
                    // Use the validated resolution, never a fresh one: resolving
                    // again here would let a swapped link redirect the clean to
                    // a target the gate above never approved.
                    var trashedChild = false
                    var childBytes: UInt64 = 0
                    if linkTarget.path != item.url.path, fileManager.fileExists(atPath: linkTarget.path) {
                        if let contents = try? fileManager.contentsOfDirectory(at: linkTarget, includingPropertiesForKeys: nil, options: []) {
                            for child in contents {
                                let checkURL = URL(fileURLWithPath: denormalizedCleanPath(child.path))
                                guard !exclusions.isPathExcluded(checkURL.path),
                                      isSafeToDelete(url: checkURL, category: item.category) else { continue }
                                let estimatedBytes = estimatedBytesForMovingEntry(at: child)
                                if (try? moveToTrash(child)) != nil {
                                    trashedChild = true
                                    childBytes &+= estimatedBytes
                                }
                            }
                        }
                    }
                    if trashedChild {
                        reclaimed &+= childBytes
                        removedCount += 1
                        noteSuccess(item)
                    } else {
                        errors.append("Safety check failed for path: \(item.url.path) (symlink target has no removable contents: every child was skipped or already gone)")
                    }
                } else if item.url.standardizedFileURL.path == userHomeURL.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true).standardizedFileURL.path {
                    // Aggregate simulator devices item: trash child devices individually so the primary iOS 27
                    // simulator is preserved unless explicitly selected as its own item in activeItems.
                    let simDevicesURL = item.url
                    // Preservation depends on a complete identity inventory, not complete sizes.
                    // A large primary's partial size must not block cleaning other devices.
                    let deviceMetas = scanSimulatorDevices(at: simDevicesURL, measureSizes: false)
                    guard !deviceMetas.isEmpty else {
                        errors.append("Simulator device inventory is incomplete; no devices were removed")
                        continue
                    }
                    let primary = primaryIOS27Simulator(in: deviceMetas)
                    let primaryPath = primary?.url.standardizedFileURL.path
                    let primaryAlsoSelected = primaryPath != nil && activeItems.contains { $0.url.standardizedFileURL.path == primaryPath }

                    var simulatorChildrenMoved = 0
                    var simulatorBytesMoved: UInt64 = 0
                    if let children = try? fileManager.contentsOfDirectory(at: simDevicesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for child in children {
                            let childPath = child.standardizedFileURL.path
                            if child.lastPathComponent == "device_set.plist" && !primaryAlsoSelected {
                                continue
                            }
                            if childPath == primaryPath {
                                continue
                            }
                            if isSafeToDelete(url: child, category: item.category) {
                                let estimatedBytes = estimatedBytesForMovingEntry(at: child)
                                do {
                                    try moveToTrash(child)
                                    simulatorChildrenMoved += 1
                                    simulatorBytesMoved &+= estimatedBytes
                                } catch { errors.append("A simulator device could not be moved to Trash") }
                            }
                        }
                    }
                    if simulatorChildrenMoved > 0 {
                        reclaimed &+= simulatorBytesMoved
                        removedCount += 1
                        noteSuccess(item)
                    }
                } else {
                    // Safe removal: move to macOS Trash
                    try moveToTrash(item.url)
                    reclaimed &+= item.bytes
                    removedCount += 1
                    noteSuccess(item)
                }
            } catch {
                errors.append("Failed to clean \(item.title): \(error.localizedDescription)")
            }
        }

        progress?(1.0, "Complete")

        return resultSoFar(bytes: reclaimed, removed: removedCount, snapshot: snapshotCreatedName)
    }

    // MARK: - Safety Guard

    /// Validates whether a file or directory is safe to clean.
    func isSafeToDelete(url: URL, category: CleanCategory) -> Bool {
        let path = (url.path as NSString).standardizingPath
        // Same resolved home as userHomeURL so injected-home tests (and any
        // future alternate home) keep scan + safety on one path.
        let home = (userHomeURL.path as NSString).standardizingPath

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

        // The fleet's own work.  `~/apps/lanes` is a directory of symlinks to
        // the external volume, but it resolves to the internal disk when that
        // volume is unmounted, so a volume check alone cannot catch it.  The
        // owner ruled on 2026-10-21 that the lanes tree is out of scope for
        // any reclaim, so it is refused by name.
        let lanesPath = home + "/apps/lanes"
        if path == lanesPath || path.hasPrefix(lanesPath + "/") {
            return false
        }

        // Never touch a volume other than the one that holds the home
        // directory.  The external disk carries the lanes and the fleet's
        // working copies, and a reclaim has no business there.
        if isOnExternalVolume(path) {
            return false
        }

        // A `.janitor-keep` marker on this path, on any parent of it, or
        // anywhere inside it means the operator marked that tree hands off.
        // This is the choke point every delete passes through, so it asks the
        // inside question as well as the parent one: a tree is deleted whole,
        // and deleting it would take the marker with it.
        if isHandsOff(URL(fileURLWithPath: path)) {
            return false
        }

        // Never touch Hog Hunter's own namespaces (bundle caches, Application
        // Support, Logs).  Use path markers — not a raw "hoghunter" substring —
        // so a temp folder named HogHunterTest_* cannot poison the allowlist.
        if isHogHunterProtectedPath(path) {
            return false
        }

        // Never touch git repositories or secret directories
        if path.contains("/.git/") || path.hasSuffix("/.git") || path.contains("/.secrets") {
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
            // Stored without a trailing slash: `path` is standardized, so a
            // trailing-slash prefix could never match the directory itself.
            let allowedDeveloperPrefixes = [
                home + "/Library/Developer/Xcode/DerivedData",
                home + "/Library/Developer/Xcode/Archives",
                home + "/Library/Developer/Xcode/iOS DeviceSupport",
                home + "/Library/Developer/CoreSimulator/Caches",
                home + "/Library/Developer/CoreSimulator/Devices",
                home + "/Library/Developer/CoreDevice",
                home + "/Library/Caches/Homebrew",
                home + "/.npm/_cacache",
                home + "/Library/Caches/Yarn",
                home + "/.cache/yarn",
                home + "/Library/Caches/pnpm",
                home + "/.local/share/pnpm/store",
                home + "/Library/Caches/CocoaPods",
                home + "/.gradle/caches",
                home + "/.cargo/registry/cache",
                home + "/Library/Caches/go-build",
                home + "/Library/Caches/dev.kdrag0n.MacVirt",
                home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/Library/Caches",
                home + "/.docker/buildx/cache",
                home + "/Library/Caches/com.docker.docker"
            ] + Self.codingPlatformCacheTargets.map { home + "/" + $0.path }
            return allowedDeveloperPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }

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

        case .aiArtifacts:
            let allowedAIPrefixes = [
                home + "/.gemini/antigravity/brain/",
                home + "/.grok/sessions/",
                home + "/.codex/archived_sessions/",
                home + "/.botfleet/updates/",
                home + "/Library/Caches/BotFleet/updates/",
                home + "/.cache/huggingface/",
                home + "/.ollama/models/blobs/"
            ]
            let isStaleUpdate = path.contains("/.BotFleet.update-") ||
                               path.contains("/.botfleet-server.node_modules.") ||
                               (path.contains("/.botfleet/native/") && path.hasSuffix(".ndjson.1"))
            let hasAllowedPrefix = allowedAIPrefixes.contains { path.hasPrefix($0) && path != $0 }
            return hasAllowedPrefix || isStaleUpdate

        case .localAIModels:
            let allowedModelPrefixes = [
                home + "/.ollama/models/",
                home + "/.cache/huggingface/hub/",
                home + "/.cache/lm-studio/models/",
                home + "/.lmstudio/models/",
                home + "/.cache/whisper/"
            ]
            return allowedModelPrefixes.contains { path.hasPrefix($0) && path != $0 }

        case .largeAndOldFiles:
            let allowedUserPrefixes = [
                home + "/Downloads/",
                home + "/Documents/",
                home + "/Desktop/"
            ]
            return allowedUserPrefixes.contains { path.hasPrefix($0) && path != $0 }

        case .apfsSnapshots:
            return path.hasPrefix("/.snapshots/com.apple.TimeMachine.")

        case .tempFiles:
            return isTempEntrySafeNow(url)

        case .staleBackups:
            // Only versioned Cursor database backups under globalStorage.  The
            // live state.vscdb has no .bak- suffix and can never match this.
            let backupsPrefix = home + "/Library/Application Support/Cursor/User/globalStorage/"
            guard path.hasPrefix(backupsPrefix) && path != backupsPrefix else { return false }
            return url.lastPathComponent.hasPrefix("state.vscdb.bak-")
        }
    }

    /// Moving a child link moves the link itself, leaving its target untouched.
    /// Zero is a conservative estimate for that entry; never credit the target tree.
    private func estimatedBytesForMovingEntry(at url: URL) -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return 0 }
        return directoryStats(at: url).bytes
    }

    // MARK: - Directory Stats Helper

    /// Allocated bytes, file count, and last modification date of a directory
    /// or file.  Any depth, entry, time, cancellation, or access limit marks
    /// `bytes` as a lower bound and leaves age unknown.
    struct DirectoryStats: Sendable {
        var bytes: UInt64
        var fileCount: Int
        var lastModified: Date?
        var isApproximate: Bool = false
    }

    /// Counts files and directories against the entry cap, including empty directories.
    /// Budgets are checked between filesystem calls, not kernel deadlines.
    func directoryStats(at url: URL, maxDepth: Int = 32, fileCap: Int = 25_000) -> DirectoryStats {
        let context = Self.scanContext
        let depth = min(maxDepth, context?.depth.maxDepth ?? maxDepth)
        let memoKey = "\(url.path)|\(depth)|\(fileCap)"
        if let cached = context?.memo[memoKey] { return cached }
        var stats = DirectoryStats(bytes: 0, fileCount: 0, lastModified: nil)
        func partial() -> DirectoryStats {
            markScanIncomplete()
            stats.isApproximate = true
            // A visited prefix cannot prove that the entire target is old.
            stats.lastModified = nil
            return stats
        }
        guard let measuredURL = scanURL(url) else { return partial() }
        let deadline = scanUptime() + (context?.depth.targetDuration ?? 0.15)
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let root = try? measuredURL.resourceValues(forKeys: keys) else { return partial() }
        func add(_ values: URLResourceValues) {
            let allocated = max(0, values.fileAllocatedSize ?? 0)
            let logical = max(0, values.fileSize ?? 0)
            stats.bytes &+= UInt64(allocated > 0 ? allocated : logical)
            stats.fileCount += 1
            if let date = values.contentModificationDate, stats.lastModified == nil || date > stats.lastModified! {
                stats.lastModified = date
            }
        }
        if root.isDirectory != true {
            add(root)
            context?.memo[memoKey] = stats
            return stats
        }
        stats.lastModified = root.contentModificationDate
        var failed = false
        guard let enumerator = fileManager.enumerator(at: measuredURL, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, _ in failed = true; return true }) else { return partial() }
        var visited = 0
        while !scanShouldStop() {
            guard visited < fileCap, scanUptime() < deadline else { return partial() }
            guard let child = enumerator.nextObject() as? URL else {
                if failed || stats.isApproximate { return partial() }
                context?.memo[memoKey] = stats
                return stats
            }
            visited += 1
            context?.remaining -= 1
            guard scanAllows(child) else { failed = true; enumerator.skipDescendants(); continue }
            guard let values = try? child.resourceValues(forKeys: keys) else { failed = true; continue }
            if values.isDirectory == true {
                if enumerator.level >= depth { stats.isApproximate = true; enumerator.skipDescendants() }
                if let date = values.contentModificationDate, stats.lastModified == nil || date > stats.lastModified! {
                    stats.lastModified = date
                }
                continue
            }
            if values.isSymbolicLink == true { failed = true; continue }
            add(values)
        }
        return partial()
    }

    // MARK: - Simulator Device Inspection

    struct SimulatorDeviceInfo: Sendable {
        let url: URL
        let udid: String
        let name: String
        let runtime: String
        let lastUsedAt: Date?
        let isIOS27: Bool
        let bytes: UInt64
        let fileCount: Int
        var isApproximate: Bool = false
    }

    /// Scans individual simulator devices inside `CoreSimulator/Devices`.
    func scanSimulatorDevices(at devicesURL: URL, measureSizes: Bool = true) -> [SimulatorDeviceInfo] {
        guard let contents = try? scanContentsOfDirectory(
            at: devicesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles], requireComplete: true
        ) else {
            return []
        }
        var devices: [SimulatorDeviceInfo] = []
        for item in contents {
            if scanShouldStop() { markScanIncomplete(); return [] }
            var isDir: ObjCBool = false
            guard scanFileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let plistURL = item.appendingPathComponent("device.plist")
            guard scanFileExists(atPath: plistURL.path) else { markScanIncomplete(); return [] }

            var name = item.lastPathComponent
            var runtime = ""
            var lastUsedAt: Date?
            var udid = item.lastPathComponent

            guard let data = try? Data(contentsOf: plistURL),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let parsedRuntime = plist["runtime"] as? String, !parsedRuntime.isEmpty else {
                markScanIncomplete()
                return []
            }
            do {
                if let parsedName = plist["name"] as? String, !parsedName.isEmpty {
                    name = parsedName
                }
                runtime = parsedRuntime
                if let parsedUDID = plist["UDID"] as? String, !parsedUDID.isEmpty {
                    udid = parsedUDID
                }
                if let parsedLastUsed = plist["lastUsedAt"] as? Date {
                    lastUsedAt = parsedLastUsed
                }
            }

            if lastUsedAt == nil {
                if let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mod = values.contentModificationDate {
                    lastUsedAt = mod
                }
            }

            let isIOS27 = runtime.localizedCaseInsensitiveContains("iOS-27") ||
                          runtime.localizedCaseInsensitiveContains("iOS 27") ||
                          runtime.localizedCaseInsensitiveContains("iOS.27")
            let stats = measureSizes ? directoryStats(at: item)
                : DirectoryStats(bytes: 0, fileCount: 0, lastModified: nil)
            devices.append(SimulatorDeviceInfo(
                url: item,
                udid: udid,
                name: name,
                runtime: runtime,
                lastUsedAt: lastUsedAt,
                isIOS27: isIOS27,
                bytes: stats.bytes,
                fileCount: stats.fileCount,
                isApproximate: stats.isApproximate
            ))
        }
        return devices
    }

    /// Finds the primary iOS 27 simulator device to preserve (most recently active).
    func primaryIOS27Simulator(in devices: [SimulatorDeviceInfo]) -> SimulatorDeviceInfo? {
        let ios27Devices = devices.filter(\.isIOS27).sorted { lhs, rhs in
            if let lDate = lhs.lastUsedAt, let rDate = rhs.lastUsedAt {
                return lDate > rDate
            }
            if lhs.lastUsedAt != nil { return true }
            if rhs.lastUsedAt != nil { return false }
            return lhs.name < rhs.name
        }
        return ios27Devices.first
    }

    // MARK: - Internal Helpers

    private var userHomeURL: URL {
        homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// True when a `.janitor-keep` marker keeps this candidate off every clean.
    ///
    /// Two questions, because the cleaner deletes whole trees.  A marker on the
    /// path or on any parent of it protects the path (`isKept`).  A marker
    /// anywhere *inside* a directory protects the directory too
    /// (`containsMarker`), because trashing or removing the tree would take
    /// the operator's marker with it.  The Python engine asks both at its own
    /// choke point (`apply_delete`), and an unattended regimen has nobody
    /// standing there to say "not that one", so the Swift side asks both.
    ///
    /// A symlink item has its *target's* children trashed (see `clean`), so the
    /// inside question is asked of the resolved target.
    private func isHandsOff(_ url: URL) -> Bool {
        if KeepSentinel.isKept(url: url, fileManager: fileManager) { return true }
        let tree = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: tree.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return KeepSentinel.containsMarker(url: tree, fileManager: fileManager)
    }

    /// True when the path lives on a volume other than the one that holds the
    /// home directory.
    ///
    /// The home directory is the reference: a machine whose home is itself on
    /// an external disk must still be able to clean its own caches.  The
    /// cheap string checks come first because most candidates are under the
    /// home directory and never need a volume lookup.
    private func isOnExternalVolume(_ path: String) -> Bool {
        let home = userHomeURL.resolvingSymlinksInPath()
        // A home on an external volume is its own reference: nothing is
        // external relative to it.
        if home.path.hasPrefix("/Volumes/") { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // A symlink out to a mounted disk lands here.
        if resolved.path.hasPrefix("/Volumes/") { return true }
        if path.hasPrefix(userHomeURL.path) { return false }
        // Anything else is judged by the volume resource values, which is how
        // a mounted disk that does not live under /Volumes is still caught.
        return DiskCleaner.detectVolume(for: URL(fileURLWithPath: path)).isExternal
    }

    /// Root scanned by the temp-files category.  Tests inject an override.
    /// Always resolved so `/tmp` (`/private/tmp`) and `/var` (`/private/var`)
    /// stay on one path for the scan, the listed item URL, and the safety guard.
    private var tempRootURL: URL {
        (tempRootDirectory ?? URL(fileURLWithPath: "/tmp", isDirectory: true)).resolvingSymlinksInPath()
    }

    /// Resolve a filesystem path so `/var` and `/private/var` compare equal.
    /// `standardizingPath` does not consult the file system.
    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Maps a symlink-resolved path back under the (possibly symlinked,
    /// e.g. `/var` -> `/private/var`) home so category-prefix checks see one
    /// path form.  Paths outside the home pass through unchanged.
    private func denormalizedCleanPath(_ resolved: String) -> String {
        let homeStd = (userHomeURL.path as NSString).standardizingPath
        let homeRes = (userHomeURL.resolvingSymlinksInPath().path as NSString).standardizingPath
        let resolvedStd = (resolved as NSString).standardizingPath
        if homeRes != homeStd,
           resolvedStd == homeRes || resolvedStd.hasPrefix(homeRes + "/") {
            return homeStd + resolvedStd.dropFirst(homeRes.count)
        }
        return resolvedStd
    }

    /// True for a folder or bundle-id *name* that belongs to Hog Hunter
    /// (used when scanning Containers / Application Support entries).
    private func isHogHunterIdentifier(_ string: String) -> Bool {
        let lower = string.lowercased()
        return lower.contains("hoghunter") || lower.contains("simplewithus.hoghunter") || lower.contains("jayservices.hoghunter")
    }

    /// True for a full filesystem path that is one of Hog Hunter's protected
    /// namespaces.  Deliberately narrower than `isHogHunterIdentifier`: a path
    /// component like `HogHunterTest_*` must not block orphan allowlisting.
    private func isHogHunterProtectedPath(_ path: String) -> Bool {
        let lower = (path as NSString).standardizingPath.lowercased()
        let markers = [
            "/library/application support/hoghunter",
            "/library/logs/hoghunter",
            "/library/caches/com.simplewithus.hoghunter",
            "/library/caches/com.jayservices.hoghunter",
            "/library/containers/com.simplewithus.hoghunter",
            "/library/containers/com.jayservices.hoghunter",
            "/library/saved application state/com.simplewithus.hoghunter",
            "/library/saved application state/com.jayservices.hoghunter"
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Shared vendor folders hold several live products.  They are not one uninstalled app.
    static func isSharedVendorContainer(_ name: String) -> Bool {
        let shared: Set<String> = [
            "google", "mozilla", "microsoft", "mobilesync", "crashreporter"
        ]
        return shared.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// True when a folder still contains a product that is installed.
    static func holdsInstalledProduct(childNames: [String], knownBundleIds: Set<String>, knownNames: Set<String>) -> Bool {
        func normalize(_ value: String) -> String {
            String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        // Normalized compare so a version-suffixed child ("IntelliJIdea2024.2")
        // still matches the installed "IntelliJ IDEA", and a product folder
        // ("Brave-Browser") still matches the display name "Brave Browser",
        // instead of being listed as an orphan and deleted.  Tokens of 2 or
        // fewer characters are too generic to decide on, so they are dropped.
        // `hasSuffix` covers product folders that embed a longer identifier
        // (e.g. bravebrowser ends with browser) without requiring an exact Set hit.
        let wanted = (knownBundleIds.union(knownNames)).map(normalize).filter { $0.count > 2 }
        for child in childNames {
            let c = normalize(child)
            guard !c.isEmpty else { continue }
            if wanted.contains(where: { token in
                token == c || c.hasPrefix(token) || (token.count >= 6 && c.hasSuffix(token))
            }) { return true }
        }
        return false
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

    /// Detects whether the item resolves to an external volume and resolves the volume display name.
    static func detectVolume(for url: URL) -> (isExternal: Bool, volumeName: String) {
        let resolved = url.resolvingSymlinksInPath()
        let path = resolved.path
        if path.hasPrefix("/Volumes/") {
            let components = path.split(separator: "/")
            let volName = components.count > 1 ? String(components[1]) : "External"
            return (true, volName)
        }
        if let values = try? resolved.resourceValues(forKeys: [.volumeIsInternalKey, .volumeNameKey]) {
            let isInternal = values.volumeIsInternal ?? true
            let name = values.volumeName ?? (isInternal ? "Macintosh HD" : "External")
            return (!isInternal, name)
        }
        return (false, "Macintosh HD")
    }
}
