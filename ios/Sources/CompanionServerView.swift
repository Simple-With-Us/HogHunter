import SwiftUI

private enum ServerFormat {
    static let dash = CompanionServerStatus.dash

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func age(_ date: Date?) -> String {
        guard let date else { return "an unknown time ago" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func color(_ severity: String?) -> Color {
        CompanionColor.color(severity ?? "calm")
    }
}

// MARK: - Flagged Issues

/// Flagged Issues or All Systems Calm, covering the Mac and, when the phone
/// may see it, the server.  Says All Systems Calm only when that is true of
/// both: an empty list on a link that withholds the server's issues is the
/// Mac's calm alone.
struct FlaggedIssuesSection: View {
    let snapshot: CompanionSnapshot
    /// Whether this phone may offer an action now: its opt-in is on and this
    /// link is one the Mac takes controls on.  Off unless the caller says so.
    var canAct: (CompanionIssueAction) -> Bool = { _ in false }
    var onAction: (CompanionFlaggedIssue, CompanionIssueAction) -> Void = { _, _ in }

    var body: some View {
        let summary = snapshot.flaggedSummary()
        if summary != .unavailable {
            Section {
                switch summary {
                case .unavailable:
                    EmptyView()
                case .issues(_, let serverIncluded):
                    ForEach(snapshot.flaggedIssues ?? []) { issue in
                        FlaggedIssueRow(
                            issue: issue,
                            action: issue.actionKind.flatMap { canAct($0) ? $0 : nil },
                            onAction: { onAction(issue, $0) }
                        )
                    }
                    if !serverIncluded {
                        Text(Self.macOnlyNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .allCalm:
                    calmRow(title: "All Systems Calm", note: nil)
                case .macCalmServerNotShown:
                    calmRow(title: "This Mac Is Calm", note: Self.macOnlyNote)
                case .macCalmServerUnknown:
                    calmRow(title: "This Mac Is Calm", note: "The server has no current reading, so it is not counted here.")
                }
            } header: {
                if case .issues(let count, _) = summary {
                    Text("Flagged Issues (\(count))")
                } else {
                    Text("Flagged Issues")
                }
            }
        }
    }

    private static let macOnlyNote = "These cover this Mac.\u{00A0} See the Server tab for how to include the server."

    private func calmRow(title: String, note: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FlaggedIssueRow: View {
    let issue: CompanionFlaggedIssue
    /// The button to show, already checked against the opt-ins and the link.
    let action: CompanionIssueAction?
    let onAction: (CompanionIssueAction) -> Void

    private var tint: Color {
        switch issue.priority {
        case 0: return .red
        case 1: return .orange
        case 2: return .yellow
        case 3: return .blue
        default: return .secondary
        }
    }

    private var icon: String {
        switch issue.priority {
        case 0: return "exclamationmark.octagon.fill"
        case 1: return "exclamationmark.triangle.fill"
        case 2: return "exclamationmark.circle.fill"
        case 3: return "info.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.subheadline.weight(.medium))
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("\(issue.host) · \(issue.priorityText)", systemImage: issue.isServer ? "server.rack" : "laptopcomputer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let action {
                Spacer(minLength: 4)
                // Bordered, so only the button takes the tap, not the whole row.
                Button(action.title) { onAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("\(action.title): \(issue.title)")
            }
        }
    }
}

// MARK: - Server Tab

/// The Server tab.  Read-only: it shows what the Mac last read from the server,
/// next to the Mac itself, so it is always plain which machine a number is from.
struct ServerTabContent: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    /// The screenshot lane's flag.  The rows are far down a lazy list, so the
    /// frame's confirmation hangs off the top card instead.
    @State private var previewProcess: PendingServerProcessAction?
    /// The section the person last looked at.  A screenshot flag wins, so a
    /// capture never depends on what an earlier run stored.
    @AppStorage("hoghunter.ios.serverSection") private var storedSection = CompanionServerSection.overview.rawValue

    private var section: CompanionServerSection {
        CompanionServerSection.screenshotSection ?? CompanionServerSection.stored(storedSection)
    }

    static let optInNote = "Server status on iPhone is off.\u{00A0} Turn on Allow iPhone to See Server Status in Hog Hunter Settings > iPhone on your Mac."
    static let linkNote = "Server status is on, but it reaches only a phone paired with its own token on your local network or Tailscale.\u{00A0} Connect that way, or pair this phone again, to see it."
    static let tooOldNote = "This Mac's copy of Hog Hunter is older than this app and does not share server status.\u{00A0} Update it on the Mac."
    static let notConfiguredNote = "This Mac has no server set up.\u{00A0} Set an SSH host in Hog Hunter Settings > Maintenance on your Mac."
    static let noReadingNote = "The Mac has not read the server yet.\u{00A0} This updates on its own."

    var body: some View {
        switch snapshot.serverAccess {
        case .macTooOld:
            machinesSection(server: nil)
            noteSection(icon: "arrow.up.circle", title: "Update the Mac", note: Self.tooOldNote)
        case .optInOff:
            machinesSection(server: nil)
            noteSection(icon: "lock", title: "Server Status Is Off", note: Self.optInNote)
        case .notOnThisLink:
            machinesSection(server: nil)
            noteSection(icon: "network.slash", title: "Not Available on This Connection", note: Self.linkNote)
        case .available(let server):
            let frame = ServerScreenshotFrame.current
            if frame == .top {
                machinesSection(server: server)
                stateSection(server)
                if server.resolvedState() != .notConfigured {
                    refreshSection
                }
            }
            if frame == .top || frame == .section, server.hasReading {
                sectionPicker
            }
            if server.hasReading {
                ServerControlNote(snapshot: snapshot, model: model)
                // A section capture puts the maintenance controls ahead of the
                // tool rows, so the switch and Scan Server sit on screen.
                let controlsFirst = frame == .section
                if controlsFirst, server.host != nil, section.showsMaintenanceControls {
                    IncludeInMacMaintenanceSection(snapshot: snapshot, model: model)
                    ServerMaintenanceSection(snapshot: snapshot, model: model)
                }
                ServerReadings(server: server, section: section, controls: ServerRowControls(snapshot: snapshot, model: model))
                if !controlsFirst, server.host != nil, section.showsMaintenanceControls {
                    IncludeInMacMaintenanceSection(snapshot: snapshot, model: model)
                    ServerMaintenanceSection(snapshot: snapshot, model: model)
                }
            }
        }
    }

    /// The Mac's server sections, as a segmented picker under the cards.
    private var sectionPicker: some View {
        Section {
            Picker("Server Section", selection: Binding(
                get: { section },
                set: { storedSection = $0.rawValue }
            )) {
                ForEach(CompanionServerSection.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    /// The two machines side by side.  A phone that cannot read the server
    /// still shows the card, with dashes, so the layout does not imply there is
    /// only one machine.
    private func machinesSection(server: CompanionServerStatus?) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                MachineCard(
                    icon: "laptopcomputer",
                    kind: "Mac",
                    name: snapshot.hostName,
                    cpu: snapshot.hasBaseline ? snapshot.pulse.cpuText : nil,
                    cpuSeverity: snapshot.pulse.cpuSeverity,
                    memory: String(format: "%.0f%%", snapshot.pulse.memoryPercent),
                    memorySeverity: snapshot.pulse.pressureSeverity,
                    disk: snapshot.storage.map { String(format: "%.0f%% used", $0.usedPercent) },
                    diskSeverity: nil
                )
                MachineCard(
                    icon: "server.rack",
                    kind: "Server",
                    name: server?.host ?? ServerFormat.dash,
                    cpu: server?.headline?.cpuText,
                    cpuSeverity: server?.headline?.cpuSeverity,
                    memory: server?.headline?.memoryText,
                    memorySeverity: server?.headline?.memorySeverity,
                    disk: server?.headline?.diskText,
                    diskSeverity: server?.headline?.diskSeverity
                )
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .modifier(ServerProcessConfirmation(pending: $previewProcess, host: server?.host, model: model))
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("-HogHunterServerConfirm"), previewProcess == nil,
                      let row = server?.processes?.first else { return }
                previewProcess = PendingServerProcessAction(row: row, action: "quit")
            }
        } header: {
            Text("Mac and Server")
        }
    }

    /// The Mac card's Refresh button.  No confirmation: it reads the server
    /// again and changes nothing there.  Pull to refresh does the same.
    private var refreshSection: some View {
        Section {
            Button {
                Task { await model.refreshServer() }
            } label: {
                HStack {
                    Label("Refresh Server Reading", systemImage: "arrow.clockwise")
                    Spacer()
                    if model.isRefreshingServer {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isRefreshingServer || !model.controlsReachable)
            if let note = model.serverRefreshNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Asks the Mac to read the server now instead of at its next minute.\u{00A0} Nothing on the server changes.")
        }
    }

    private func noteSection(icon: String, title: String, note: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func stateSection(_ server: CompanionServerStatus) -> some View {
        switch server.resolvedState() {
        case .ok:
            Section {
                LabeledContent("Last Reading", value: ServerFormat.age(server.generatedAt))
            }
        case .notConfigured:
            noteSection(icon: "server.rack", title: "No Server Set Up", note: Self.notConfiguredNote)
        case .noReading:
            noteSection(icon: "hourglass", title: "No Reading Yet", note: Self.noReadingNote)
        case .stale:
            noteSection(
                icon: "clock.badge.exclamationmark",
                title: "Stale Reading",
                note: "The server's last reading is from \(ServerFormat.age(server.generatedAt)).\u{00A0} The numbers below may be out of date."
            )
        case .error:
            noteSection(
                icon: "exclamationmark.triangle.fill",
                title: "Could Not Read the Server",
                note: errorNote(server)
            )
        }
    }

    private func errorNote(_ server: CompanionServerStatus) -> String {
        let reason = server.errorText ?? "The Mac could not reach the server."
        guard server.hasReading else { return reason }
        return "\(reason)\u{00A0} The numbers below are from \(ServerFormat.age(server.generatedAt))."
    }
}

private struct MachineCard: View {
    let icon: String
    let kind: String
    let name: String
    let cpu: String?
    let cpuSeverity: String?
    let memory: String?
    let memorySeverity: String?
    let disk: String?
    let diskSeverity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            reading("CPU", cpu, cpuSeverity)
            reading("Memory", memory, memorySeverity)
            reading("Disk", disk, diskSeverity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func reading(_ label: String, _ value: String?, _ severity: String?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value ?? ServerFormat.dash)
                .monospacedDigit()
                .foregroundStyle(value == nil || severity == nil || severity == "calm" ? Color.primary : ServerFormat.color(severity))
        }
        .font(.caption)
    }
}

/// The screenshot lane's flags.  A UI capture sees only the top of a long list,
/// so a flag starts the list further down and every row gets looked at.
private enum ServerScreenshotFrame {
    /// `section` is a capture of one picker section: the cards above it are
    /// left off so the section's own rows sit on screen under the picker.
    case top, details, controls, section

    static var current: ServerScreenshotFrame {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-HogHunterServerControls") { return .controls }
        if arguments.contains("-HogHunterServerDetails") { return .details }
        if arguments.contains("-HogHunterServerActivity") || arguments.contains("-HogHunterServerStorage") || arguments.contains("-HogHunterServerMaintenance") { return .section }
        return .top
    }
}

/// Everything the block carries, in the order the Mac's card shows it.
private struct ServerReadings: View {
    let server: CompanionServerStatus
    let section: CompanionServerSection
    let controls: ServerRowControls

    var body: some View {
        // The details and controls frames start the Overview further down;
        // every other section shows its whole part.
        let frame = section == .overview ? ServerScreenshotFrame.current : .top
        if section.showsActivityReadings, frame == .top {
            activitySection
            pressureSection
        }
        if section.showsStorageReadings, frame != .controls {
            devicesSection
            sizeSection("App Databases", rows: server.databases)
            sizeSection("Directories", rows: server.directories)
            diagnosticsSection
        }
        if section.showsTools, frame != .controls {
            toolsSection
        }
        if frame != .details {
            if section.showsProcesses { processesSection }
            if section.showsWorkloads { workloadsSection }
        }
    }

    private var activitySection: some View {
        Section("Server Activity") {
            VStack(alignment: .leading, spacing: 6) {
                MeterRow(
                    title: "CPU",
                    value: server.cpu?.percentText,
                    percent: server.cpu?.percent,
                    severity: server.cpu?.severity,
                    detail: cpuDetail
                )
                if let history = server.cpu?.history, history.count >= 2 {
                    CpuSparklineView(samples: history, width: nil, height: 24)
                        .accessibilityLabel("Recent Server CPU")
                        .accessibilityValue("Latest \(Int(history.last ?? 0)) percent")
                }
            }
            MeterRow(title: "Memory", value: server.memory?.percentText, percent: server.memory?.percent, severity: server.memory?.severity, detail: server.memory?.detail)
            MeterRow(title: "Swap", value: server.swap?.percentText, percent: server.swap?.percent, severity: server.swap?.severity, detail: server.swap?.detail)
        }
    }

    private var cpuDetail: String {
        let cores = server.cpu?.cores.map { "\($0) cores" } ?? "\(ServerFormat.dash) cores"
        return "\(cores) · 1m load \(server.cpu?.loadText ?? ServerFormat.dash)"
    }

    @ViewBuilder
    private var pressureSection: some View {
        if let pressure = server.pressure {
            Section(pressure.isFresh() ? "Paging Activity" : "Paging Activity · Earlier Reading") {
                LabeledContent("Swap In", value: pressure.swapInText ?? ServerFormat.dash)
                LabeledContent("Swap Out", value: pressure.swapOutText ?? ServerFormat.dash)
                LabeledContent("Memory Stalls", value: pressure.memoryStallsText ?? ServerFormat.dash)
                if let sampledAt = pressure.sampledAt {
                    Text("Measured \(ServerFormat.age(sampledAt)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        if let devices = server.devices, !devices.isEmpty {
            Section("Server Disks") {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        MeterRow(
                            title: device.title,
                            value: device.usedText,
                            percent: device.usedPercent,
                            severity: device.severity,
                            detail: deviceDetail(device)
                        )
                        // The Mac shows this in the disk's tooltip.
                        if let note = device.note, !note.isEmpty {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func deviceDetail(_ device: CompanionServerDevice) -> String {
        let free = "\(device.freeText ?? ServerFormat.dash) free"
        guard let total = device.totalText else { return free }
        return "\(free) of \(total)"
    }

    @ViewBuilder
    private func sizeSection(_ title: String, rows: [CompanionServerSizeRow]?) -> some View {
        if let rows, !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    HStack {
                        Text(row.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(row.bytesText ?? ServerFormat.dash)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(row.changeText ?? ServerFormat.dash)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(changeColor(row.changePercent))
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(title)
            } footer: {
                Text("The right column is the change over the last day.")
            }
        }
    }

    private func changeColor(_ percent: Double?) -> Color {
        guard let percent, abs(percent) >= 0.1 else { return .secondary }
        return percent > 0 ? .red : .green
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let diagnostics = server.storageDiagnostics {
            Section {
                if diagnostics.categoriesComplete == true {
                    ForEach(diagnostics.categories ?? []) { category in
                        LabeledContent(category.title) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(category.sizeText ?? ServerFormat.dash)
                                    .monospacedDigit()
                                Text("Engine reclaimable \(category.reclaimableText ?? ServerFormat.dash)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Docker storage totals unavailable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if diagnostics.usesContainerd == true {
                    LabeledContent("Containerd Blobs", value: diagnostics.blobText ?? ServerFormat.dash)
                }
            } header: {
                Text(diagnostics.isFresh() ? "Container Storage" : "Container Storage · Earlier Reading")
            } footer: {
                Text("Readings overlap, so do not add them.\u{00A0} Engine reclaimable is not a cleanup recommendation.")
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        if let tools = server.tools, !tools.isEmpty {
            Section("Tools") {
                ForEach(tools) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(toolColor(tool.state))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.subheadline)
                            if let reason = tool.reason, tool.state != "running" {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(toolStateText(tool))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func toolStateText(_ tool: CompanionServerTool) -> String {
        if tool.state == "running", let count = tool.count, count > 1 {
            return "\(tool.stateText) (\(count))"
        }
        return tool.stateText
    }

    private func toolColor(_ state: String) -> Color {
        switch state {
        case "running": return .green
        case "unknown": return .orange
        default: return .secondary
        }
    }

    @ViewBuilder
    private var processesSection: some View {
        if let processes = server.processes {
            Section {
                if processes.isEmpty {
                    Text("No processes in the server's latest reading.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(processes) { process in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(process.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(process.cpuText ?? ServerFormat.dash)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Text(process.memoryText ?? ServerFormat.dash)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                            ServerProcessMenu(process: process, host: server.host, controls: controls)
                        }
                        if let caption = processCaption(process) {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack {
                    Text("Top Server Processes")
                    Spacer()
                    if let count = server.processCount {
                        Text("\(count) in all")
                    }
                }
            }
        }
    }

    private func processCaption(_ process: CompanionServerProcess) -> String? {
        var parts = [process.container ?? process.owner].compactMap { $0 }
        if let swap = process.swapText { parts.append("Swap \(swap)") }
        if process.isTamed == true { parts.append("Tamed") }
        if let reason = process.protectionReason { parts.append(reason) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var workloadsSection: some View {
        if let workloads = server.workloads, !workloads.isEmpty {
            Section("Coolify Workloads") {
                ForEach(workloads) { workload in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(workloadColor(workload))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workload.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text([workload.type, workload.status].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let reason = workload.protectionReason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(workload.cpuText ?? ServerFormat.dash)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(workload.memoryText ?? ServerFormat.dash)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
                        ServerWorkloadMenu(workload: workload, host: server.host, controls: controls)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func workloadColor(_ workload: CompanionServerWorkload) -> Color {
        switch workload.isHealthy {
        case true?: return .green
        case false?: return .orange
        case nil: return .secondary
        }
    }
}

/// A reading with a bar.  With no number there is no bar and a dash: an empty
/// bar would read as an idle machine.
private struct MeterRow: View {
    let title: String
    let value: String?
    let percent: Double?
    let severity: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(value ?? ServerFormat.dash)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            }
            if let percent {
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .tint(ServerFormat.color(severity))
            }
            Text(detail ?? ServerFormat.dash)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Server Controls

/// One finished server action, for the result sheet.
struct ServerActionOutcome: Identifiable {
    let id = UUID()
    let title: String
    let response: CompanionServerActionResponse

    static func strategyTitle(_ id: String) -> String {
        switch id {
        case CompanionServerControl.packageCacheStrategy: return "Package Cache"
        case CompanionServerControl.rotatedLogsStrategy: return "Rotated Backup Logs"
        case CompanionServerControl.buildCacheStrategy: return "Docker Build Cache"
        case CompanionServerControl.imageStrategy: return "Unused Docker Images"
        default: return id
        }
    }
}

/// Whether the rows may offer their actions on this link.
@MainActor
struct ServerRowControls {
    let snapshot: CompanionSnapshot
    let model: CompanionModel

    var enabled: Bool {
        snapshot.remoteServerControlAllowed == true && model.serverControlsReachable && !model.isRunningServerAction
    }
}

/// Says why the actions are missing, rather than offering ones that would fail.
private struct ServerControlNote: View {
    let snapshot: CompanionSnapshot
    let model: CompanionModel

    var body: some View {
        if snapshot.remoteServerControlAllowed == false {
            note(icon: "lock", title: "Server Controls Are Off", text: CompanionServerControl.optInNote)
        } else if snapshot.remoteServerControlAllowed == true, !model.serverControlsReachable {
            note(icon: "network.slash", title: "Server Controls Need Tailscale", text: CompanionServerControl.tailscaleOnlyNote)
        }
    }

    private func note(icon: String, title: String, text: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct PendingServerProcessAction: Equatable {
    let row: CompanionServerProcess
    let action: String

    /// Named for what it does, on the button and in the title.
    var buttonTitle: String {
        switch action {
        case "quit": return "Stop Process"
        case "forceQuit": return "Force Quit Process"
        case "tame": return "Tame Process"
        case "untame": return "Restore Priority"
        default: return "Sample Process"
        }
    }

    var isDestructive: Bool { action == "quit" || action == "forceQuit" }

    var message: String {
        switch action {
        case "tame", "untame":
            return "This changes scheduling priority and may affect response times.\u{00A0} The server rechecks the process identity and its protections before acting."
        case "sample":
            return "This reads the process's kernel counters for 3 seconds and changes nothing.\u{00A0} The result can name server internals."
        default:
            if row.container != nil {
                return "This interrupts a server workload and may lose unsaved work.\u{00A0} The server rechecks the process identity and its protections before acting."
            }
            return "Unsaved work may be lost.\u{00A0} The server rechecks the process identity and its protections before acting."
        }
    }
}

/// The confirmation every process action goes through.
private struct ServerProcessConfirmation: ViewModifier {
    @Binding var pending: PendingServerProcessAction?
    let host: String?
    let model: CompanionModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "\(pending?.buttonTitle ?? "Act On") \(pending?.row.name ?? "Process") on \(host ?? "the Server")?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmed = pending {
                Button(confirmed.buttonTitle, role: confirmed.isDestructive ? .destructive : nil) {
                    pending = nil
                    Task { await model.runServerAction(.process(rowId: confirmed.row.id, action: confirmed.action), rowName: confirmed.row.name) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.message ?? "")
        }
    }
}

private struct ServerProcessMenu: View {
    let process: CompanionServerProcess
    let host: String?
    let controls: ServerRowControls
    @State private var pending: PendingServerProcessAction?

    private static let titles = [("quit", "Stop Process…"), ("forceQuit", "Force Quit Process…"), ("tame", "Tame Process…"), ("untame", "Restore Priority…"), ("sample", "Sample Process…")]

    var body: some View {
        // A protected row has no actions, so it has no button at all.
        if controls.snapshot.remoteServerControlAllowed == true, process.actions?.isEmpty == false {
            Menu {
                ForEach(Self.titles, id: \.0) { action, title in
                    if process.actions?.contains(action) == true {
                        Button(title, role: action == "quit" || action == "forceQuit" ? .destructive : nil) {
                            pending = PendingServerProcessAction(row: process, action: action)
                        }
                    }
                }
            } label: {
                Label("Actions for \(process.name)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(!controls.enabled)
            .modifier(ServerProcessConfirmation(pending: $pending, host: host, model: controls.model))
        }
    }
}

private struct ServerWorkloadMenu: View {
    let workload: CompanionServerWorkload
    let host: String?
    let controls: ServerRowControls
    @State private var pendingAction: String?

    private func buttonTitle(_ action: String?) -> String {
        action == "stop" ? "Stop Workload" : "Restart Workload"
    }

    var body: some View {
        if controls.snapshot.remoteServerControlAllowed == true, workload.actions?.isEmpty == true {
            // A protected workload offers nothing.  The Mac keeps a disabled
            // menu with the reason as its help; the phone keeps a menu that
            // says the same thing.
            Menu {
                Button(workload.protectionReason ?? "No actions are offered for this workload.") {}
                    .disabled(true)
            } label: {
                Label("No actions for \(workload.name)", systemImage: "lock")
                    .labelStyle(.iconOnly)
            }
            .accessibilityHint(workload.protectionReason ?? "Protected")
        } else if controls.snapshot.remoteServerControlAllowed == true, workload.actions?.isEmpty == false {
            Menu {
                if workload.actions?.contains("stop") == true {
                    Button("Stop Workload…", role: .destructive) { pendingAction = "stop" }
                }
                if workload.actions?.contains("restart") == true {
                    Button("Restart Workload…") { pendingAction = "restart" }
                }
            } label: {
                Label("Actions for \(workload.name)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(!controls.enabled)
            .confirmationDialog(
                "\(buttonTitle(pendingAction)) \(workload.name) on \(host ?? "the Server")?",
                isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                titleVisibility: .visible
            ) {
                if let action = pendingAction {
                    Button(buttonTitle(action), role: .destructive) {
                        pendingAction = nil
                        Task { await controls.model.runServerAction(.workload(rowId: workload.id, action: action), rowName: workload.name) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            } message: {
                Text("This interrupts the server workload and may lose unsaved work.\u{00A0} Coolify may restart workloads it is configured to keep alive, and changed or protected containers are refused.")
            }
        }
    }
}

/// The Mac's Include in Mac Maintenance switch, beside server maintenance.  It
/// is the Maintain tab's remote server step: the same row, the same
/// confirmation and the same POST /v1/maintain/settings call, and it shows only
/// where the Maintain tab would let the switch be used.
private struct IncludeInMacMaintenanceSection: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @State private var pendingChange: PendingMaintainChange?

    private var live: CompanionSnapshot { model.snapshot ?? snapshot }
    private var step: CompanionMaintainStepSetting? {
        live.maintain?.stepSettings?.first(where: { $0.stepId == Self.stepId })
    }

    static let stepId = "coolify_remote"

    var body: some View {
        if live.remoteMaintainAllowed == true, let step {
            Section {
                Toggle("Include in Mac Maintenance", isOn: Binding(
                    get: { step.isEnabled },
                    set: { pendingChange = MaintainView.stepChange(step, turningOn: $0, host: live.hostName) }
                ))
                .disabled(model.isApplyingMaintainSettings)
                .confirmationDialog(
                    pendingChange?.title ?? "",
                    isPresented: Binding(get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } }),
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
                // A refusal, an unreachable Mac or a failed request lands in
                // maintainSettingsError; show it as the Maintain tab does, so
                // the switch does not snap back without a word.
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
            } footer: {
                Text("Uses the Mac's maintenance schedule, and the server's own schedule is unchanged.\u{00A0} Manual actions work with this option off.")
            }
        }
    }
}

/// Scan and run, as on the Mac's card.  A scan needs one confirmation and
/// changes nothing.  A run that removes images needs a second, separate one.
private struct ServerMaintenanceSection: View {
    let snapshot: CompanionSnapshot
    let model: CompanionModel
    @State private var selected: Set<String> = [
        CompanionServerControl.packageCacheStrategy,
        CompanionServerControl.rotatedLogsStrategy,
        CompanionServerControl.buildCacheStrategy,
    ]
    @State private var confirmScan = false
    @State private var confirmRun = false
    @State private var confirmImages = false

    private var enabled: Bool {
        snapshot.remoteServerControlAllowed == true && model.serverControlsReachable && !model.isRunningServerAction
    }
    private var host: String { snapshot.server?.host ?? "the Server" }
    /// In the order the Mac lists them, whichever order they were ticked in.
    private var chosen: [String] { CompanionServerControl.strategies.filter(selected.contains) }
    private var removesImages: Bool { selected.contains(CompanionServerControl.imageStrategy) }
    private var chosenTitles: String { chosen.map(ServerActionOutcome.strategyTitle).joined(separator: ", ") }

    var body: some View {
        if snapshot.remoteServerControlAllowed == true {
            Section {
                ForEach(CompanionServerControl.strategies, id: \.self) { strategy in
                    Toggle(ServerActionOutcome.strategyTitle(strategy), isOn: Binding(
                        get: { selected.contains(strategy) },
                        set: { if $0 { selected.insert(strategy) } else { selected.remove(strategy) } }
                    ))
                    .disabled(!enabled)
                }
                Button("Scan Server") { confirmScan = true }
                    .disabled(!enabled || chosen.isEmpty)
                    .confirmationDialog("Scan \(host)?", isPresented: $confirmScan, titleVisibility: .visible) {
                        Button("Scan Server") {
                            Task { await model.runServerAction(.maintain(mode: "scan", strategies: chosen, imageRemovalAcknowledged: false), rowName: "Server Scan") }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("A scan lists what is eligible for \(chosenTitles) and changes nothing.")
                    }
                Button("Run Server Maintenance", role: .destructive) { confirmRun = true }
                    .disabled(!enabled || chosen.isEmpty)
                    .confirmationDialog("Run Server Maintenance on \(host)?", isPresented: $confirmRun, titleVisibility: .visible) {
                        Button("Run Server Maintenance", role: .destructive) {
                            if removesImages {
                                // The first dialog has to finish closing, or the second never opens.
                                Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    confirmImages = true
                                }
                            } else {
                                run(acknowledged: false)
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently removes eligible items for \(chosenTitles), even when disk pressure is low.\u{00A0} The server rechecks age, current use, protection markers and the cleanup lock.")
                    }
                    .alert("Remove Unused Docker Images?", isPresented: $confirmImages) {
                        Button("Remove Images", role: .destructive) { run(acknowledged: true) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Removing old untagged images can remove local rollback options and require downloading or rebuilding them again.")
                    }
            } header: {
                Text("Server Maintenance")
            } footer: {
                Text("Only age-qualified, unused items are eligible.\u{00A0} Containers, volumes and active logs are protected.")
            }
        }
    }

    private func run(acknowledged: Bool) {
        Task { await model.runServerAction(.maintain(mode: "run", strategies: chosen, imageRemovalAcknowledged: acknowledged), rowName: "Server Maintenance") }
    }
}

/// What came back.  A sample or a scan can name server internals, and it is
/// shown here and kept nowhere.
struct ServerActionResultView: View {
    let outcome: ServerActionOutcome
    @Environment(\.dismiss) private var dismiss

    private var result: CompanionServerActionOutcome { outcome.response.outcome }

    private var icon: String {
        switch result {
        case .done: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .unknown: return "questionmark.circle.fill"
        case .noWork: return "minus.circle.fill"
        case .refused: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch result {
        case .done: return .green
        case .noWork: return .secondary
        case .partial, .unknown, .refused: return .orange
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(result.headline, systemImage: icon)
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(outcome.response.displayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let sample = outcome.response.sampleText {
                    Section("Process Sample") {
                        Text(sample)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let maintenance = outcome.response.maintenance {
                    Section("Strategies") {
                        ForEach(maintenance.strategies) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.subheadline)
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Section {
                        LabeledContent("Removed File Bytes", value: maintenance.removedBytesText ?? ServerFormat.dash)
                        LabeledContent("Available Space Change", value: maintenance.observedChangeText ?? ServerFormat.dash)
                    } footer: {
                        Text("Available space also changes with other server activity, and Docker requests do not prove physical bytes reclaimed.")
                    }
                }
            }
            .navigationTitle(outcome.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
