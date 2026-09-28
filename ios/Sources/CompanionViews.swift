import SwiftUI

struct CompanionRootView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Hog Hunter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.saved != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Forget Mac") { model.forget() }
                        }
                    }
                }
        }
        .onAppear { model.start() }
        .sheet(isPresented: codePresented) {
            CodeEntryView(model: model)
                .presentationDetents([.medium])
        }
    }

    private var codePresented: Binding<Bool> {
        Binding(
            get: { if case .code = model.phase { return true } else { return false } },
            set: { if !$0 { model.cancelCode() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .live:
            if let snapshot = model.snapshot {
                DashboardView(snapshot: snapshot, model: model)
            } else {
                StatusPage(
                    title: "Waiting for a Snapshot",
                    message: "Hog Hunter is connected and waiting for the next sample from your Mac."
                )
            }
        case .choose:
            MacListView(model: model)
        case .offline:
            StatusPage(
                title: "Mac Not on this Wi-Fi",
                message: model.statusLine + "  Hog Hunter only shares while the Mac app is open and Share With iPhone is on."
            )
        case .looking, .code:
            StatusPage(
                title: "Looking for Your Mac",
                message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings.  Both devices need the same Wi-Fi."
            )
        }
    }
}

private struct StatusPage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 44))
                .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.78))
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct MacListView: View {
    let model: CompanionModel

    var body: some View {
        List(model.discovered) { mac in
            Button {
                model.select(mac)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Share With iPhone is on")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.discovered.isEmpty {
                StatusPage(
                    title: "Looking for Your Mac",
                    message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings."
                )
            }
        }
    }
}

private struct CodeEntryView: View {
    @Bindable var model: CompanionModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing Code") {
                    TextField("Code", text: $model.codeDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.title3, design: .monospaced))
                        .focused($focused)
                    Text("Type the code shown in Hog Hunter Settings on your Mac.  The iPhone can look at the list.  It cannot quit anything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let codeError = model.codeError {
                    Section {
                        Text(codeError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelCode() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { Task { await model.submitCode() } }
                        .disabled(model.isSubmittingCode)
                }
            }
            .onAppear { focused = true }
        }
    }
}

struct DashboardView: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @State private var showCleanConfirm = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.hostName)
                        .font(.headline)
                    Text("\(snapshot.window) · \(snapshot.grouping) · \(snapshot.cpuScale)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                HStack(alignment: .top, spacing: 12) {
                    MeterCard(
                        title: "CPU",
                        value: snapshot.pulse.cpuPercent,
                        headline: snapshot.pulse.cpuText,
                        caption: snapshot.pulse.cpuCaption,
                        severity: snapshot.pulse.cpuSeverity
                    )
                    MeterCard(
                        title: "Memory",
                        value: snapshot.pulse.memoryPercent,
                        headline: snapshot.pulse.memoryText,
                        caption: snapshot.pulse.memoryCaption,
                        severity: snapshot.pulse.pressureSeverity
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                if snapshot.pulse.swapText != nil || snapshot.pulse.pressureText != nil {
                    HStack(spacing: 8) {
                        if let swap = snapshot.pulse.swapText {
                            Pill(text: swap, severity: snapshot.pulse.pressureSeverity)
                        }
                        if let pressure = snapshot.pulse.pressureText {
                            Pill(text: pressure, severity: snapshot.pulse.pressureSeverity)
                        }
                    }
                }
            }
            Section("Disk & System Clutter") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Safe Mac Clean", systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        if model.isCleaning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Text("Remotely trigger a safe Standard Clean on \(snapshot.hostName). Cleans user caches, logs, developer junk, and empties trash with instant APFS snapshot rollback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let result = model.lastCleanResult {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Reclaimed \(result.formattedBytesReclaimed) (\(result.itemsRemoved) items) with APFS snapshot.")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 2)
                    }

                    if let error = model.cleanError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Button {
                        showCleanConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(model.isCleaning ? "Cleaning Mac…" : "Clean Mac Clutter (Safe)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isCleaning)
                }
                .padding(.vertical, 4)
            }
            .confirmationDialog(
                "Clean \(snapshot.hostName)?",
                isPresented: $showCleanConfirm,
                titleVisibility: .visible
            ) {
                Button("Run Safe Clean", role: .destructive) {
                    Task { await model.triggerRemoteClean() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will safely trigger a Standard Clean on \(snapshot.hostName). An APFS local snapshot will be taken first, and deleted items are moved to Trash.")
            }
            .onChange(of: model.showCleanDialogRequested) { _, requested in
                if requested {
                    showCleanConfirm = true
                    model.showCleanDialogRequested = false
                }
            }
            Section(snapshot.grouping == "Processes" ? "Busy Processes" : "Busy Apps") {
                if snapshot.rows.isEmpty {
                    Text(snapshot.hasBaseline ? "Nothing is busy right now." : "Measuring…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.rows) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.isApp ? "app.fill" : "gearshape")
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(row.cpuText)
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(rowColor(row.severity))
                                Text(row.memoryText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section {
                Text("Read only.  Quit stays on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rowColor(_ severity: String) -> Color {
        severity == "calm" ? Color.primary : CompanionColor.color(severity)
    }
}

private struct MeterCard: View {
    let title: String
    let value: Double
    let headline: String
    let caption: String
    let severity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ProgressView(value: min(max(value / 100, 0), 1))
                .tint(CompanionColor.color(severity))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(headline), \(caption)")
    }
}

private struct Pill: View {
    let text: String
    let severity: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(severity == "calm" ? Color.secondary : CompanionColor.color(severity))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

enum CompanionColor {
    static func color(_ severity: String) -> Color {
        switch severity {
        case "hot":
            return Color(red: 0.75, green: 0.18, blue: 0.16)
        case "elevated":
            return Color(red: 0.80, green: 0.52, blue: 0.10)
        default:
            return Color(red: 0.18, green: 0.42, blue: 0.78)
        }
    }
}
