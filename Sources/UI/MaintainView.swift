import SwiftUI

/// Maintain — scheduled cleaning at a glance.
///
/// The header stays put and the cards scroll under it, like the Disk Cleaner
/// and App Storage tabs.  With nine steps and twenty runs the cards are taller
/// than the menu bar panel, which is a fixed size: a plain stack would take its
/// natural height, the panel's frame would center it, and both ends would be
/// clipped (the panel's own header and tab picker went out of sight).  Every
/// card is pinned to the full width so none of them shrinks to its text.
struct MaintainView: View {
    @ObservedObject var store: MaintainStore
    /// SwiftUI's own "open the Settings scene" action, the only supported way
    /// into it; `showSettingsWindow:` sent to `NSApp` by hand is dropped here.
    @Environment(\.openSettings) private var openSettings
    var showHeader: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showHeader {
                header
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusCard
                    VPSResourceCardView(store: store.vpsStore)
                    stepsSection
                    historySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.trailing, 4)
            }
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }

    /// Only the action.  The tab's name and subtitle belong to `StorageView`,
    /// which renders a header for every tab; a second copy here put "Robotic
    /// Maintain" on screen twice, an inch apart.  Same defect as the two
    /// scan spinners: two render paths answering one question.  The header is
    /// what pushed the cards out of the panel, so it stays, minus the words.
    @State private var expandedStepIds: Set<String> = []

    private var header: some View {
        HStack {
            Button(action: {
                HogActions.openSettings(tab: .maintenance, using: openSettings)
            }) {
                Label("Modify Maintenance Settings…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)

            Spacer()
            Button("Run Now") { store.runNow("full") }
                .disabled(store.isRunningNow)
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: healthIcon)
                        .foregroundStyle(healthColor)
                    Text(store.status?.displayHealth ?? "Waiting for first run")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if store.isRunningNow {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status = store.status {
                    gridRow("Last full clean", formatDate(status.lastRunAt?["full"]))
                    gridRow("Next full clean", formatNext(status.nextRunAt["full"]))
                    gridRow("Background job", status.launchdLoaded ? "Loaded" : "Not loaded")
                }
                if let err = store.lastError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var stepsSection: some View {
        GroupBox("Active Maintenance Tasks") {
            VStack(alignment: .leading, spacing: 8) {
                if store.activeCatalog.isEmpty {
                    VStack(alignment: .center, spacing: 6) {
                        Text("No maintenance tasks are currently active.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Configure in Settings…") {
                            HogActions.openSettings(tab: .maintenance, using: openSettings)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else {
                    ForEach(store.activeCatalog) { entry in
                        stepCard(entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func stepCard(_ entry: MaintainStepCatalogEntry) -> some View {
        let isExpanded = expandedStepIds.contains(entry.id)
        let stepResult = store.status?.stepLastResults[entry.id]
        let history = store.history24h(for: entry.id)
        let status = classifyStepStatus(stepResult)

        return VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                if isExpanded {
                    expandedStepIds.remove(entry.id)
                } else {
                    expandedStepIds.insert(entry.id)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: status.icon)
                        .foregroundStyle(status.color)
                        .font(.system(size: 12))
                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    if !entry.tooltip.isEmpty {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(entry.tooltip)
                    }
                    Spacer()
                    Text(status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(status.color)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.tooltip.isEmpty ? entry.title : entry.tooltip)

            HStack(spacing: 8) {
                Text(history.lastRunDate != nil ? "Last run \(formatDate(history.lastRunDate))" : "Not run yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(format24hSummary(history))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            timelineBar(history)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .padding(.vertical, 2)
                    Text(entry.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let stepResult {
                        HStack(alignment: .top, spacing: 4) {
                            Text("Last run:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("\(stepResult.statusLabel) — \(stepResult.reason)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if stepResult.bytesFreed > 0 {
                            Text("Reclaimed \(HogFormat.memory(UInt64(stepResult.bytesFreed))) in \(stepResult.durationMs) ms")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }

                    Text("Past 24h: \(history.successCount) ran, \(history.skipCount) skipped, \(history.failCount) failed")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }

    private func timelineBar(_ history: Step24hHistory) -> some View {
        let displayOutcomes = Array(history.recentOutcomes.suffix(24))
        return HStack(spacing: 3) {
            if displayOutcomes.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 5)
                    .frame(maxWidth: .infinity)
                    .help("No runs in past 24 hours")
            } else {
                ForEach(displayOutcomes) { sample in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(sampleColor(sample.status))
                        .frame(height: 6)
                        .frame(maxWidth: .infinity)
                        .help("\(formatDate(sample.timestamp)): \(sample.status.capitalized) — \(sample.reason)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sampleColor(_ status: String) -> Color {
        switch status {
        case "ran": return .green
        case "failed": return .red
        default: return Color.secondary.opacity(0.3)
        }
    }

    private struct StepStatusDisplay {
        let label: String
        let icon: String
        let color: Color
    }

    private func classifyStepStatus(_ result: MaintainStepResult?) -> StepStatusDisplay {
        guard let result else {
            return StepStatusDisplay(label: "Not Run", icon: "questionmark.circle", color: .secondary)
        }
        if result.status == "ran" {
            return StepStatusDisplay(label: "Done", icon: "checkmark.circle.fill", color: .green)
        }
        if result.status == "failed" {
            return StepStatusDisplay(label: "Failed", icon: "xmark.circle.fill", color: .red)
        }
        let lower = result.reason.lowercased()
        if lower.contains("not configured") || lower.contains("misconfigured") || lower.contains("no host") {
            return StepStatusDisplay(label: "Misconfigured", icon: "exclamationmark.triangle.fill", color: .orange)
        }
        return StepStatusDisplay(label: "Skipped", icon: "minus.circle.fill", color: .secondary)
    }

    private func format24hSummary(_ history: Step24hHistory) -> String {
        if history.runsCount == 0 {
            return "0 runs in 24h"
        }
        if history.failCount > 0 {
            return "\(history.successCount) ran, \(history.failCount) failed in 24h"
        }
        return "\(history.successCount) of \(history.runsCount) runs in 24h"
    }

    /// The cleaning runs only: janitor, full, manual and pressure.  The quick
    /// disk and memory check runs every few minutes, so it gets one line above
    /// the list instead of filling it.  The phone shows the same.
    private var historySection: some View {
        let now = Date()
        let runs = CompanionMaintain.recentRuns(from: store.history)
        let watch = CompanionMaintain.watch(from: store.history, now: now)
        return GroupBox("Recent Runs") {
            VStack(alignment: .leading, spacing: 6) {
                if let watch {
                    Text(watch.summary(now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if runs.isEmpty {
                    Text("No cleaning runs recorded yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    // A grid, so the bytes and the times each line up in a column
                    // whatever the text is ("6 minutes ago" is wider than "1 hour
                    // ago", and "15 KB" than "0 KB"), both right-aligned.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(runs) { run in
                            GridRow {
                                HStack(spacing: 6) {
                                    Text(run.trigger.capitalized)
                                        .font(.system(size: 11, weight: .medium))
                                    if let mark = run.result.markLabel {
                                        Text(mark)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(run.result == .failed ? Color.red : Color.orange)
                                            .help(run.result == .failed
                                                ? "The run did not finish cleanly."
                                                : "A step failed, and the other steps still did their work.")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(HogFormat.memory(UInt64(max(0, run.bytesFreed))))
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .gridColumnAlignment(.trailing)
                                Text(formatDate(run.endedAt))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var healthIcon: String {
        switch store.status?.health {
        case "healthy": return "checkmark.circle.fill"
        case "overdue": return "clock.badge.exclamationmark"
        case "failed": return "exclamationmark.triangle.fill"
        case "unloaded": return "pause.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private var healthColor: Color {
        switch store.status?.health {
        case "healthy": return .green
        case "overdue", "failed": return .orange
        case "unloaded": return .red
        default: return .secondary
        }
    }

    private func gridRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
    }

    private func formatDate(_ epoch: Double?) -> String {
        guard let epoch, epoch > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: epoch)
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func formatNext(_ epoch: Double?) -> String {
        guard let epoch, epoch > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: epoch)
        if date < Date() { return "Due now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
