import AppKit
import SwiftUI

/// Which part of the server snapshot a card shows.
///
/// The dashboard's server sections each ask for the part that belongs to
/// them, so no two sections show the same readings and every section says
/// something different from the one before it.
enum VPSResourceSection: String {
    /// Everything the snapshot carries: the headline readings, the app
    /// databases, the largest directories and the tool states.
    case all
    /// CPU, memory and swap: the readings that describe what the server is
    /// doing right now.
    case activity
    /// The server's disks, its app databases and its largest directories.
    case storage
    /// The tool states: the maintenance work the server runs.
    case maintenance

    /// Whether this section shows the server's headline readings.
    var showsHeadline: Bool { self == .all || self == .activity }
    /// Whether this section shows the server's disks.
    var showsDevices: Bool { self == .all || self == .storage }
    /// Whether this section shows the app databases.
    var showsDatabases: Bool { self == .all || self == .storage }
    /// Whether this section shows the largest directories.
    var showsDirectories: Bool { self == .all || self == .storage }
    /// Whether this section shows the tool states.
    var showsTools: Bool { self == .all || self == .maintenance }
    /// Whether this section shows the Coolify workloads the server runs.
    var showsCoolify: Bool { self == .all || self == .activity }
    /// Whether this section shows the server's own processes.
    var showsProcesses: Bool { self == .all || self == .activity }
}

