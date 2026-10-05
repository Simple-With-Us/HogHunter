import AppKit
import Foundation
import SwiftUI

/// Disk cleaner view inside Hog Hunter's Storage window.
/// Offers category-by-category breakdown, selective item inspection, and safe one-click reclamation.
struct DiskCleanerView: View {
    @ObservedObject var store: DiskCleanerStore
    var isTabActive: Bool = true
    @State private var showExclusionsSheet = false

    var body: some View {
        VStack(spacing: 10) {
            tierSelector
            if store.selectedTier == .extreme {
                extremeDisclaimerBanner
            }
            heroHeader
            contentBody
            bottomBar
        }
        .onAppear {
            if isTabActive, case .idle = store.state {
                store.scan()
            }
            store.refreshLastCleanup()
        }
        .onChange(of: isTabActive) { active in
            if active, case .idle = store.state {
                store.scan()
            }
            store.refreshLastCleanup()
        }
        .onDisappear {
            store.cancelScan()
        }
        .sheet(isPresented: $showExclusionsSheet) {
            CleanerExclusionsSheet(store: store)
        }
        .confirmationDialog(
            "Confirm \(store.selectedTier.title)",
            isPresented: $store.showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reclaim \(HogFormat.memory(store.totalSelectedBytes())) (\(store.selectedTier.title))", role: .destructive) {
                store.cleanSelected(createSnapshot: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clean \(HogFormat.memory(store.totalSelectedBytes())) across \(store.totalSelectedItemsCount()) items?  An APFS local snapshot is created first.  If that snapshot fails, nothing is deleted.  Items that are not already in the Trash move to the Trash, where Put Back still works.  Items already in the Trash are removed permanently.")
        }
    }

    // MARK: - Tier Selector & Disclaimer

    private var tierSelector: some View {
        HStack {
            Text("Mode:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("Tier", selection: Binding(
                get: { store.selectedTier },
                set: { store.setTier($0) }
            )) {
                ForEach(CleanTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .disabled(isBusy)

            Spacer()

            Text(store.selectedTier.badge)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(store.selectedTier == .extreme ? Color.orange.opacity(0.18) : Color.blue.opacity(0.15))
                )
                .foregroundStyle(store.selectedTier == .extreme ? Color.orange : Color.blue)
        }
        .padding(.horizontal, 2)
    }

    private var extremeDisclaimerBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Extreme Clean Targets AI Agent & Deep Developer Clutter")
                    .font(.system(size: 11, weight: .bold))
            }
            Text("Extreme Clean scans for uninstalled app leftovers, older AI agent transcripts (>7 days) across Gemini/Grok/Codex, temporary update downloads, and large/old files.\nWhile git repositories and critical directories are strictly protected, local AI tools may need to re-download model caches, re-index workspaces, or re-authenticate ephemeral CLI sessions.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $store.acknowledgedExtremeDisclaimer) {
                Text("I understand this targets AI tool caches, orphaned app data, and older transcripts.")
                    .font(.system(size: 10, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Hero Header

    @ViewBuilder
    private var heroHeader: some View {
        switch store.state {
        case .idle:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text("Ready to scan system clutter")
                        .font(.system(size: 13, weight: .medium))
                }
                Text("Select Reclaim to start cleaning")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        case .scanning(let category):
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scanning system clutter…")
                        .font(.system(size: 13, weight: .medium))
                }
                Text(category)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        case .scanned(let report):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: "sparkles")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(HogFormat.memory(store.totalSelectedBytes()))
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.primary)
                            Text("ready to reclaim")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text("\(HogFormat.memory(report.totalBytes)) total discovered across \(report.categories.map(\.items.count).reduce(0, +)) items")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // The number a person actually weighs the decision against is
                    // not "13 GB is reclaimable" but "13 GB against how much room
                    // is left".  Without the volume side of that ratio the button
                    // is a leap of faith.
                    volumeGauge
                        .frame(width: 152)
                }

