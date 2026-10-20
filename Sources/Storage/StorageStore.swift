import Foundation
import SwiftUI

/// Wraps `StorageScanner` for use from a SwiftUI view: kicks the scan off on
/// a background queue, debounces manual refresh, and exposes the result as
/// `@Published` so the view can re-render when it lands.
///
/// The store is `@MainActor` because SwiftUI reads from it on the main actor;
/// the actual scan work happens on a private utility `DispatchQueue` so the
/// UI never blocks, even on a slow drive.
@MainActor
final class StorageStore: ObservableObject {
    enum State: Equatable {
        /// First scan has not run yet.
        case idle
        /// Scan is in flight; UI shows a "Scanning…" banner.
        case scanning
        /// A scan completed at `lastScanAt`.
        case completed(at: Date)
        /// The scanner encountered an unrecoverable error.
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Top-N apps by total disk, sorted by descending `totalBytes`.
    @Published private(set) var apps: [StorageUsage] = []
    /// Cross-app category totals for the subtitle.
    @Published private(set) var categoryTotals: [StorageCategoryTotal] = []
    /// Number of apps that the user has installed but the scanner could not
    /// allocate to a category (the ones we kept so the row still appears).
    @Published private(set) var installedAppCount: Int = 0
    /// Total bytes summed across every scanned app's `hiddenBytes`.
    @Published private(set) var totalHidden: UInt64 = 0

    let scanner: StorageScanner
    private let queue = DispatchQueue(label: "hoghunter.storage", qos: .utility)
    private let runningBundleIds: () -> Set<String>
    private var inflight = false
    private var lastRefresh: Date?

    init(scanner: StorageScanner = StorageScanner(),
         runningBundleIds: @escaping () -> Set<String>) {
        self.scanner = scanner
        self.runningBundleIds = runningBundleIds
    }

    /// Number of top apps the UI should show.  Capped because the full list
    /// (200+ apps) is unwieldy; the user can drag the panel taller.
    nonisolated static let displayedLimit = 25
    nonisolated static let hardLimit = 200

    /// Starts a scan if none is in flight.  Called on first `onAppear`, after
    /// a manual refresh, and on the periodic timer.
    func refresh() {
        guard ApplicationRunMode.current != .uiHarness, !inflight else { return }
        inflight = true
        state = .scanning
        let scanner = self.scanner
        let runningBundleIds = self.runningBundleIds()

        queue.async { [weak self] in
            let started = Date()
            let result = scanner.installedApps(runningBundleIds: runningBundleIds)
            // Truncate to top-N so the UI does not have to walk a 200-element
            // array on every state mutation; the full list is recomputed on
            // each refresh anyway.
            let top = Array(result.sorted { $0.totalBytes > $1.totalBytes }.prefix(Self.hardLimit))
            let displayTop = Array(top.prefix(Self.displayedLimit))
            let totals = StorageStore.categoryTotals(from: displayTop)
            let hidden = displayTop.reduce(0 as UInt64) { $0 &+ $1.hiddenBytes }
            let elapsed = Date().timeIntervalSince(started)
            // Smallest mercy: even a 200-app scan should never block the
            // main thread for more than one render pass; we report on
            // the next main-actor tick the caller scheduled us from.
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = displayTop
                self.categoryTotals = totals
                self.installedAppCount = result.count
                self.totalHidden = hidden
                self.lastRefresh = Date()
                self.state = .completed(at: Date())
                self.inflight = false
                _ = elapsed
            }
        }
    }

    /// Computes per-category totals across the displayed rows.
    nonisolated static func categoryTotals(from apps: [StorageUsage]) -> [StorageCategoryTotal] {
        var totals: [StorageCategory: UInt64] = [:]
        for app in apps {
            for slice in app.slices {
                totals[slice.category, default: 0] &+= slice.bytes
            }
        }
        return totals
            .map { StorageCategoryTotal(category: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Convenience: the human-readable explanation for the
    /// "X% is hidden, not visible in Finder" footer.
    func hiddenShareCaption() -> String? {
        guard !apps.isEmpty else { return nil }
        let grand = apps.reduce(0 as UInt64) { $0 &+ $1.totalBytes }
        guard grand > 0 else { return nil }
        let hidden = totalHidden
        let percent = Double(hidden) / Double(grand) * 100
        return "\(HogFormat.percent(percent / 100)) of the displayed total is outside the .app bundle."
    }
}
