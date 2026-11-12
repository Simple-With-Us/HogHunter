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
                        .foregroundStyle(run.result == .failed ? Color.red : run.result == .skipped ? Color.secondary : Color.orange)
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

/// A step or threshold change the person has asked for and not yet confirmed.
struct PendingMaintainChange {
    var title: String
    var message: String
    var confirmLabel: String
    var update: CompanionMaintainSettingsRequest
}

/// A threshold with a draft, so a tap on the stepper changes nothing on the
/// Mac until the person applies it and confirms.
private struct MaintainTuningRow: View {
    let title: String
    let unit: String
    let current: Double
    let range: ClosedRange<Double>
    let step: Double
    let note: String
    let isEnabled: Bool
    let onApply: (Double) -> Void
    @State private var draft: Double

    init(title: String, unit: String, current: Double, range: ClosedRange<Double>, step: Double, note: String, isEnabled: Bool, onApply: @escaping (Double) -> Void) {
        self.title = title
        self.unit = unit
        self.current = current
        self.range = range
        self.step = step
        self.note = note
        self.isEnabled = isEnabled
        self.onApply = onApply
        _draft = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: $draft, in: range, step: step) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(Int(draft)) \(unit)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!isEnabled)
            if draft != current {
                Button("Apply \(Int(draft)) \(unit)") { onApply(draft) }
                    .font(.subheadline.weight(.semibold))
                    .disabled(!isEnabled)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onChange(of: current) { _, value in draft = value }
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
    @State private var pendingChange: PendingMaintainChange?

    /// The newest snapshot.  This screen is pushed over the dashboard, so the
    /// value it was created with goes stale; the model's copy does not.
    private var live: CompanionSnapshot { model.snapshot ?? snapshot }
    private var maintain: CompanionMaintainStatus? { live.maintain }
    private var isAvailable: Bool { live.remoteMaintainAllowed != nil }
    private var isAllowed: Bool { live.remoteMaintainAllowed == true }
    private var isRunning: Bool { maintain?.isRunning == true || model.isStartingMaintain }

    static let offNote = "Running the Maintain from iPhone is off.\u{00A0} Turn on Allow iPhone to Run Maintenance in Hog Hunter Settings > iPhone on your Mac."
    static let tooOldNote = "This Mac's copy of Hog Hunter is older than this app and does not share the Maintain.\u{00A0} Update it on the Mac."
    static let runsTooOldNote = "This Mac's copy of Hog Hunter is older than this app and does not share its recent runs.\u{00A0} Update it on the Mac."

    var body: some View {
        List {
            statusSection
            runSection
            stepSettingsSection
            tuningSection
            customScriptsSection
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
        .confirmationDialog(
            pendingChange?.title ?? "",
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = pendingChange {
                Button(change.confirmLabel) {
                    pendingChange = nil
                    Task { await model.updateMaintainSettings(change.update) }
                }
            }
            Button("Cancel", role: .cancel) { pendingChange = nil }
        } message: {
            Text(pendingChange?.message ?? "")
        }
        .alert(
            "Could Not Change That",
            isPresented: Binding(
                get: { model.maintainSettingsError != nil },
                set: { if !$0 { model.maintainSettingsError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.maintainSettingsError = nil }
        } message: {
            Text(model.maintainSettingsError ?? "")
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
            Text("Run Now starts the full set of enabled steps.\u{00A0} Turn steps on or off below.")
        }
    }

    // MARK: - Settings

    /// Every built-in step with a switch.  Each switch asks first, and the
    /// remote server step asks in words of its own.
    @ViewBuilder
    private var stepSettingsSection: some View {
        if let settings = maintain?.stepSettings {
            Section {
                ForEach(settings) { step in
                    Toggle(isOn: Binding(
                        get: { step.isEnabled },
                        set: { pendingChange = Self.stepChange(step, turningOn: $0, host: live.hostName) }
                    )) {
                        Text(step.title)
                    }
                    .disabled(!isAllowed || model.isApplyingMaintainSettings)
                }
            } header: {
                Text("Steps to Run")
            } footer: {
                Text("These are Hog Hunter's built-in steps.\u{00A0} Custom scripts are turned on at the Mac only, because they run code this iPhone cannot see.")
            }
        }
    }

    static func stepChange(_ step: CompanionMaintainStepSetting, turningOn: Bool, host: String) -> PendingMaintainChange {
        var update = CompanionMaintainSettingsRequest(stepEnabled: [step.stepId: turningOn])
        if step.isRemoteServer, turningOn {
            update.acknowledgeRemoteServer = true
            return PendingMaintainChange(
                title: "Turn On Remote Server Maintenance?",
                message: "Every time \(host) runs the Maintain, it will connect to your remote server over SSH and clean package caches, rotated backup logs and unused build cache there when the server is short of disk.\u{00A0} That includes runs the Mac starts by itself.",
                confirmLabel: "Turn On Server Maintenance",
                update: update
            )
        }
        return PendingMaintainChange(
            title: "\(turningOn ? "Turn On" : "Turn Off") \(step.title)?",
            message: turningOn
                ? "\(host) will include this step in every Maintain run, including the runs it starts by itself."
                : "\(host) will skip this step in every Maintain run until you turn it back on.",
            confirmLabel: turningOn ? "Turn On" : "Turn Off",
            update: update
        )
    }

    @ViewBuilder
    private var tuningSection: some View {
        if let tuning = maintain?.tuning {
            let ready = isAllowed && !model.isApplyingMaintainSettings
            Section {
                MaintainTuningRow(
                    title: "Disk Threshold",
                    unit: "GB",
                    current: tuning.lowFreeGiB,
                    range: CompanionMaintainLimits.lowFreeGiBRange,
                    step: CompanionMaintainLimits.lowFreeGiBStep,
                    note: "Reclaim caches when free disk falls below this.",
                    isEnabled: ready
                ) { value in
                    pendingChange = PendingMaintainChange(
                        title: "Set the Disk Threshold to \(Int(value)) GB?",
                        message: "\(live.hostName) will reclaim caches in a run when free disk is below \(Int(value)) GB.",
                        confirmLabel: "Set to \(Int(value)) GB",
                        update: CompanionMaintainSettingsRequest(lowFreeGiB: value)
                    )
                }
                MaintainTuningRow(
                    title: "Worktree Retention",
                    unit: "days",
                    current: Double(tuning.worktreeRetireMinDays),
                    range: Double(CompanionMaintainLimits.worktreeRetireDaysRange.lowerBound)...Double(CompanionMaintainLimits.worktreeRetireDaysRange.upperBound),
                    step: 1,
                    note: "Only clean, merged, inactive worktrees are eligible.",
                    isEnabled: ready
                ) { value in
                    pendingChange = PendingMaintainChange(
                        title: "Keep Merged Worktrees \(Int(value)) Days?",
                        message: "\(live.hostName) will retire a merged git worktree once it has been idle for \(Int(value)) days.\u{00A0} A shorter time retires more of them.",
                        confirmLabel: "Set to \(Int(value)) Days",
                        update: CompanionMaintainSettingsRequest(worktreeRetireMinDays: Int(value))
                    )
                }
                MaintainTuningRow(
                    title: "PM2 Log Cap",
                    unit: "MB",
                    current: Double(tuning.pm2LogsCapMB),
                    range: Double(CompanionMaintainLimits.pm2LogsCapMBRange.lowerBound)...Double(CompanionMaintainLimits.pm2LogsCapMBRange.upperBound),
                    step: Double(CompanionMaintainLimits.pm2LogsCapMBStep),
                    note: "Truncate PM2 logs larger than this.",
                    isEnabled: ready
                ) { value in
                    pendingChange = PendingMaintainChange(
                        title: "Cap PM2 Logs at \(Int(value)) MB?",
                        message: "\(live.hostName) will truncate any PM2 log over \(Int(value)) MB in a run.",
                        confirmLabel: "Set to \(Int(value)) MB",
                        update: CompanionMaintainSettingsRequest(pm2LogsCapMB: Int(value))
                    )
                }
            } header: {
                Text("Thresholds")
            }
        }
    }

    /// The custom scripts the Mac lists, by name and state.  Read only.
    @ViewBuilder
    private var customScriptsSection: some View {
        if let scripts = maintain?.customScripts {
            Section {
                if scripts.isEmpty {
                    Text("No custom scripts or plugins found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scripts) { script in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.name)
                                    .font(.body.weight(.medium))
                                Text("\(script.mode.capitalized), \(script.scope)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(script.isEnabled ? "On" : "Off")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(script.isEnabled ? Color.green : Color.secondary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Custom Scripts")
            } footer: {
                Text("Read only.\u{00A0} Paths stay on \(live.hostName), and scripts are turned on or off there.")
            }
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
                Text("What the last run did.\u{00A0} Steps are turned on and off in Steps to Run, above.")
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
