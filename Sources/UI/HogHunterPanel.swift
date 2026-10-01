import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case storage = "Storage"

    var id: String { rawValue }
}

struct HogHunterPanel: View {
    @EnvironmentObject private var store: HogStore
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: PanelTab = .activity
    @State private var pendingQuit: HogRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch selectedTab {
            case .activity:
                meters
                captions
                controls
                list
                footer
            case .storage:
                StorageView(runningBundleIds: { store.runningBundleIdsSnapshot() }, embeddedInPanel: true)
            }
        }
        .padding(14)
        .frame(width: 560, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(store.appearance.colorScheme)
        .onAppear { store.panelVisible = true }
        .onDisappear { store.panelVisible = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hog Hunter — top processes")
        .alert(
            pendingQuit.map { "Quit \($0.name)?" } ?? "Quit Process?",
            isPresented: Binding(
                get: { pendingQuit != nil },
                set: { if !$0 { pendingQuit = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingQuit = nil }
            Button("Quit") {
                if let row = pendingQuit { store.quit(row, force: false) }
                pendingQuit = nil
            }
            Button("Force Quit", role: .destructive) {
                if let row = pendingQuit { store.quit(row, force: true) }
                pendingQuit = nil
            }
        } message: {
            Text(quitMessage)
        }
    }

    private var quitMessage: String {
        guard let row = pendingQuit else { return "" }
        let count = max(1, row.keys.count)
        let included = count == 1
            ? "1 process is included."
            : "\(count) processes are included."
        let forced = count == 1
            ? "Force Quit ends 1 process immediately.  Unsaved work is lost."
            : "Force Quit ends \(count) processes immediately.  Unsaved work is lost."
        return "Asks \(row.name) to quit.  It may show a save prompt or refuse.  \(included)"
            + "\n\n" + forced
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(Color(red: 0.86, green: 0.32, blue: 0.16))
                Text("Hog Hunter")
                    .font(.system(size: 17, weight: .semibold))
                Circle()
                    .fill(store.isStale
                          ? Color(red: 0.80, green: 0.52, blue: 0.10)
                          : Color(red: 0.16, green: 0.58, blue: 0.30))
                    .frame(width: 7, height: 7)
                if store.alertsEnabled {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Alerts on at \(Int(store.alertThresholdPercent))% for \(store.alertSustainedMinutes) min.")
                        .accessibilityLabel("Alerts on at \(Int(store.alertThresholdPercent))% for \(store.alertSustainedMinutes) minutes")
                }
            }

            Spacer()

            Picker("Tab", selection: $selectedTab) {
                Label("Activity", systemImage: "flame.fill").tag(PanelTab.activity)
                Label("Storage", systemImage: "internaldrive").tag(PanelTab.storage)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Spacer()

            gearMenu
        }
        .help(store.isStale ? "Sampling is behind." : "Sampling is up to date.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(store.isStale ? "Hog Hunter, sampling is behind" : "Hog Hunter, sampling is up to date")
    }

    private var gearMenu: some View {
        Menu {
            SettingsLink {
                Text("Settings…")
            }
            Button("Open Storage Window…") { HogActions.openStorageWindow(openWindow: openWindow) }
            Button("Network Window…") { HogActions.openNetworkWindow(openWindow: openWindow) }
            Divider()
            Button("Activity Monitor") { HogActions.openActivityMonitor() }
            Divider()
            Button("Quit Hog Hunter") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings, Storage, Network, Other Actions")
        .accessibilityLabel("Settings, Storage, Network, Other Actions")
    }

    // MARK: - Meters

    private var meters: some View {
        HStack(alignment: .top, spacing: 10) {
            Meter(
                title: "CPU",
                value: store.pulse.cpuPercent,
                caption: store.hasBaseline ? store.cpuCaption : "Measuring…",
                severity: Severity.forMachineCpu(store.pulse.cpuPercent)
            )
            VStack(alignment: .leading, spacing: 6) {
                Meter(
                    title: "Memory",
                    value: store.pulse.memoryPercent,
                    caption: store.memorySizeCaption,
                    severity: Severity.forPressure(store.pulse.pressure),
                    accessibilityDetail: store.memoryCaption
                )
                if !pills.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(pills, id: \.text) { pill in
                            MeterPill(text: pill.text, severity: pill.severity, help: pill.help)
                        }
                    }
                }
            }
        }
    }

    private struct Pill {
        var text: String
        var severity: Severity
        var help: String
    }

    /// Swap, pressure and thermal, in the order they usually start to matter.
    private var pills: [Pill] {
        var out: [Pill] = []
        if store.pulse.swapUsedBytes > 0 {
            out.append(Pill(
                text: "\(HogFormat.memory(store.pulse.swapUsedBytes)) swapped",
                severity: Severity.forPressure(store.pulse.pressure),
                help: "Memory the Mac has written to disk because RAM ran short."
            ))
        }
        if store.pulse.pressure != .unknown {
            out.append(Pill(
                text: "Pressure \(store.pulse.pressure.label)",
                severity: Severity.forPressure(store.pulse.pressure),
                help: "How hard the Mac is working to find free memory."
            ))
        }
        if store.pulse.thermalState != .nominal {
            out.append(Pill(
                text: "Thermal \(Self.thermalLabel(store.pulse.thermalState))",
                severity: Self.thermalSeverity(store.pulse.thermalState),
                help: "macOS slows the machine down as this rises."
            ))
        }
        return out
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func thermalSeverity(_ state: ProcessInfo.ThermalState) -> Severity {
        switch state {
        case .nominal, .fair: return .calm
        case .serious: return .elevated
        case .critical: return .hot
        @unknown default: return .calm
        }
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let attributed = store.attributionCaption {
                Text(attributed)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !store.hasBaseline {
                Text("Measuring…  The first CPU reading needs two samples.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let swapping = store.swapRateCaption {
                Text(swapping)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let notice = store.lastNotice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.historyError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Window", selection: $store.window) {
                ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Picker("Show", selection: $store.grouping) {
                    ForEach(HogGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Sort", selection: $store.sort) {
                    ForEach(HogSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
        }
        .labelsHidden()
    }

    // MARK: - Rows

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if store.rows.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
                ForEach(store.rows) { row in
                    HogRowView(
                        row: row,
                        scale: store.cpuScale,
                        coreCount: store.pulse.coreCount,
                        store: store
                    ) {
                        pendingQuit = row
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if !store.hasBaseline { return "Measuring…" }
        if store.window == .now { return "Nothing heavy right now." }
        return "No history yet.  Leave Hog Hunter open to build it."
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { _ in store.toggleLoginItem() }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                if let error = store.loginItemError {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(store.coverageNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.scaleLegend)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}