                if let last = store.lastCleanup {
                    Text("Last cleanup \(CleanupHistoryStore.relativeDate(for: last.cleanedAt)) — freed \(last.formattedBytesReclaimed)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        case .cleaning(let progress, let currentItem):
            VStack(spacing: 8) {
                if currentItem.contains("snapshot") {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Creating APFS safety snapshot (this can take 15–30s)…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                } else {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                }
                HStack {
                    Text("Cleaning: \(currentItem)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if currentItem.contains("snapshot") {
                        Text("Working…")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        case .cleaned(let result):
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reclaimed \(result.formattedBytesReclaimed)!")
                        .font(.system(size: 16, weight: .bold))
                    Text("Cleaned \(result.itemsRemoved) items safely.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if !result.errors.isEmpty {
                        Text("\(result.errors.count) items could not be deleted (system locked).")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                Button("Scan Again") {
                    store.scan()
                }
                .controlSize(.regular)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        case .failed(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Encountered an Issue")
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") { store.scan() }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    /// Free space on the startup volume, and how much of it this clean would
    /// hand back.  `DiskSpace` is the same reading the panel's Storage card
    /// uses, so the two can never disagree.
    private var volumeGauge: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Startup Volume")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(volumeCaption)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            ProgressView(value: min(max(volumeUsedFraction, 0), 1))
                .tint(Severity.forDisk(volumeUsedFraction).color)
            Text(volumeDetail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .help("Reclaiming everything selected would take free space from this to the number below.  macOS counts purgeable space as available, so a healthy disk can look nearly full here and still be fine.")
    }

    private var volumeSpace: DiskSpace? { DiskSpace.current() }

    private var volumeUsedFraction: Double { volumeSpace?.usedFraction ?? 0 }

    private var volumeCaption: String {
        guard let volumeSpace else { return "Reading…" }
        return "\(HogFormat.memory(volumeSpace.freeBytes)) free"
    }

    private var volumeDetail: String {
        guard let volumeSpace else { return "" }
        let after = max(0, volumeSpace.freeBytes) + store.totalSelectedBytes()
        return "→ \(HogFormat.memory(after)) of \(HogFormat.memory(volumeSpace.totalBytes))"
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        if let report = store.report {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(report.categories) { catReport in
                        CategoryCardView(catReport: catReport, store: store)
                    }
                }
                .padding(.vertical, 2)
            }
        } else {
            VStack {
                Spacer()
                ProgressView()
                Text("Analyzing disk clutter…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer()
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("Select All") {
                store.selectAll()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(isBusy)

            Text("•")
                .foregroundStyle(.tertiary)

            Button("Deselect All") {
                store.deselectAll()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(isBusy)

            Text("•")
                .foregroundStyle(.tertiary)

            Button {
                showExclusionsSheet = true
            } label: {
                let count = store.exclusions.excludedCategories.count + store.exclusions.excludedPaths.count
                Label(count > 0 ? "Exclusions (\(count))" : "Exclusions…", systemImage: "shield")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .disabled(isBusy)

            Spacer()

            Button {
                store.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(isBusy)

            Button {
                store.showConfirmation = true
            } label: {
                let selectedBytes = store.totalSelectedBytes()
                Text("Reclaim \(HogFormat.memory(selectedBytes))")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(store.totalSelectedBytes() == 0 || isBusy || (store.selectedTier == .extreme && !store.acknowledgedExtremeDisclaimer))
        }
        .padding(.top, 4)
    }

    private var isBusy: Bool {
        switch store.state {
        case .scanning, .cleaning: return true
        default: return false
        }
    }
}

// MARK: - Category Card View

private struct CategoryCardView: View {
    let catReport: CleanCategoryReport
    @ObservedObject var store: DiskCleanerStore
    @State private var displayLimit: Int = 50

    var body: some View {
        let isExpanded = store.isCategoryExpanded(catReport.category)
        let isFullySelected = store.isCategoryFullySelected(catReport.category)
        let isPartiallySelected = store.isCategoryPartiallySelected(catReport.category)

        return VStack(spacing: 0) {
            // Header Row
            HStack(spacing: 10) {
                Button {
                    store.toggleCategorySelection(catReport.category)
                } label: {
                    Image(systemName: isFullySelected ? "checkmark.square.fill" : (isPartiallySelected ? "minus.square.fill" : "square"))
                        .font(.system(size: 15))
                        .foregroundStyle(isFullySelected || isPartiallySelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFullySelected ? "Deselect \(catReport.category.title)" : "Select \(catReport.category.title)")

                categoryIconView(for: catReport.category)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(catReport.category.title)
                            .font(.system(size: 12, weight: .semibold))
                        if catReport.items.count > 0 {
                            Text("(\(catReport.items.count))")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(catReport.category.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(catReport.formattedTotalSize)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .layoutPriority(1)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.toggleCategoryExpanded(catReport.category)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityLabel(isExpanded ? "Collapse \(catReport.category.title)" : "Expand \(catReport.category.title)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Items List when Expanded
            if isExpanded {
                Divider()
                if catReport.items.isEmpty {
                    Text("No items found in this category.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    let visibleItems = Array(catReport.items.prefix(displayLimit))
                    let remainingCount = catReport.items.count - visibleItems.count

                    LazyVStack(spacing: 0) {
                        ForEach(visibleItems) { item in
                            itemRow(item)
                            if item.id != visibleItems.last?.id || remainingCount > 0 {
                                Divider()
                                    .padding(.leading, 32)
                            }
                        }
                        if remainingCount > 0 {
                            HStack(spacing: 10) {
                                Text("Showing \(visibleItems.count) of \(catReport.items.count) files")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Show Next \(min(50, remainingCount))") {
                                    displayLimit += 50
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 10))

                                Button("Show All (\(catReport.items.count))") {
                                    displayLimit = catReport.items.count
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 10))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func itemRow(_ item: CleanItem) -> some View {
        let isSelected = store.isItemSelected(item)

        return HStack(spacing: 8) {
            Button {
                store.toggleItemSelection(item)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(item.title)" : "Select \(item.title)")
            .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if item.canRevealInFinder {
                Button {
                    store.revealInFinder(url: item.url)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(item.title) in Finder")
                .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 5)
    }

    private func categoryIconView(for category: CleanCategory) -> some View {
        let color: Color
        switch category {
        case .userCaches: color = .blue
        case .logsAndDiagnostics: color = .indigo
        case .trash: color = .red
        case .developer: color = .orange
        case .orphanedData: color = .purple
        case .aiArtifacts: color = .green
        case .localAIModels: color = .mint
        case .largeAndOldFiles: color = .teal
        case .apfsSnapshots: color = .cyan
        }

        return ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 26, height: 26)
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Exclusions Sheet

private struct CleanerExclusionsSheet: View {
    @ObservedObject var store: DiskCleanerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cleaner Exclusions & Safety")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section("Category Exclusions") {
                    Text("Excluded categories are skipped during scans and will never be cleaned.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    ForEach(CleanCategory.allCases) { category in
                        Toggle(isOn: Binding(
                            get: { store.exclusions.isCategoryExcluded(category) },
                            set: { _ in store.toggleCategoryExclusion(category) }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: category.icon)
                                    .frame(width: 16)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(category.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Custom Excluded Folders") {
                    Text("Files in these directories or their subfolders are preserved and skipped.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if store.exclusions.excludedPaths.isEmpty {
                        Text("No custom excluded folders.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(store.exclusions.excludedPaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    store.removeExcludedPath(path)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove exclusion")
                            }
                        }
                    }

                    Button("Add Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Exclude Folder"
                        if panel.runModal() == .OK, let url = panel.url {
                            store.addExcludedPath(url.path)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 420)
    }
}

