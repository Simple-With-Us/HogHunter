import SwiftUI

/// What the phone draws for the Mac's health word, the same icons and colours
/// as the Maintain card on the Mac.
private extension CompanionMaintainStatus {
    var iconName: String {
        switch health {
        case "healthy": return "checkmark.circle.fill"
        case "overdue": return "clock.badge.exclamationmark"
        case "failed": return "exclamationmark.triangle.fill"
        case "unloaded": return "pause.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch health {
        case "healthy": return .green
        case "overdue", "failed": return .orange
        case "unloaded": return .red
        default: return .secondary
        }
    }
}

private enum MaintainFormat {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func last(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func next(_ date: Date?) -> String {
        guard let date else { return "Not scheduled" }
        if date < Date() { return "Due now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .file)
    }

    private static let spans: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    /// "20m" or "1h 3m".  Nil for a run that took under a second, which a
    /// watch tick usually does.
    static func took(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        return spans.string(from: TimeInterval(seconds))
    }
}

/// The row on the Storage tab that leads to the Maintain screen.
struct MaintainSummaryRow: View {
    let snapshot: CompanionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: snapshot.maintain?.iconName ?? "sparkles")
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(snapshot.maintain?.tint ?? Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Maintain")
                    .font(.body.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.maintain?.isRunning == true {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        if snapshot.remoteMaintainAllowed == nil { return "Not available on this Mac" }
        guard let maintain = snapshot.maintain else { return "Waiting for first run" }
        return maintain.isRunning ? "Running now" : maintain.displayHealth
    }
}

/// One line of the Recent Runs list, the way the Mac lists a run (what kind,
/// what it freed, when it ended), with how long it took and whether it failed
/// or only partly worked.
private struct MaintainRunRow: View {
    let run: CompanionMaintainRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(run.trigger.capitalized)
                    .font(.body.weight(.medium))
                if let mark = run.result.markLabel {
                    Text(mark)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(run.result == .failed ? Color.red : Color.orange)
                }
                Spacer()
                Text(run.bytesFreed > 0 ? "Freed \(MaintainFormat.bytes(run.bytesFreed))" : "Nothing freed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "3 hours ago, took 20m".
    private var detail: String {
        let ended = run.endedAt.map { MaintainFormat.relative.localizedString(for: $0, relativeTo: Date()) }
        let parts = [ended, MaintainFormat.took(run.durationSeconds).map { "took \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "No end time recorded" : parts.joined(separator: ", ")
    }
}

/// Maintain on the Mac: whether it is on schedule, what its last run
/// did, and a Run Now button.
///
/// A run takes minutes and carries on at the Mac whether or not this screen
/// stays open.  The phone asks for it to start and then watches the snapshot.
/// Run Now acts on the Mac, so it asks first and says what a run can do.
struct MaintainView: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @State private var showRunConfirm = false

    /// The newest snapshot.  This screen is pushed over the dashboard, so the
    /// value it was created with goes stale; the model's copy does not.
    private var live: CompanionSnapshot { model.snapshot ?? snapshot }
    private var maintain: CompanionMaintainStatus? { live.maintain }
    private var isAvailable: Bool { live.remoteMaintainAllowed != nil }
    private var isAllowed: Bool { live.remoteMaintainAllowed == true }
    private var isRunning: Bool { maintain?.isRunning == true || model.isStartingMaintain }

    static let offNote = "Running the Maintain from iPhone is off.\u{00A0} Turn on Allow iPhone to Run Maintain in Hog Hunter Settings > iPhone on your Mac."
    static let tooOldNote = "This Mac's copy of Hog Hunter is older than this app and does not share the Maintain.\u{00A0} Update it on the Mac."
    static let runsTooOldNote = "This Mac's copy of Hog Hunter is older than this app and does not share its recent runs.\u{00A0} Update it on the Mac."

    var body: some View {
        List {
            statusSection
            runSection
            stepsSection
            recentRunsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Maintain")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Run the Maintain on \(live.hostName)?",
            isPresented: $showRunConfirm,
            titleVisibility: .visible
        ) {
            Button("Run Maintain", role: .destructive) {
                Task { await model.runMaintain() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(live.hostName) will run the full set of enabled steps.\u{00A0} That can retire old merged git worktrees, trim caches and build folders, and run maintenance on remote servers.\u{00A0} It can take several minutes, and the run carries on at the Mac even if you close this screen.")
        }
        .alert(
            "Could Not Run the Maintain",
            isPresented: Binding(
                get: { model.maintainError != nil },
                set: { if !$0 { model.maintainError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.maintainError = nil }
        } message: {
            Text(model.maintainError ?? "")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            if !isAvailable {
                Text(Self.tooOldNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let maintain {
                HStack {
                    Image(systemName: maintain.iconName)
                        .foregroundStyle(maintain.tint)
                        .accessibilityHidden(true)
                    Text(maintain.displayHealth)
                        .font(.headline)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                if isRunning {
                    Text("A run is going on \(live.hostName).\u{00A0} This screen updates when it finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last Full Clean", value: MaintainFormat.last(maintain.lastFullRunAt))
                LabeledContent("Next Full Clean", value: MaintainFormat.next(maintain.nextFullRunAt))
                // Before the first run there is no status to read this from.
                if maintain.health != "unknown" {
                    LabeledContent("Background Job", value: maintain.launchdLoaded ? "Loaded" : "Not loaded")
                }
                // Which kind of run the next two rows and the steps below describe.
                if let trigger = maintain.lastRunTrigger {
                    LabeledContent("Last Run", value: trigger.capitalized)
                }
                if let freed = maintain.lastRunBytesFreed {
                    LabeledContent("Last Run Freed", value: MaintainFormat.bytes(freed))
                }
                if let ended = maintain.lastRunEndedAt {
                    LabeledContent("Last Run Ended", value: MaintainFormat.last(ended))
                }
            } else {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(isRunning ? "Running now" : "Waiting for first run")
                        .font(.headline)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("\(live.hostName) has not recorded a Maintain run yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status on \(live.hostName)")
        }
    }

    private var runSection: some View {
        Section {
            Button {
                showRunConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text(isRunning ? "Running…" : "Run Now")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isAllowed || isRunning)

            if isAvailable, !isAllowed {
                Text(Self.offNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Run Now starts the full set of enabled steps.\u{00A0} Turn a step off at the Mac, in the Storage tab.")
        }
    }

    @ViewBuilder
    private var stepsSection: some View {
        if let steps = maintain?.steps {
            Section {
                if steps.isEmpty {
                    Text("The last run recorded no steps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(step.title)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(step.statusLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Self.color(forStatus: step.statusLabel))
                            }
                            if !step.reason.isEmpty {
                                Text(step.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if step.bytesFreed > 0 {
                                Text("Freed \(MaintainFormat.bytes(step.bytesFreed))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("What the Last Run Did")
            } footer: {
                Text("Read only.\u{00A0} Steps are turned on and off at the Mac.")
            }
        } else if isAvailable, !isAllowed {
            Section {
                Text("Step results appear here once you allow iPhone to run the Maintain.\u{00A0} They can name folders and servers on \(live.hostName), so the Mac shares them only with that setting on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What the Last Run Did")
            }
        }
    }

    /// The Mac's Recent Runs list: the cleaning runs, with one line above them
    /// for the five minute checks.  A run carries no step text, and neither
    /// does the summary, so this needs no opt-in.
    @ViewBuilder
    private var recentRunsSection: some View {
        if isAvailable, let maintain {
            Section {
                if let runs = maintain.cleaningRuns {
                    if let watch = maintain.watch {
                        Text(watch.summary(now: Date()))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if runs.isEmpty {
                        Text("No cleaning runs recorded yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(runs) { run in
                            MaintainRunRow(run: run)
                        }
                    }
                } else {
                    Text(Self.runsTooOldNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Recent Runs")
            } footer: {
                if maintain.cleaningRuns?.isEmpty == false {
                    Text(maintain.watch == nil ? Self.recentRunsFooter : Self.recentRunsFooter + "\u{00A0} " + Self.watchFooterNote)
                }
            }
        }
    }

    /// What the list is and what Partial means.
    static let recentRunsFooter = "Newest first.\u{00A0} Partial means a step failed and the other steps still did their work."
    /// Why the list holds no disk and memory checks, said only while the line that counts them is on screen.
    static let watchFooterNote = "The quick disk and memory check that runs every few minutes is counted above, not listed."

    private static func color(forStatus label: String) -> Color {
        switch label {
        case "Done": return .green
        case "Failed": return .red
        default: return .secondary
        }
    }
}
