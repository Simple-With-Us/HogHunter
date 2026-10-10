import SwiftUI

/// Robotic Vacuum — scheduled cleaning at a glance.
struct RoboticVacuumView: View {
    @ObservedObject var store: RoboticVacuumStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard
            stepsSection
            historySection
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Robotic Vacuum")
                    .font(.system(size: 17, weight: .semibold))
                Text("Keeps your Mac tidy on a schedule.\u{00A0} You will be told if a run is late or stops.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            .padding(4)
        }
    }

    private var stepsSection: some View {
        GroupBox("Cleaning Steps") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn steps off if you want them skipped on the next run.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(RoboticVacuumStore.catalog) { entry in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { store.stepToggles[entry.id] ?? true },
                            set: { store.setStepEnabled(entry.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.system(size: 12))
                                if let step = store.status?.stepLastResults[entry.id] {
                                    Text("\(step.statusLabel) — \(step.reason)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    /// The cleaning runs only: janitor, full, manual and pressure.  The quick
    /// disk and memory check runs every few minutes, so it gets one line above
    /// the list instead of filling it.  The phone shows the same.
    private var historySection: some View {
        let now = Date()
        let runs = CompanionVacuum.recentRuns(from: store.history)
        let watch = CompanionVacuum.watch(from: store.history, now: now)
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
                    ForEach(runs) { run in
                        HStack {
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
                            Spacer()
                            Text(HogFormat.memory(UInt64(max(0, run.bytesFreed))))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(formatDate(run.endedAt))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
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
