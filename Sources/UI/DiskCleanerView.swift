import AppKit
import Foundation
import SwiftUI

/// CleanMyMac-grade disk cleaner view inside Hog Hunter's Storage window.
/// Offers category-by-category breakdown, selective item inspection, and safe one-click reclamation.
struct DiskCleanerView: View {
    @StateObject private var store = DiskCleanerStore()

    var body: some View {
        VStack(spacing: 12) {
            heroHeader
            contentBody
            bottomBar
        }
        .onAppear {
            if case .idle = store.state {
                store.scan()
            }
        }
        .confirmationDialog(
            "Confirm Disk Cleanup",
            isPresented: $store.showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reclaim \(HogFormat.memory(store.totalSelectedBytes()))", role: .destructive) {
                store.cleanSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clean \(HogFormat.memory(store.totalSelectedBytes())) across \(store.totalSelectedItemsCount()) items?\n\nNon-trash items will be safely moved to your macOS Trash. Trash items will be permanently removed.")
        }
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
                }

                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        case .cleaning(let progress, let currentItem):
            VStack(spacing: 8) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                HStack {
                    Text("Cleaning: \(currentItem)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
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

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        if let report = store.report {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(report.categories) { catReport in
                        categoryCard(catReport)
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

    // MARK: - Category Card

    private func categoryCard(_ catReport: CleanCategoryReport) -> some View {
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
                    VStack(spacing: 0) {
                        ForEach(catReport.items) { item in
                            itemRow(item)
                            if item.id != catReport.items.last?.id {
                                Divider()
                                    .padding(.leading, 32)
                            }
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

    // MARK: - Item Row

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
            .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                store.revealInFinder(url: item.url)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .padding(.trailing, 8)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Category Icon

    private func categoryIconView(for category: CleanCategory) -> some View {
        let color: Color
        switch category {
        case .userCaches: color = .blue
        case .logsAndDiagnostics: color = .indigo
        case .trash: color = .red
        case .developer: color = .orange
        case .orphanedData: color = .purple
        case .largeAndOldFiles: color = .teal
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("Select All") {
                store.selectAll()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))

            Text("•")
                .foregroundStyle(.tertiary)

            Button("Deselect All") {
                store.deselectAll()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))

            Spacer()

            Button {
                store.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .controlSize(.small)

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
            .disabled(store.totalSelectedBytes() == 0 || isBusy)
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
