import SwiftUI

/// The Mac's disk cleaner on the phone: pick Standard or Extreme, scan on the
/// Mac, tick what to clean, confirm, and read the history.  The Mac does the
/// scanning and the cleaning; this screen shows what it found and sends back
/// short references to the items the person ticked, never paths.
struct CleanerView: View {
    @Bindable var model: CompanionModel
    @State private var showConfirm = false
    @State private var expanded: Set<String> = []

    private var snapshot: CompanionSnapshot? { model.snapshot }
    private var hostName: String { snapshot?.hostName ?? "your Mac" }
    private var canClean: Bool { snapshot?.remoteCleanAllowed == true }
    private var report: CompanionCleanReport? { model.cleanReport }
    private var progress: CompanionCleanProgress? { snapshot?.cleanProgress }
    private var isCleaningNow: Bool { model.isCleaningSelection || progress?.isCleaning == true }
    private var isBusy: Bool { model.cleanScanIsRunning || isCleaningNow }
    private var isExtreme: Bool { model.cleanTier == "extreme" }
    /// Extreme needs the notice ticked, on the phone as on the Mac.
    private var tierReady: Bool { !isExtreme || model.extremeAcknowledged }
    /// The scan on screen belongs to the tier that is selected.
    private var scanMatchesTier: Bool { report?.state == "ready" && report?.tier == model.cleanTier }
    private var tierTitle: String { isExtreme ? "Extreme Clean" : "Standard Clean" }

