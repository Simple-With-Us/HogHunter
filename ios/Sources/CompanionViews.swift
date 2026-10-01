import SwiftUI

enum CompanionTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case storage = "Storage"
    case network = "Network"
    var id: String { rawValue }
}

enum CompanionSort: String, CaseIterable, Identifiable {
    case cpu = "CPU %"
    case memory = "Memory"
    var id: String { rawValue }
}

enum UsageParser {
    static func parseCPU(_ text: String) -> Double {
        let digits = text.filter { $0.isNumber || $0 == "." }
        return Double(digits) ?? 0.0
    }

    static func parseMemoryBytes(_ text: String) -> UInt64 {
        let upper = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let numPart = upper.filter { $0.isNumber || $0 == "." }
        guard let val = Double(numPart) else { return 0 }
        if upper.contains("TB") {
            return UInt64(val * 1_099_511_627_776)
        } else if upper.contains("GB") {
            return UInt64(val * 1_073_741_824)
        } else if upper.contains("MB") {
            return UInt64(val * 1_048_576)
        } else if upper.contains("KB") {
            return UInt64(val * 1_024)
        } else {
            return UInt64(val)
        }
    }
}

extension CompanionRow {
    var sortCPU: Double {
        cpuPercent ?? UsageParser.parseCPU(cpuText)
    }

    var sortMemory: UInt64 {
        memoryBytes ?? UsageParser.parseMemoryBytes(memoryText)
    }
}

struct CompanionRootView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Hog Hunter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.remoteHostDraft = model.saved?.remoteHost ?? ""
                            model.remotePortDraft = "\(model.saved?.remotePort ?? 24240)"
                            model.remoteTokenDraft = model.saved?.token ?? ""
                            model.remoteNameDraft = model.saved?.name ?? ""
                            model.remoteConnectError = nil
                            model.isRemoteSheetPresented = true
                        } label: {
                            Image(systemName: "network.badge.shield.half.filled")
                        }
                        .accessibilityLabel("Connect Remotely")
                    }
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
        .sheet(isPresented: $model.isRemoteSheetPresented) {
            RemoteConnectSheet(model: model)
                .presentationDetents([.medium, .large])
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
                title: "Mac Offline or Not Found",
                message: model.statusLine + "  Hog Hunter shares while the Mac app is open and Share With iPhone is on.",
                onRemoteConnect: {
                    model.remoteConnectError = nil
                    model.isRemoteSheetPresented = true
                }
            )
        case .looking, .code:
            StatusPage(
                title: "Looking for Your Mac",
                message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings.  Both devices need the same Wi-Fi, or connect via Tailscale.",
                onRemoteConnect: {
                    model.remoteConnectError = nil
                    model.isRemoteSheetPresented = true
                }
            )
        }
    }
}

private struct StatusPage: View {
    let title: String
    let message: String
    var onRemoteConnect: (() -> Void)? = nil

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

