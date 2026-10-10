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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusCard
                    stepsSection
                    historySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
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
    private var header: some View {
        HStack {
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
        GroupBox("Cleaning Steps") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn steps off if you want them skipped on the next run.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(MaintainStore.catalog) { entry in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { store.stepToggles[entry.id] ?? true },
                            set: { store.setStepEnabled(entry.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.system(size: 12))
                                if let step = store.status?.stepLastResults[entry.id] {
                                    // Two lines, not one: the longest reasons name what
                                    // was skipped and why, and cutting them off hid that.
                                    Text("\(step.statusLabel) — \(step.reason)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
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
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
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
