import AppKit
import Foundation
import SwiftUI

/// Observable store managing state, scan execution, selection, and safe cleaning
/// for Hog Hunter's disk cleaner.
@MainActor
final class DiskCleanerStore: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning(category: String)
        case scanned(CleanScanReport)
        case cleaning(progress: Double, currentItem: String)
        case cleaned(CleanResult)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.scanning(let a), .scanning(let b)): return a == b
            case (.scanned(let a), .scanned(let b)): return a.scannedAt == b.scannedAt
            case (.cleaning(let p1, let c1), .cleaning(let p2, let c2)): return p1 == p2 && c1 == c2
            case (.cleaned(let a), .cleaned(let b)): return a.cleanedAt == b.cleanedAt
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published var selectedItemIds: Set<String> = []
    @Published var expandedCategoryIds: Set<String> = []
    @Published private(set) var report: CleanScanReport?
    @Published var showConfirmation: Bool = false
    @Published var selectedTier: CleanTier = .standard
    @Published var acknowledgedExtremeDisclaimer: Bool = false
    @Published var exclusions: CleanerExclusions
    /// Where exclusions live.  Tests pass a throwaway suite.
    private let exclusionsDefaults: UserDefaults
    /// A scan follows every exclusion edit.  Tests turn that off so they do
    /// not walk the real disk.
    private let rescanAfterExclusionChange: Bool

    var isCleaning: Bool {
        if case .cleaning = state { return true }
        return false
    }

    /// Re-reads the stored exclusions.  The phone and the Settings window edit
    /// the same value, so a copy loaded at launch goes stale.
    func reloadExclusions() {
        exclusions = CleanerExclusions.load(from: exclusionsDefaults)
    }

    func toggleCategoryExclusion(_ category: CleanCategory) {
        exclusions = CleanerExclusions.update(in: exclusionsDefaults) { $0.toggleCategory(category) }
        if rescanAfterExclusionChange { scan() }
    }

    func addExcludedPath(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        guard !normalized.isEmpty else { return }
        exclusions = CleanerExclusions.update(in: exclusionsDefaults) { current in
            if !current.excludedPaths.contains(normalized) { current.excludedPaths.append(normalized) }
        }
        if rescanAfterExclusionChange { scan() }
    }

    func removeExcludedPath(_ path: String) {
        exclusions = CleanerExclusions.update(in: exclusionsDefaults) { $0.removePath(path) }
        if rescanAfterExclusionChange { scan() }
    }

    let cleaner: DiskCleaner
    /// Append-only cleanup history under the stable app-support namespace.
    /// Refreshed on clean and on view appear so the hero header's "last cleanup" line is always fresh.
    let historyStore: CleanupHistoryStore
    @Published private(set) var lastCleanup: CleanupHistoryRecord?
    private var isScanInFlight = false
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private var currentScanId: UUID?
    private var currentCleanId: UUID?

    init(cleaner: DiskCleaner = DiskCleaner(),
         historyStore: CleanupHistoryStore = CleanupHistoryStore(inMemory: false),
         exclusionsDefaults: UserDefaults = CleanerExclusions.sharedDefaults,
         rescanAfterExclusionChange: Bool = true) {
        self.cleaner = cleaner
        self.historyStore = historyStore
        self.exclusionsDefaults = exclusionsDefaults
        self.rescanAfterExclusionChange = rescanAfterExclusionChange
        self.exclusions = CleanerExclusions.load(from: exclusionsDefaults)
        self.lastCleanup = historyStore.latestRecord()
    }

    deinit {
        scanTask?.cancel()
        cleanTask?.cancel()
    }

    // MARK: - Scan

    /// Switches the active cleaning tier and initiates a scan for that tier.
    func setTier(_ tier: CleanTier) {
        guard tier != selectedTier else { return }
        selectedTier = tier
        scan()
    }

    /// Cancels any in-flight clutter scan.
    func cancelScan() {
        currentScanId = nil
        scanTask?.cancel()
        scanTask = nil
        isScanInFlight = false
        if case .scanning = state {
            state = .idle
        }
    }

    /// Cancels all background cleaner tasks (scan or deletion).
    func cancelAll() {
        cancelScan()
        currentCleanId = nil
        cleanTask?.cancel()
        cleanTask = nil
        if case .cleaning = state {
            state = .idle
        }
    }

    /// Initiates a full disk clutter scan for the active tier.
    func scan() {
        cancelScan()
        reloadExclusions()
        isScanInFlight = true
        let scanId = UUID()
        currentScanId = scanId
        let currentTier = selectedTier
        state = .scanning(category: "Starting \(currentTier.title) scan…")

        let cleaner = self.cleaner
        let activeExclusions = exclusions
        scanTask = Task.detached(priority: .utility) { [weak self, cleaner] in
            let scanReport = await cleaner.scan(tier: currentTier, exclusions: activeExclusions) { categoryTitle in
                Task { @MainActor [weak self] in
                    guard let self, self.currentScanId == scanId else { return }
                    self.state = .scanning(category: categoryTitle)
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.currentScanId == scanId else { return }
                self.report = scanReport

                // Initialize selections according to category defaultSelected and item isSelected
                var initialSelected: Set<String> = []
                for catReport in scanReport.categories where catReport.category.defaultSelected {
                    for item in catReport.items where item.isSelected {
                        initialSelected.insert(item.id)
                    }
                }
                self.selectedItemIds = initialSelected
                self.state = .scanned(scanReport)
                self.isScanInFlight = false
                self.scanTask = nil
                self.currentScanId = nil
            }
        }
    }

    // MARK: - Selections

    func isItemSelected(_ item: CleanItem) -> Bool {
        selectedItemIds.contains(item.id)
    }

    func toggleItemSelection(_ item: CleanItem) {
        if selectedItemIds.contains(item.id) {
            selectedItemIds.remove(item.id)
        } else {
            selectedItemIds.insert(item.id)
        }
    }

    func isCategoryFullySelected(_ category: CleanCategory) -> Bool {
        guard let items = items(for: category), !items.isEmpty else { return false }
        return items.allSatisfy { selectedItemIds.contains($0.id) }
    }

    func isCategoryPartiallySelected(_ category: CleanCategory) -> Bool {
        guard let items = items(for: category), !items.isEmpty else { return false }
        let selectedCount = items.filter { selectedItemIds.contains($0.id) }.count
        return selectedCount > 0 && selectedCount < items.count
    }

    func toggleCategorySelection(_ category: CleanCategory) {
        guard let items = items(for: category) else { return }
        if isCategoryFullySelected(category) {
            for item in items {
                selectedItemIds.remove(item.id)
            }
        } else {
            for item in items {
                selectedItemIds.insert(item.id)
            }
        }
    }

    func selectAll() {
        guard let report else { return }
        for cat in report.categories {
            for item in cat.items {
                selectedItemIds.insert(item.id)
            }
        }
    }

    func deselectAll() {
        selectedItemIds.removeAll()
    }

    func toggleCategoryExpanded(_ category: CleanCategory) {
        if expandedCategoryIds.contains(category.id) {
            expandedCategoryIds.remove(category.id)
        } else {
            expandedCategoryIds.insert(category.id)
        }
    }

    func isCategoryExpanded(_ category: CleanCategory) -> Bool {
        expandedCategoryIds.contains(category.id)
    }

    // MARK: - Metrics

    func items(for category: CleanCategory) -> [CleanItem]? {
        report?.categories.first(where: { $0.category == category })?.items
    }

    func categorySelectedBytes(_ category: CleanCategory) -> UInt64 {
        guard let items = items(for: category) else { return 0 }
        return items.filter { selectedItemIds.contains($0.id) }.reduce(0 as UInt64) { $0 &+ $1.bytes }
    }

    func totalSelectedBytes() -> UInt64 {
        guard let report else { return 0 }
        var sum: UInt64 = 0
        for cat in report.categories {
            for item in cat.items where selectedItemIds.contains(item.id) {
                sum &+= item.bytes
            }
        }
        return sum
    }

    func totalSelectedItemsCount() -> Int {
        selectedItemIds.count
    }

    func totalDiscoveredBytes() -> UInt64 {
        report?.totalBytes ?? 0
    }

    // MARK: - Cleaning

    /// Executes cleaning on all selected items with APFS snapshot preservation.
    func cleanSelected(createSnapshot: Bool = true) {
        guard let report else { return }
        let itemsToClean = report.categories.flatMap { $0.items }.filter { selectedItemIds.contains($0.id) }
        guard !itemsToClean.isEmpty else { return }

        cleanTask?.cancel()
        cleanTask = nil
        let cleanId = UUID()
        currentCleanId = cleanId

        let currentTier = selectedTier
        // The scan that produced these items may be older than an edit made
        // from the phone or Settings.  `clean` re-filters against whatever it
        // is handed, so hand it the stored value, not the launch-time copy.
        reloadExclusions()
        let activeExclusions = exclusions
        let totalItems = max(1, itemsToClean.count)
        state = .cleaning(progress: 0, currentItem: "Preparing…")
        let initialProgress = CompanionCleanProgress(
            isCleaning: true,
            phase: "preparing",
            progress: 0.0,
            statusText: "Preparing…",
            currentItem: nil,
            itemsCleaned: 0,
            totalItems: totalItems,
            bytesReclaimed: 0,
            formattedBytesReclaimed: "0 B",
            snapshotName: nil,
            error: nil
        )
        let initialUpdate = DiskCleanerProgressUpdate(runId: cleanId, progress: initialProgress)
        NotificationCenter.default.post(name: .diskCleanerProgressChanged, object: initialUpdate)

        cleanTask = Task.detached(priority: .userInitiated) { [weak self, cleaner] in
            var lastReportedTime = Date.distantPast
            var lastReportedProgress: Double = -1.0
            let result = await cleaner.clean(items: itemsToClean, tier: currentTier, createSnapshot: createSnapshot, exclusions: activeExclusions) { progress, currentItem in
                let now = Date()
                let isSpecial = currentItem.contains("snapshot") || progress >= 1.0 || (progress - lastReportedProgress) >= 0.02 || now.timeIntervalSince(lastReportedTime) >= 0.1
                if isSpecial {
                    lastReportedProgress = progress
                    lastReportedTime = now
                    Task { @MainActor [weak self] in
                        guard let self, self.currentCleanId == cleanId else { return }
                        self.state = .cleaning(progress: progress, currentItem: currentItem)
                        let activeProg = CompanionCleanProgress(
                            isCleaning: true,
                            phase: currentItem.contains("snapshot") ? "snapshot" : (progress >= 1.0 ? "finishing" : "cleaning"),
                            progress: progress,
                            statusText: currentItem.contains("snapshot") ? currentItem : "Cleaning \(currentItem)…",
                            currentItem: currentItem,
                            itemsCleaned: Int(progress * Double(totalItems)),
                            totalItems: totalItems,
                            bytesReclaimed: 0,
                            formattedBytesReclaimed: "…",
                            snapshotName: nil,
                            error: nil
                        )
                        let activeUpdate = DiskCleanerProgressUpdate(runId: cleanId, progress: activeProg)
                        NotificationCenter.default.post(name: .diskCleanerProgressChanged, object: activeUpdate)
                    }
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.currentCleanId == cleanId else { return }
                self.selectedItemIds.removeAll()
                self.state = .cleaned(result)
                self.cleanTask = nil
                self.currentCleanId = nil
                let completedProg = CompanionCleanProgress(
                    isCleaning: false,
                    phase: "completed",
                    progress: 1.0,
                    statusText: "Clean complete: Reclaimed \(result.formattedBytesReclaimed)",
                    currentItem: nil,
                    itemsCleaned: result.itemsRemoved,
                    totalItems: totalItems,
                    bytesReclaimed: result.bytesReclaimed,
                    formattedBytesReclaimed: result.formattedBytesReclaimed,
                    snapshotName: result.snapshotName,
                    error: result.errors.isEmpty ? nil : result.errors.joined(separator: ", ")
                )
                let completedUpdate = DiskCleanerProgressUpdate(runId: cleanId, progress: completedProg)
                NotificationCenter.default.post(name: .diskCleanerProgressChanged, object: completedUpdate)

                // Persist only after the user is happy.  A failed clean (no
                // items removed) is not worth a history row -- the user did not
                // actually reclaim anything.
                if result.itemsRemoved > 0 {
                    // History must mirror successes only: selected-but-failed
                    // rows (thin failure, isSafeToDelete rejection, trashItem
                    // throw) stay out of the "Last cleanup" summary.
                    let record = CleanupHistoryRecord(
                        bytesReclaimed: result.bytesReclaimed,
                        itemsRemoved: result.itemsRemoved,
                        tier: result.tier,
                        categoryIds: result.removedCategoryIds,
                        itemTitles: Array(result.removedItemTitles.prefix(50)),
                        snapshotName: result.snapshotName,
                        cleanedAt: result.cleanedAt
                    )
                    self.historyStore.append(record)
                    self.lastCleanup = record
                }
            }
        }
    }

    // MARK: - Finder Integration

    func revealInFinder(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Cleanup History

    /// Re-reads the latest cleanup history record from disk.  Called by the view
    /// on appear so a record written by an earlier launch (or an external
    /// `cleanup-history.jsonl` edit) is visible without restarting the panel.
    func refreshLastCleanup() {
        lastCleanup = historyStore.latestRecord()
    }
}
