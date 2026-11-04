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

    var body: some View {
        let summary = snapshot.flaggedSummary()
        if summary != .unavailable {
            Section {
                switch summary {
                case .unavailable:
                    EmptyView()
                case .issues(_, let serverIncluded):
                    ForEach(snapshot.flaggedIssues ?? []) { issue in
                        FlaggedIssueRow(issue: issue)
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
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Server Tab

/// The Server tab.  Read-only: it shows what the Mac last read from the server,
/// next to the Mac itself, so it is always plain which machine a number is from.
struct ServerTabContent: View {
    let snapshot: CompanionSnapshot

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
            machinesSection(server: server)
            stateSection(server)
            if server.hasReading {
                ServerReadings(server: server)
            }
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
        } header: {
            Text("Mac and Server")
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
                LabeledContent("Reading From", value: ServerFormat.age(server.generatedAt))
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

/// Everything the block carries, in the order the Mac's card shows it.
private struct ServerReadings: View {
    let server: CompanionServerStatus

    var body: some View {
        activitySection
        pressureSection
        devicesSection
        sizeSection("App Databases", rows: server.databases)
        sizeSection("Directories", rows: server.directories)
        diagnosticsSection
        toolsSection
        processesSection
        workloadsSection
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
                    MeterRow(
                        title: device.title,
                        value: device.usedText,
                        percent: device.usedPercent,
                        severity: device.severity,
                        detail: deviceDetail(device)
                    )
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
                        }
                        Spacer(minLength: 8)
                        Text(workload.cpuText ?? ServerFormat.dash)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(workload.memoryText ?? ServerFormat.dash)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
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