    var body: some View {
        List {
            if !canClean {
                Section {
                    Text("Cleaning from iPhone is off.\u{00A0} Turn on Allow iPhone to Run Disk Cleaner in Hog Hunter Settings > iPhone on your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            tierSection
            statusSection
            if scanMatchesTier, let report {
                ForEach(report.categories) { category in
                    categorySection(category)
                }
            }
            historySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Disk Cleaner")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.cleanerError = nil
            await model.refreshCleanReport()
        }
        .onDisappear { model.cancelCleanerPolling() }
        .safeAreaInset(edge: .bottom) {
            if scanMatchesTier { actionBar }
        }
        .confirmationDialog(
            "Confirm \(tierTitle)",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Reclaim \(iPhoneStorage.format(bytes: model.selectedCleanBytes)) (\(tierTitle))", role: .destructive) {
                Task { await model.cleanSelection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CleanerCopy.confirmationMessage(
                sizeText: iPhoneStorage.format(bytes: model.selectedCleanBytes),
                itemCount: model.selectedCleanRefs.count
            ))
        }
        .alert(
            "Could Not Continue",
            isPresented: Binding(
                get: { model.cleanerError != nil },
                set: { if !$0 { model.cleanerError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.cleanerError = nil }
        } message: {
            Text(model.cleanerError ?? "")
        }
    }

    // MARK: - Mode

    private var tierSection: some View {
        Section {
            Picker("Mode", selection: $model.cleanTier) {
                Text("Standard Clean").tag("standard")
                Text("Extreme Clean").tag("extreme")
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)
            Text(isExtreme
                 ? "Deep scan of AI agent bloat, leftovers & large files."
                 : "Safe major clutter removal.\u{00A0} Protected by APFS snapshot & Trash Put-Back.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isExtreme {
                VStack(alignment: .leading, spacing: 8) {
                    Label(CleanerCopy.extremeTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.orange)
                    Text(CleanerCopy.extremeBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(CleanerCopy.extremeAcknowledgement, isOn: $model.extremeAcknowledged)
                        .font(.caption.weight(.medium))
                        .disabled(isBusy)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Scan state

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if let progress, progress.isCleaning || model.isCleaningSelection {
                cleaningProgress(progress)
            } else if model.cleanScanIsRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning \(hostName)…")
                            .font(.subheadline.weight(.semibold))
                        Text(report?.scanningCategory ?? "Starting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if scanMatchesTier, let report {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(iPhoneStorage.format(bytes: model.selectedCleanBytes))
                            .font(.title2.weight(.bold).monospacedDigit())
                        Text("ready to reclaim")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(report.totalText) total discovered across \(report.totalItems) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let scanned = report.scannedAt {
                        Text("Scanned \(CompanionRelative.text(for: scanned)) on \(hostName).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        report?.state == "ready" ? "Scan again for \(tierTitle)" : "Ready to scan system clutter",
                        systemImage: "sparkles"
                    )
                    .font(.subheadline.weight(.semibold))
                    Text("\(hostName) scans for \(isExtreme ? "everything in Standard plus leftovers, AI artifacts and large files" : "caches, logs, trash and developer junk").\u{00A0} Nothing is deleted until you confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let last = model.lastCleanResult, !isCleaningNow {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Reclaimed \(last.formattedBytesReclaimed) (\(last.itemsRemoved) items).")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            Button {
                model.beginCleanScan()
            } label: {
                HStack {
                    Spacer()
                    Label(scanMatchesTier ? "Rescan" : "Scan \(tierTitle)", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!canClean || isBusy || !tierReady)
            if isExtreme, !model.extremeAcknowledged {
                Text("Tick the notice above to scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cleaningProgress(_ progress: CompanionCleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress.statusText.isEmpty ? "Cleaning in progress…" : progress.statusText)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(progress.progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            ProgressView(value: max(0.05, progress.progress), total: 1.0)
            if progress.totalItems > 0 {
                Text("\(progress.itemsCleaned) of \(progress.totalItems) items cleaned")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Items

    private func categorySection(_ category: CompanionCleanCategory) -> some View {
        let isOpen = expanded.contains(category.id)
        let selectedCount = category.items.filter { model.selectedCleanRefs.contains($0.id) }.count
        let allSelected = model.isCleanCategoryFullySelected(category)
        return Section {
            HStack(spacing: 12) {
                Button {
                    if isOpen { expanded.remove(category.id) } else { expanded.insert(category.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.icon)
                            .frame(width: 24)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(category.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                if category.isExtremeOnly {
                                    Text("EXTREME ONLY")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                                }
                            }
                            Text("\(category.totalText) in \(category.itemCount) \(category.itemCount == 1 ? "item" : "items")\(selectedCount > 0 ? ", \(selectedCount) selected" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    // A borderless button tints its label; the title and the
                    // count read as ordinary text, like the Mac's rows.
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(category.title), \(category.totalText)")
                .accessibilityHint(isOpen ? "Hide items" : "Show items")

                Button {
                    model.setCleanCategory(category, selected: !allSelected)
                } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : (selectedCount > 0 ? "minus.circle.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(selectedCount > 0 ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(category.items.isEmpty || isBusy)
                .accessibilityLabel(allSelected ? "Deselect all in \(category.title)" : "Select all in \(category.title)")
            }

            if isOpen {
                ForEach(category.items) { item in
                    itemRow(item)
                }
                if category.itemCount > category.items.count {
                    Text("Showing the largest \(category.items.count) of \(category.itemCount) items.\u{00A0} The rest stay where they are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func itemRow(_ item: CompanionCleanItem) -> some View {
        let selected = model.selectedCleanRefs.contains(item.id)
        return Button {
            model.toggleCleanItem(item.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                Text(item.sizeText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Select All") { model.selectAllCleanItems() }
                Text("•").foregroundStyle(.tertiary)
                Button("Deselect All") { model.deselectAllCleanItems() }
                Spacer()
            }
            .font(.caption)
            .disabled(isBusy)
            Button {
                showConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text(isCleaningNow ? "Cleaning Mac…" : "Reclaim \(iPhoneStorage.format(bytes: model.selectedCleanBytes))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canClean || isBusy || model.selectedCleanRefs.isEmpty || !tierReady)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section {
            let history = report?.history ?? []
            if history.isEmpty {
                Text("No cleanups recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Freed \(record.sizeText)")
                                .font(.subheadline.weight(.semibold))
                            if record.source == "iPhone" {
                                Text("FROM IPHONE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            Spacer()
                            Text(CompanionRelative.text(for: record.cleanedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(record.tierTitle), \(record.itemsRemoved) \(record.itemsRemoved == 1 ? "item" : "items")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !record.categoryTitles.isEmpty {
                            Text(record.categoryTitles.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Cleanup History")
        } footer: {
            Text("Every clean that removes something is recorded on \(hostName), whether it started there or here.")
        }
    }
}

enum CompanionRelative {
    static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "3h ago", or "just now" inside ten seconds, where the formatter says "in 0s".
    static func text(for date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 10 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