/// Remote VPS resource-usage card showing CPU, RAM (including swap),
/// and storage from `/root/vps-storage-status.json`.
struct VPSResourceCardView: View {
    @ObservedObject var store: VPSStatusStore
    @Environment(\.openSettings) private var openSettings
    /// Which part of the snapshot this card shows.
    var section: VPSResourceSection = .all
    /// The one action the owner can take on the server from here.
    @StateObject private var control = ServerControl()
    /// The process waiting for a confirmation.
    @State private var pendingProcess: VPSProcess?
    /// The workload waiting for a confirmation.
    @State private var pendingContainer: VPSCoolifyResource?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader
                if store.configuredHost.isEmpty {
                    unconfiguredView
                } else if let err = store.errorMessage, store.snapshot == nil {
                    errorView(err)
                } else if store.isLoading && store.snapshot == nil {
                    loadingView
                } else if let snapshot = store.snapshot {
                    snapshotContent(snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog(
            "Stop \(pendingProcess?.name ?? "this process") on the server?",
            isPresented: Binding(
                get: { pendingProcess != nil },
                set: { if !$0 { pendingProcess = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop it", role: .destructive) {
                guard let process = pendingProcess else { return }
                pendingProcess = nil
                Task { await control.stop(process: process, host: store.configuredHost) }
            }
            Button("Cancel", role: .cancel) { pendingProcess = nil }
        } message: {
            Text("The server stops it by its process identity, so a process that has changed since the reading is left alone.")
        }
        .confirmationDialog(
            "Stop \(pendingContainer?.name ?? "this workload") on the server?",
            isPresented: Binding(
                get: { pendingContainer != nil },
                set: { if !$0 { pendingContainer = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop it", role: .destructive) {
                guard let container = pendingContainer else { return }
                pendingContainer = nil
                Task { await control.stopContainer(named: container.stopName, host: store.configuredHost) }
            }
            Button("Cancel", role: .cancel) { pendingContainer = nil }
        } message: {
            Text("Coolify will restart a workload it is set to keep alive.")
        }
        .overlay(alignment: .bottomLeading) {
            if let outcome = control.lastOutcome {
                Text(outcome.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .padding(4)
            }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text(store.snapshot?.host ?? (store.configuredHost.isEmpty ? "Server Resources" : store.configuredHost))
                .font(.system(size: 13, weight: .semibold))
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            if let snapshot = store.snapshot {
                Text("Snapshot \(snapshot.relativeTimeString())")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                store.fetch(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh remote server resource status")
            .disabled(store.isLoading || store.configuredHost.isEmpty)
        }
    }

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No remote server configured.\u{00A0} Set an SSH host in Settings to monitor server CPU, RAM, and storage.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Configure in Settings…") {
                HogActions.openSettings(tab: .maintenance, using: openSettings)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.vertical, 4)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Unable to read server snapshot")
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") {
                store.fetch(force: true)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Connecting to remote host…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: VPSStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Three metrics across uses the panel's width before adding height.
            // Missing readings do not reserve empty metric cards.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 3), spacing: 8) {
                if section.showsHeadline, let cpu = snapshot.cpu { cpuBox(cpu) }
                if section.showsHeadline, let mem = snapshot.memory { memoryBox(mem) }
                if section.showsDevices, let root = snapshot.rootDevice { deviceBox(root, title: "Disk (/)") }
                if section.showsDevices, let fleetExtra = snapshot.fleetExtraDevice {
                    deviceBox(fleetExtra, title: "Fleet Extra (/mnt/fleet-extra)", tooltip: fleetExtra.note)
                }
                if section.showsHeadline, let swap = snapshot.swap { swapBox(swap) }
                if section.showsDevices, let tmp = snapshot.tmpDevice {
                    deviceBox(tmp, title: "Tmpfs (/tmp)", tooltip: tmp.note)
                }
                if section.showsDevices, let shm = snapshot.shmDevice {
                    deviceBox(shm, title: "Shared Mem (/dev/shm)", tooltip: shm.note)
                }
            }

            // A section only carries the readings it owns, so two sections
            // never show the same rows.
            let dbs = section.showsDatabases ? (snapshot.appDbs ?? [:]) : [:]
            let tools = section.showsTools ? (snapshot.toolStatuses ?? []) : []
            let dirs = section.showsDirectories ? (snapshot.largestDirs ?? []) : []
            let workloads = section.showsCoolify ? (snapshot.coolify ?? []) : []
            let processes = section.showsProcesses ? (snapshot.processes ?? []) : []
            if !processes.isEmpty {
                processesView(processes)
            }
            if !workloads.isEmpty {
                coolifyView(workloads)
            }
            if !dirs.isEmpty && (!dbs.isEmpty || !tools.isEmpty) {
                HStack(alignment: .top, spacing: 16) {
                    supportingReadings(dbs: dbs, tools: tools)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    largestDirsView(dirs)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                supportingReadings(dbs: dbs, tools: tools)
                if !dirs.isEmpty { largestDirsView(dirs) }
            }
        }
    }

    private func supportingReadings(dbs: [String: Int64], tools: [VPSToolStatus]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !dbs.isEmpty { appDbsRow(dbs) }
            if !tools.isEmpty { toolsView(tools) }
        }
    }

    private func cpuBox(_ cpu: VPSCPU) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CPU")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f%%", cpu.pct))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(cpu.severity.color)
            }
            ProgressView(value: min(max(cpu.pct / 100, 0), 1))
                .tint(cpu.severity.color)
            Text("\(cpu.cores) cores • 1m load: \(String(format: "%.2f", cpu.load1))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func memoryBox(_ mem: VPSMemory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Memory")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f%%", mem.usedPercentage))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(mem.severity.color)
            }
            ProgressView(value: min(max(mem.usedPercentage / 100, 0), 1))
                .tint(mem.severity.color)
            Text("\(HogFormat.memory(UInt64(mem.usedBytes))) / \(HogFormat.memory(UInt64(mem.totalBytes)))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func deviceBox(_ device: VPSDevice, title: String, tooltip: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let frac = device.usedFraction {
                    Text(String(format: "%.0f%% used", frac * 100))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Severity.forDisk(frac).color)
                }
            }
            if let frac = device.usedFraction {
                ProgressView(value: frac)
                    .tint(Severity.forDisk(frac).color)
            }
            Text("\(HogFormat.memory(UInt64(device.freeBytes))) free\(device.estimatedTotalBytes != nil ? " of \(HogFormat.memory(UInt64(device.estimatedTotalBytes!)))" : "")")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .help(tooltip ?? device.note ?? title)
    }

    private func swapBox(_ swap: VPSSwap) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Swap")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f%%", swap.usedPercentage))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(swap.severity.color)
            }
            ProgressView(value: min(max(swap.usedPercentage / 100, 0), 1))
                .tint(swap.severity.color)
            Text("\(HogFormat.memory(UInt64(swap.usedBytes))) of \(HogFormat.memory(UInt64(swap.totalBytes))) swapped")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func appDbsRow(_ dbs: [String: Int64]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("App Databases")
                    .font(.system(size: 11, weight: .semibold))
                Text("\u{00A0} (daily change)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach([("st_app_db", "Socratic Trade"), ("ct_db", "Congress Trade"), ("um_db", "Usage Monitor")], id: \.0) { key, name in
                if let bytes = dbs[key] {
                    SizeUsageRow(name: name, bytes: bytes, percentChange: store.databasePercentChange(key: key))
                }
            }
        }
    }

    private func largestDirsView(_ dirs: [VPSDirectory]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("Directories")
                    .font(.system(size: 11, weight: .semibold))
                Text("\u{00A0} (daily change)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(dirs) { dir in
                SizeUsageRow(name: dir.path, bytes: dir.bytes,
                             percentChange: store.directoryPercentChange(path: dir.path))
            }
        }
    }

    private func toolsView(_ tools: [VPSToolStatus]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tools")
                .font(.system(size: 11, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(tools) { tool in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(toolColor(tool.state))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name)
                            Text(toolStatusLabel(tool.state))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            // An unknown state is only useful when it says
                            // why it is unknown.  The reason is short enough
                            // to read in place and long enough to act on.
                            if tool.state == .unknown, let reason = tool.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        if tool.state == .running, tool.count > 1 {
                            Text("\(tool.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 11))
                    .help("\(tool.name): \(toolStatusLabel(tool.state))\(tool.reason.map { " — \($0)" } ?? "")")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(tool.name), \(toolStatusLabel(tool.state))")
                    .accessibilityValue(tool.state == .running && tool.count > 1 ? "\(tool.count) processes" : (tool.reason ?? ""))
                }
            }
        }
    }

    /// The Coolify workloads this host runs, and how each is doing.
    private func coolifyView(_ resources: [VPSCoolifyResource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Coolify Workloads")
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(resources) { resource in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(resource.isHealthy ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(resource.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(resource.type)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        if let cpu = resource.cpuPercent {
                            Text(String(format: "%.0f%%", cpu))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        }
                        if let memory = resource.memoryBytes {
                            Text(HogFormat.memory(UInt64(max(0, memory))))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button("Stop") { pendingContainer = resource }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .font(.system(size: 9))
                            .help("Stop this workload on the server")
                    }
                    .help("\(resource.name): \(resource.status)")
                }
            }
        }
    }

    /// The server's own processes, and the one action the owner can take on
    /// them.  The server stops a process by its identity, so a process that
    /// changed since the reading is refused rather than signalled.
    private func processesView(_ processes: [VPSProcess]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Top Processes")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(processes.count) processes")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(processes.prefix(12)) { process in
                    HStack(spacing: 8) {
                        Text(process.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if let container = process.container, !container.isEmpty {
                            Text(container)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%%", process.cpuPercent))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        if let memory = process.memoryBytes {
                            Text(HogFormat.memory(UInt64(max(0, memory))))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button("Stop") { pendingProcess = process }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .font(.system(size: 9))
                            .help("Stop this process on the server")
                    }
                }
                if processes.isEmpty {
                    Text("No processes in the server's latest reading.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toolStatusLabel(_ state: VPSToolStatus.State) -> String {
        switch state {
        case .running: return "running"
        case .stopped: return "not running"
        case .absent: return "not found"
        case .unknown: return "unknown"
        }
    }

    private func toolColor(_ state: VPSToolStatus.State) -> Color {
        switch state {
        case .running: return .green
        case .stopped: return .secondary
        case .absent: return .secondary.opacity(0.4)
        case .unknown: return .orange
        }
    }
}
