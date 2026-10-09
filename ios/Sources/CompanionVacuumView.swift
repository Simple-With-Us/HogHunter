import SwiftUI

/// What the phone draws for the Mac's health word, the same icons and colours
/// as the Robotic Vacuum card on the Mac.
private extension CompanionVacuumStatus {
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

private enum VacuumFormat {
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
}

/// The row on the Storage tab that leads to the Robotic Vacuum screen.
struct VacuumSummaryRow: View {
    let snapshot: CompanionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: snapshot.vacuum?.iconName ?? "sparkles")
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(snapshot.vacuum?.tint ?? Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Robotic Vacuum")
                    .font(.body.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.vacuum?.isRunning == true {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        if snapshot.remoteVacuumAllowed == nil { return "Not available on this Mac" }
        guard let vacuum = snapshot.vacuum else { return "Waiting for first run" }
        return vacuum.isRunning ? "Running now" : vacuum.displayHealth
    }
}

/// Robotic Vacuum on the Mac: whether it is on schedule, what its last run
/// did, and a Run Now button.
///
/// A run takes minutes and carries on at the Mac whether or not this screen
/// stays open.  The phone asks for it to start and then watches the snapshot.
/// Run Now acts on the Mac, so it asks first and says what a run can do.
struct VacuumView: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @State private var showRunConfirm = false

    /// The newest snapshot.  This screen is pushed over the dashboard, so the
    /// value it was created with goes stale; the model's copy does not.
    private var live: CompanionSnapshot { model.snapshot ?? snapshot }
    private var vacuum: CompanionVacuumStatus? { live.vacuum }
    private var isAvailable: Bool { live.remoteVacuumAllowed != nil }
    private var isAllowed: Bool { live.remoteVacuumAllowed == true }
    private var isRunning: Bool { vacuum?.isRunning == true || model.isStartingVacuum }

    static let offNote = "Running the Robotic Vacuum from iPhone is off.\u{00A0} Turn on Allow iPhone to Run Robotic Vacuum in Hog Hunter Settings > iPhone on your Mac."
    static let tooOldNote = "This Mac's copy of Hog Hunter is older than this app and does not share the Robotic Vacuum.\u{00A0} Update it on the Mac."

    var body: some View {
        List {
            statusSection
            runSection
            stepsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Robotic Vacuum")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Run the Robotic Vacuum on \(live.hostName)?",
            isPresented: $showRunConfirm,
            titleVisibility: .visible
        ) {
            Button("Run Robotic Vacuum", role: .destructive) {
                Task { await model.runVacuum() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(live.hostName) will run the full set of enabled steps.\u{00A0} That can retire old merged git worktrees, trim caches and build folders, and run maintenance on remote servers.\u{00A0} It can take several minutes, and the run carries on at the Mac even if you close this screen.")
        }
        .alert(
            "Could Not Run the Robotic Vacuum",
            isPresented: Binding(
                get: { model.vacuumError != nil },
                set: { if !$0 { model.vacuumError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.vacuumError = nil }
        } message: {
            Text(model.vacuumError ?? "")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            if !isAvailable {
                Text(Self.tooOldNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let vacuum {
                HStack {
                    Image(systemName: vacuum.iconName)
                        .foregroundStyle(vacuum.tint)
                        .accessibilityHidden(true)
                    Text(vacuum.displayHealth)
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
                LabeledContent("Last Full Clean", value: VacuumFormat.last(vacuum.lastFullRunAt))
                LabeledContent("Next Full Clean", value: VacuumFormat.next(vacuum.nextFullRunAt))
                // Before the first run there is no status to read this from.
                if vacuum.health != "unknown" {
                    LabeledContent("Background Job", value: vacuum.launchdLoaded ? "Loaded" : "Not loaded")
                }
                if let freed = vacuum.lastRunBytesFreed {
                    LabeledContent("Last Run Freed", value: VacuumFormat.bytes(freed))
                }
                if let ended = vacuum.lastRunEndedAt {
                    LabeledContent("Last Run Ended", value: VacuumFormat.last(ended))
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
                Text("\(live.hostName) has not recorded a Robotic Vacuum run yet.")
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
        if let steps = vacuum?.steps {
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
                                Text("Freed \(VacuumFormat.bytes(step.bytesFreed))")
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
                Text("Step results appear here once you allow iPhone to run the Robotic Vacuum.\u{00A0} They can name folders and servers on \(live.hostName), so the Mac shares them only with that setting on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What the Last Run Did")
            }
        }
    }

    private static func color(forStatus label: String) -> Color {
        switch label {
        case "Done": return .green
        case "Failed": return .red
        default: return .secondary
        }
    }
}
