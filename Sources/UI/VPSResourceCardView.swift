import AppKit
import SwiftUI

/// Remote VPS resource-usage card showing CPU, RAM (including swap),
/// and storage from `/root/vps-storage-status.json`.
struct VPSResourceCardView: View {
    @ObservedObject var store: VPSStatusStore
    @Environment(\.openSettings) private var openSettings

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
                if let cpu = snapshot.cpu { cpuBox(cpu) }
                if let mem = snapshot.memory { memoryBox(mem) }
                if let root = snapshot.rootDevice { deviceBox(root, title: "Disk (/)") }
                if let swap = snapshot.swap { swapBox(swap) }
                if let tmp = snapshot.tmpDevice {
                    deviceBox(tmp, title: "Tmpfs (/tmp)", tooltip: tmp.note)
                }
                if let shm = snapshot.shmDevice {
                    deviceBox(shm, title: "Shared Mem (/dev/shm)", tooltip: shm.note)
                }
            }

            let dbs = snapshot.appDbs ?? [:]
            let tools = snapshot.toolStatuses ?? []
            let dirs = snapshot.largestDirs ?? []
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
                        }
                        if tool.state == .running, tool.count > 1 {
                            Text("\(tool.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 11))
                    .help("\(tool.name): \(toolStatusLabel(tool.state))")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(tool.name), \(toolStatusLabel(tool.state))")
                    .accessibilityValue(tool.state == .running && tool.count > 1 ? "\(tool.count) processes" : "")
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
