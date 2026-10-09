import Foundation
import Network

/// The phone's disk cleaner: scan on the Mac, choose items, clean.
///
/// The phone never names a path.  The Mac keeps the scan under an id and the
/// report lists short references into it; a clean sends the id and the
/// references back, and the Mac refuses anything that is not in its scan.
extension CompanionModel {
    private static let notConnected = "Not connected to your Mac.\u{00A0} Wait for Hog Hunter to find it, then try again."

    // MARK: - What is ticked

    var selectedCleanItems: [CompanionCleanItem] {
        guard let report = cleanReport else { return [] }
        return report.categories.flatMap { $0.items }.filter { selectedCleanRefs.contains($0.id) }
    }

    var selectedCleanBytes: UInt64 {
        selectedCleanItems.reduce(0) { $0 &+ $1.bytes }
    }

    var cleanScanIsRunning: Bool {
        isStartingScan || cleanReport?.state == "scanning"
    }

    func toggleCleanItem(_ id: String) {
        if selectedCleanRefs.contains(id) { selectedCleanRefs.remove(id) } else { selectedCleanRefs.insert(id) }
    }

    func isCleanCategoryFullySelected(_ category: CompanionCleanCategory) -> Bool {
        !category.items.isEmpty && category.items.allSatisfy { selectedCleanRefs.contains($0.id) }
    }

    func setCleanCategory(_ category: CompanionCleanCategory, selected: Bool) {
        for item in category.items {
            if selected { selectedCleanRefs.insert(item.id) } else { selectedCleanRefs.remove(item.id) }
        }
    }

    func selectAllCleanItems() {
        guard let report = cleanReport else { return }
        selectedCleanRefs = Set(report.categories.flatMap { $0.items }.map(\.id))
    }

    func deselectAllCleanItems() {
        selectedCleanRefs = []
    }

    // MARK: - Report

    /// Shows what the Mac already holds: a scan from a moment ago, one still
    /// running, and the cleanup history.  Called when the cleaner opens.
    func refreshCleanReport() async {
        if isDemoMode {
            if cleanReport == nil { cleanReport = Self.sampleCleanReport(state: "idle", tier: cleanTier) }
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            cleanerError = Self.notConnected
            return
        }
        do {
            let report = try await CompanionConnection.fetchCleanReport(endpoint: endpoint, token: saved.token)
            applyCleanReport(report)
            if report.state == "scanning" {
                await followScan(endpoint: endpoint, token: saved.token)
            }
        } catch {
            cleanerError = Self.describe(error)
        }
    }

    private func applyCleanReport(_ report: CompanionCleanReport) {
        cleanReport = report
        guard report.state == "ready", let scanId = report.scanId, scanId != seededScanId else { return }
        seededScanId = scanId
        selectedCleanRefs = Set(report.categories.flatMap { $0.items }.filter(\.isSelected).map(\.id))
        if let tier = report.tier { cleanTier = tier }
    }

    // MARK: - Scan

    /// Asks the Mac to scan for the chosen tier and follows it until it is done.
    func startCleanScan() async {
        guard !cleanScanIsRunning, !isCleaningSelection else { return }
        cleanerError = nil
        if cleanTier == "extreme", !extremeAcknowledged {
            cleanerError = "Tick the Extreme Clean notice first."
            return
        }
        if isDemoMode {
            await demoScan()
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            cleanerError = Self.notConnected
            return
        }
        isStartingScan = true
        do {
            let response = try await CompanionConnection.startCleanScan(
                endpoint: endpoint,
                token: saved.token,
                tier: cleanTier,
                acknowledgedExtreme: extremeAcknowledged
            )
            isStartingScan = false
            if response.status == "scanning" {
                await followScan(endpoint: endpoint, token: saved.token)
            } else if response.status == "busy" {
                // Something is already scanning or cleaning.  Show it.
                cleanerError = response.error
                await refreshCleanReport()
            } else {
                cleanerError = response.error ?? "The Mac did not start the scan."
            }
        } catch {
            isStartingScan = false
            cleanerError = Self.describe(error)
        }
    }

    /// Polls the report while the Mac scans.  A scan walks a lot of folders
    /// and can take a minute or two; the limit keeps a stuck Mac from holding
    /// the screen on a spinner for good.
    private func followScan(endpoint: NWEndpoint, token: String) async {
        cleanReportPoll?.cancel()
        let started = Date()
        while !Task.isCancelled, Date().timeIntervalSince(started) < 10 * 60 {
            do {
                let report = try await CompanionConnection.fetchCleanReport(endpoint: endpoint, token: token)
                applyCleanReport(report)
                if report.state != "scanning" { return }
            } catch {
                cleanerError = Self.describe(error)
                return
            }
            try? await Task.sleep(for: .milliseconds(1_200))
        }
        if cleanReport?.state == "scanning" {
            cleanerError = "The scan is taking a long time.\u{00A0} It keeps running on the Mac; come back to this screen to see it."
        }
    }

