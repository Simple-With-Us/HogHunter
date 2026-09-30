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

    let cleaner: DiskCleaner
    private let queue = DispatchQueue(label: "hoghunter.cleaner", qos: .utility)
    private var isScanInFlight = false

    init(cleaner: DiskCleaner = DiskCleaner()) {
        self.cleaner = cleaner
    }

    // MARK: - Scan

    /// Switches the active cleaning tier and initiates a scan for that tier.
    func setTier(_ tier: CleanTier) {
        guard tier != selectedTier else { return }
        selectedTier = tier
        scan()
    }

    /// Initiates a full disk clutter scan for the active tier.
    func scan() {
        guard !isScanInFlight else { return }
        isScanInFlight = true
        let currentTier = selectedTier
        state = .scanning(category: "Starting \(currentTier.title) scan…")

        let cleaner = self.cleaner
        queue.async { [weak self] in
            Task {
                let scanReport = await cleaner.scan(tier: currentTier) { categoryTitle in
                    Task { @MainActor in
                        self?.state = .scanning(category: categoryTitle)
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    self.report = scanReport

                    // Initialize selections according to category defaultSelected
                    var initialSelected: Set<String> = []
                    for catReport in scanReport.categories where catReport.category.defaultSelected {
                        for item in catReport.items {
                            initialSelected.insert(item.id)
                        }
                    }
                    self.selectedItemIds = initialSelected
                    self.state = .scanned(scanReport)
                    self.isScanInFlight = false
                }
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

        let currentTier = selectedTier
        state = .cleaning(progress: 0, currentItem: "Preparing…")

        var lastReportedTime = Date.distantPast
        var lastReportedProgress: Double = -1.0
        let cleaner = self.cleaner
        queue.async { [weak self] in
            Task {
                let result = await cleaner.clean(items: itemsToClean, tier: currentTier, createSnapshot: createSnapshot) { progress, currentItem in
                    let now = Date()
                    let isSpecial = currentItem.contains("snapshot") || progress >= 1.0 || (progress - lastReportedProgress) >= 0.02 || now.timeIntervalSince(lastReportedTime) >= 0.1
                    if isSpecial {
                        lastReportedProgress = progress
                        lastReportedTime = now
                        Task { @MainActor in
                            self?.state = .cleaning(progress: progress, currentItem: currentItem)
                        }
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    self.selectedItemIds.removeAll()
                    self.state = .cleaned(result)
                }
            }
        }
    }

    // MARK: - Finder Integration

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