            if let onRemoteConnect {
                Button(action: onRemoteConnect) {
                    Label("Connect via Tailscale or Domain…", systemImage: "network")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct MacListView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        List {
            Section("Nearby Macs") {
                ForEach(model.discovered) { mac in
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
            }

            Section {
                Button {
                    model.remoteConnectError = nil
                    model.isRemoteSheetPresented = true
                } label: {
                    Label("Connect via Tailscale or Domain…", systemImage: "network")
                }
            }
        }
        .overlay {
            if model.discovered.isEmpty {
                StatusPage(
                    title: "Looking for Your Mac",
                    message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings.",
                    onRemoteConnect: {
                        model.remoteConnectError = nil
                        model.isRemoteSheetPresented = true
                    }
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
    @State private var selectedTab: CompanionTab = .activity
    @State private var sortOrder: CompanionSort = .cpu
    @State private var showCleanConfirm = false

    private var sortedRows: [CompanionRow] {
        snapshot.rows.sorted { a, b in
            switch sortOrder {
            case .cpu:
                if a.sortCPU != b.sortCPU {
                    return a.sortCPU > b.sortCPU
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .memory:
                if a.sortMemory != b.sortMemory {
                    return a.sortMemory > b.sortMemory
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(CompanionTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            List {
                hostHeaderSection

                switch selectedTab {
                case .activity:
                    activityContent
                case .storage:
                    storageContent
                case .network:
                    networkContent
                }
            }
            .listStyle(.insetGrouped)
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
    }

    private var hostHeaderSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.hostName)
                        .font(.headline)
                    Text("\(snapshot.window) · \(snapshot.grouping) · \(snapshot.cpuScale)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.saved?.remoteHost != nil {
                    Label("Remote", systemImage: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var activityContent: some View {
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

        Section {
            if sortedRows.isEmpty {
                Text(snapshot.hasBaseline ? "Nothing is busy right now." : "Measuring…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(sortedRows.enumerated()), id: \.element.id) { index, row in
                    let rank = index + 1
                    HStack(spacing: 10) {
                        Text("#\(rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(rank <= 3 ? Color.orange : Color.secondary)
                            .frame(width: 26, alignment: .leading)

                        Image(systemName: row.isApp ? "app.fill" : "gearshape")
                            .frame(width: 20)
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
                                .font(.body.weight(sortOrder == .cpu ? .bold : .semibold).monospacedDigit())
                                .foregroundStyle(rowColor(row.severity))
                            Text(row.memoryText)
                                .font(.caption.weight(sortOrder == .memory ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(sortOrder == .memory ? Color.primary : Color.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            HStack {
                Text(snapshot.grouping == "Processes" ? "Busy Processes" : "Busy Apps")
                Spacer()
                Picker("Sort", selection: $sortOrder) {
                    ForEach(CompanionSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
            }
        }

        Section {
            Text("Read only.  Quit stays on the Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var storageContent: some View {
        Section("Mac Disk Usage") {
            if let storage = snapshot.storage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Macintosh HD", systemImage: "internaldrive")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.0f%% Used", storage.usedPercent))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(storage.usedPercent > 90 ? Color.red : (storage.usedPercent > 75 ? Color.orange : Color.primary))
                    }

                    ProgressView(value: min(max(storage.usedPercent / 100.0, 0), 1.0))
                        .tint(storage.usedPercent > 90 ? Color.red : (storage.usedPercent > 75 ? Color.orange : Color.accentColor))

                    HStack {
                        Text(storage.usedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(storage.freeText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("Disk telemetry will update with next sample.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
    }

    @ViewBuilder
    private var networkContent: some View {
        Section("Active Connection Hogs") {
            if let networkRows = snapshot.network, !networkRows.isEmpty {
                ForEach(networkRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(row.name)
                                .font(.body.weight(.medium))
                            Text("PID \(row.pid)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(row.establishedCount) active")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }

                        if !row.sampleRemoteHosts.isEmpty {
                            Text(row.sampleRemoteHosts.joined(separator: ", "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                VStack(alignment: .center, spacing: 8) {
                    Image(systemName: "network.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No active connection hogs detected on \(snapshot.hostName).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
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

struct RemoteConnectSheet: View {
    @Bindable var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac Connection Details") {
                    TextField("Host, Tailscale IP, or Domain", text: $model.remoteHostDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("Port", text: $model.remotePortDraft)
                        .keyboardType(.numberPad)

                    TextField("Pairing Code (from Mac Settings)", text: $model.remoteTokenDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    TextField("Mac Name (Optional)", text: $model.remoteNameDraft)
                }

                Section {
                    Text("Connect via Tailscale IP (e.g. 100.x.y.z), MagicDNS name (*.ts.net), or a domain mapped to your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = model.remoteConnectError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task {
                            await model.connectRemote()
                            if model.remoteConnectError == nil {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isConnectingRemote {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(model.isConnectingRemote ? "Connecting…" : "Connect to Mac")
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(model.isConnectingRemote || model.remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Remote Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
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