    // MARK: - Clean

    /// Cleans the ticked items from the scan on screen.  The caller has
    /// already shown the confirmation.
    func cleanSelection() async {
        guard !isCleaningSelection, let report = cleanReport, report.state == "ready",
              let scanId = report.scanId, !selectedCleanRefs.isEmpty else { return }
        cleanerError = nil
        isCleaningSelection = true
        defer { isCleaningSelection = false }
        if isDemoMode {
            await demoClean(report: report)
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            cleanerError = Self.notConnected
            return
        }
        let request = CompanionCleanRequest(
            scanId: scanId,
            tier: report.tier,
            items: selectedCleanRefs.sorted(),
            acknowledgedExtreme: report.tier == "extreme" ? extremeAcknowledged : nil
        )
        // The reply comes when the Mac has finished, which can be minutes.
        // Poll the snapshot meanwhile so its progress shows.
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await self?.refresh()
            }
        }
        defer { progress.cancel() }
        do {
            lastCleanResult = try await CompanionConnection.triggerClean(endpoint: endpoint, token: saved.token, request: request)
            await refresh()
        } catch CompanionClientError.forbidden(let reason) {
            cleanerError = reason
        } catch CompanionClientError.rejected(let reason) {
            cleanerError = reason
        } catch {
            // The reply can be lost while the Mac keeps cleaning.  Look
            // before calling it a failure.
            await refresh()
            if snapshot?.cleanProgress?.isCleaning == true {
                cleanerError = "Lost the connection while the Mac was cleaning.\u{00A0} It is still running; its progress shows here."
            } else {
                cleanerError = "Could not finish the clean.\u{00A0} \(Self.describe(error))"
            }
        }
        // The scan is spent: what it listed is gone or changing.
        selectedCleanRefs = []
        seededScanId = nil
        await refreshCleanReport()
    }

    // MARK: - Demo mode

    private func demoScan() async {
        isStartingScan = true
        cleanReport = CompanionCleanReport(state: "scanning", scanId: "demo", tier: cleanTier, scanningCategory: "User Caches")
        try? await Task.sleep(for: .milliseconds(900))
        cleanReport?.scanningCategory = "Developer Junk"
        try? await Task.sleep(for: .milliseconds(900))
        applyCleanReport(Self.sampleCleanReport(state: "ready", tier: cleanTier, scanId: "demo-\(UUID().uuidString.prefix(6))"))
        isStartingScan = false
    }

    private func demoClean(report: CompanionCleanReport) async {
        let bytes = selectedCleanBytes
        let count = selectedCleanItems.count
        demoSetCleanProgress(CompanionCleanProgress(
            isCleaning: true, phase: "snapshot", progress: 0.15, statusText: "Creating APFS safety snapshot…",
            currentItem: nil, itemsCleaned: 0, totalItems: count, bytesReclaimed: 0, formattedBytesReclaimed: "0 B",
            snapshotName: nil, error: nil
        ))
        try? await Task.sleep(for: .milliseconds(800))
        demoSetCleanProgress(CompanionCleanProgress(
            isCleaning: false, phase: "completed", progress: 1.0,
            statusText: "Clean complete: Reclaimed \(iPhoneStorage.format(bytes: bytes))",
            currentItem: nil, itemsCleaned: count, totalItems: count, bytesReclaimed: bytes,
            formattedBytesReclaimed: iPhoneStorage.format(bytes: bytes),
            snapshotName: "com.apple.TimeMachine.2026-10-09-DemoSnapshot.local", error: nil
        ))
        lastCleanResult = CompanionCleanResponse(
            status: "completed", bytesReclaimed: bytes, formattedBytesReclaimed: iPhoneStorage.format(bytes: bytes),
            itemsRemoved: count, snapshotCreated: true,
            snapshotName: "com.apple.TimeMachine.2026-10-09-DemoSnapshot.local",
            tier: report.tier == "extreme" ? "Extreme Clean" : "Standard Clean"
        )
        var history = cleanReport?.history ?? []
        history.insert(CompanionCleanupRecord(
            id: "demo-\(history.count)", cleanedAt: Date(), bytesReclaimed: bytes, sizeText: iPhoneStorage.format(bytes: bytes),
            itemsRemoved: count, tier: report.tier ?? "standard", tierTitle: report.tier == "extreme" ? "Extreme Clean" : "Standard Clean",
            categoryTitles: ["User Caches"], itemTitles: selectedCleanItems.prefix(5).map(\.title),
            snapshotName: "com.apple.TimeMachine.2026-10-09-DemoSnapshot.local", source: "iPhone"
        ), at: 0)
        cleanReport = CompanionCleanReport(state: "idle", history: history)
        selectedCleanRefs = []
        seededScanId = nil
    }

    static func sampleCleanReport(state: String, tier: String, scanId: String = "demo") -> CompanionCleanReport {
        let history = [
            CompanionCleanupRecord(
                id: "demo-h1", cleanedAt: Date().addingTimeInterval(-3 * 3600), bytesReclaimed: 4_200_000_000, sizeText: "3.9 GB",
                itemsRemoved: 28, tier: "standard", tierTitle: "Standard Clean",
                categoryTitles: ["User Caches", "Developer Junk"], itemTitles: ["Xcode DerivedData", "com.apple.Safari", "npm cache"],
                snapshotName: "com.apple.TimeMachine.2026-10-09-091200.local", source: "iPhone"
            ),
            CompanionCleanupRecord(
                id: "demo-h2", cleanedAt: Date().addingTimeInterval(-3 * 86_400), bytesReclaimed: 1_300_000_000, sizeText: "1.2 GB",
                itemsRemoved: 9, tier: "standard", tierTitle: "Standard Clean",
                categoryTitles: ["Trash Bins"], itemTitles: ["Trash: old-build.zip"], snapshotName: nil, source: nil
            ),
        ]
        guard state == "ready" else { return CompanionCleanReport(state: state, tier: tier, history: history) }
        let extreme = tier == "extreme"
        var categories = [
            CompanionCleanCategory(
                id: "userCaches", title: "User Caches", description: "Application cache directories that can be safely rebuilt.", icon: "arrow.triangle.2.circlepath",
                isExtremeOnly: false, totalBytes: 2_600_000_000, totalText: "2.4 GB", itemCount: 3,
                items: [
                    CompanionCleanItem(id: "0.0", title: "com.apple.Safari", subtitle: "~/Library/Caches/com.apple.Safari", bytes: 1_400_000_000, sizeText: "1.3 GB", fileCount: 812, detail: nil, isSelected: true),
                    CompanionCleanItem(id: "0.1", title: "Google Chrome", subtitle: "~/Library/Caches/Google", bytes: 900_000_000, sizeText: "858 MB", fileCount: 390, detail: nil, isSelected: false),
                    CompanionCleanItem(id: "0.2", title: "com.spotify.client", subtitle: "~/Library/Caches/com.spotify.client", bytes: 300_000_000, sizeText: "286 MB", fileCount: 120, detail: "Spotify streaming & offline media cache", isSelected: false),
                ]
            ),
            CompanionCleanCategory(
                id: "developer", title: "Developer Junk", description: "Xcode DerivedData, Archives, iOS DeviceSupport, and package manager caches.", icon: "hammer",
                isExtremeOnly: false, totalBytes: 9_100_000_000, totalText: "8.5 GB", itemCount: 2,
                items: [
                    CompanionCleanItem(id: "1.0", title: "Xcode DerivedData", subtitle: "~/Library/Developer/Xcode/DerivedData", bytes: 7_000_000_000, sizeText: "6.5 GB", fileCount: 91_000, detail: "Build products Xcode rebuilds on demand.", isSelected: true),
                    CompanionCleanItem(id: "1.1", title: "npm cache", subtitle: "~/.npm", bytes: 2_100_000_000, sizeText: "2.0 GB", fileCount: 44_000, detail: nil, isSelected: true),
                ]
            ),
        ]
        if extreme {
            categories.append(CompanionCleanCategory(
                id: "aiArtifacts", title: "AI & Agent Junk", description: "Inactive AI agent session transcripts (>7 days) and temporary update downloads.", icon: "sparkles",
                isExtremeOnly: true, totalBytes: 1_800_000_000, totalText: "1.7 GB", itemCount: 1,
                items: [CompanionCleanItem(id: "2.0", title: "Agent session", subtitle: "~/.codex/archived_sessions/2026-09-01", bytes: 1_800_000_000, sizeText: "1.7 GB", fileCount: 310, detail: "Archived Codex transcript", isSelected: false)]
            ))
        }
        let total = categories.reduce(0) { $0 + $1.totalBytes }
        return CompanionCleanReport(
            state: "ready", scanId: scanId, tier: tier, scannedAt: Date(), totalBytes: total, totalText: iPhoneStorage.format(bytes: total),
            totalItems: categories.reduce(0) { $0 + $1.itemCount }, categories: categories, history: history
        )
    }
}
