import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case storage = "Storage"
    case network = "Network"

    var id: String { rawValue }
}

struct HogHunterPanel: View {
    @EnvironmentObject private var store: HogStore
    /// SwiftUI's own "open the Settings scene" action.  Sending
    /// `showSettingsWindow:` to `NSApp` by hand is silently dropped here and
    /// the gear button did nothing; this is the supported path.
    @Environment(\.openSettings) private var openSettings
    @State private var selectedTab: PanelTab = .activity
    @State private var pendingQuit: HogRow?
    @State private var hasVisitedStorage: Bool = false
    @State private var hasVisitedNetwork: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .frame(width: Self.contentWidth)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    meters
                    captions
                    controls
                    list
                    footer
                }
                .opacity(selectedTab == .activity ? 1 : 0)
                .allowsHitTesting(selectedTab == .activity)
                .accessibilityHidden(selectedTab != .activity)

                if hasVisitedStorage {
                    StorageView(runningBundleIds: { store.runningBundleIdsSnapshot() }, embeddedInPanel: true, isTabActive: selectedTab == .storage)
                        .frame(width: Self.contentWidth, alignment: .leading)
                        .clipped()
                        .opacity(selectedTab == .storage ? 1 : 0)
                        .allowsHitTesting(selectedTab == .storage)
                        .accessibilityHidden(selectedTab != .storage)
                }

                if hasVisitedNetwork {
                    NetworkView(bundleResolver: { pid in store.lookup(pid: pid) }, bandwidth: store.bandwidth, embeddedInPanel: true, isTabActive: selectedTab == .network)
                        // Both lines are load-bearing.  A tab's own content
                        // decides its ideal width, and a long unwrapped string
                        // anywhere in it (a hostname list, a footer sentence)
                        // pushes that past the panel.  `ZStack` lays a child out
                        // at its ideal width *before* the enclosing frame is
                        // applied, so without this the panel briefly renders
                        // wider than itself and crops.  Fixing it at the
                        // container means no child can ever do that again,
                        // whatever text is added later.
                        .frame(width: Self.contentWidth, alignment: .leading)
                        .clipped()
                        .opacity(selectedTab == .network ? 1 : 0)
                        .allowsHitTesting(selectedTab == .network)
                        .accessibilityHidden(selectedTab != .network)
                }
            }
            // Every child is laid out at exactly the panel's inner width.  A
            // `VStack` sizes itself to its widest child's *ideal* width, and a
            // long unwrapped caption -- the attribution line especially -- is
            // wider than the panel, so without this the whole column is laid
            // out past the edge and clipped on both sides instead of wrapping.
            .frame(width: Self.contentWidth, alignment: .leading)
        }
        .padding(Self.inset)
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(store.appearance.colorScheme)
        .onChange(of: selectedTab) { newTab in
            if newTab == .storage {
                hasVisitedStorage = true
            } else if newTab == .network {
                hasVisitedNetwork = true
            }
        }
        .onAppear {
            store.panelVisible = true
            if selectedTab == .storage {
                hasVisitedStorage = true
            } else if selectedTab == .network {
                hasVisitedNetwork = true
            }
        }
        .onDisappear {
            store.panelVisible = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selectedTab == .activity ? "Hog Hunter — top processes" : (selectedTab == .storage ? "Hog Hunter — storage and disk cleaner" : "Hog Hunter — network activity"))
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

    // MARK: - Metrics

    static let panelWidth: CGFloat = 620
    static let panelHeight: CGFloat = 680
    static let inset: CGFloat = 14
    /// What is left of the panel once the inset is taken off both sides.
    static var contentWidth: CGFloat { panelWidth - inset * 2 }
    /// Fixed so the control row cannot resize itself when a segment changes.
    static let windowPickerWidth: CGFloat = 260
    static let groupPickerWidth: CGFloat = 125
    static let sortPickerWidth: CGFloat = 110

    private var quitMessage: String {        guard let row = pendingQuit else { return "" }
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
                Image("HogProfile")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 15)
                Text("Hog Hunter")
                    .font(.system(size: 17, weight: .semibold))
                if store.isStale {
                    Text("Sampling Behind")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.15))
                        )
                }
            }
            .help(store.isStale ? "Sampling is behind." : "Sampling is up to date.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(store.isStale ? "Hog Hunter, sampling is behind" : "Hog Hunter, sampling is up to date")

            Spacer()

            Picker("Tab", selection: $selectedTab) {
                Label("Activity", image: "HogProfile").tag(PanelTab.activity)
                Label("Storage", systemImage: "internaldrive").tag(PanelTab.storage)
                Label("Network", systemImage: "network").tag(PanelTab.network)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)

            Spacer()

            activityMonitorButton
            settingsButton
        }
    }

    /// Activity Monitor's own icon rather than a look-alike SF Symbol, so the
    /// button is recognisably that app and not another chart.  A borderless
    /// button matches the gear beside it.
    private var activityMonitorButton: some View {
        Button {
            HogActions.openActivityMonitor()
        } label: {
            Image(nsImage: HogActions.activityMonitorIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Open Activity Monitor")
        .accessibilityLabel("Open Activity Monitor")
    }

    /// Opens Settings rather than a menu.  Storage and Network left this menu
    /// when they became tabs in this window, so what was left was one action,
    /// and one action does not need a menu to hold it.
    private var settingsButton: some View {
        Button {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
            // openSettings() from Environment sometimes fails for accessory apps.
            // sendAction is the robust fallback.
            NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, from: nil)
            openSettings()
            // The scene builds its window asynchronously, so the "already
            // open? come forward" pass has to be retried, not run once.
            HogActions.scheduleFrontSettingsWindow()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    // MARK: - Meters

    private var meters: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Meter(
                    title: "CPU",
                    value: store.pulse.cpuPercent,
                    caption: store.hasBaseline ? store.cpuCaption : "Measuring…",
                    severity: Severity.forMachineCpu(store.pulse.cpuPercent)
                )
                pillRow(thermalPills)
                diskCard
            }
            VStack(alignment: .leading, spacing: 6) {
                Meter(
                    title: "Memory",
                    value: store.pulse.memoryPercent,
                    caption: store.memorySizeCaption,
                    severity: Severity.forPressure(store.pulse.pressure),
                    accessibilityDetail: store.memoryCaption
                )
                pillRow(memoryPills)
            }
        }
    }

    /// The third card, under CPU: how full the boot volume is.  It is a button
    /// because the answer to "how full is it" is usually "which app did that",
    /// which is one click away in the Storage tab.
    private var diskCard: some View {
        Button {
            selectedTab = .storage
            hasVisitedStorage = true
        } label: {
            Meter(
                title: "Storage",
                value: (store.diskSpace?.usedFraction ?? 0) * 100,
                caption: store.diskSpaceCaption,
                severity: Severity.forDisk(store.diskSpace?.usedFraction ?? 0)
            )
        }
        .buttonStyle(.plain)
        .help("Free space on the startup volume.  Click for the Storage tab.")
        .accessibilityLabel("Storage")
        .accessibilityValue(store.diskSpaceCaption)
    }

    /// Empty when there is nothing to say, so the row collapses instead of
    /// reserving an empty band under the meter.
    @ViewBuilder
    private func pillRow(_ pills: [Pill]) -> some View {
        if !pills.isEmpty {
            WrappingHStack(spacing: 4, lineSpacing: 4) {
                ForEach(pills, id: \.text) { pill in
                    MeterPill(text: pill.text, severity: pill.severity, help: pill.help)
                }
            }
        }
    }

    private struct Pill {
        var text: String
        var severity: Severity
        var help: String
    }

    /// Swap and memory pressure: both are statements about RAM.
    private var memoryPills: [Pill] {
        var out: [Pill] = []
        if store.pulse.swapUsedBytes > 0 {
            out.append(Pill(
                text: "\(HogFormat.memory(store.pulse.swapUsedBytes)) Swapped",
                severity: Severity.forPressure(store.pulse.pressure),
                help: "Memory the Mac has written to disk because RAM ran short."
            ))
        }
        if store.pulse.pressure != .unknown {
            out.append(Pill(
                text: "Pressure \(store.pulse.pressure.displayLabel)",
                severity: Severity.forPressure(store.pulse.pressure),
                help: "How hard the Mac is working to find free memory."
            ))
        }
        // Battery came in with #50 and stays exactly where it was.  Thermal
        // used to live here too and does not any more: it moved to
        // `thermalPills` under CPU, because `ProcessInfo.thermalState` is a
        // machine-wide die reading rather than anything about RAM.
        if let pct = store.pulse.batteryPercent {
            let isCharging = store.pulse.isCharging ?? false
            let isBattery = store.pulse.powerSource == "Battery Power"
            if isBattery || pct < 100 {
                let severity: Severity = pct <= 20 ? .hot : (pct <= 40 ? .elevated : .calm)
                let icon = isCharging ? "⚡ " : ""
                let text = "\(icon)\(pct)% Battery"
                out.append(Pill(
                    text: text,
                    severity: severity,
                    help: isCharging ? "Charging (\(pct)%)." : "Running on battery (\(pct)%).  High CPU processes increase discharge rate."
                ))
            }
        }
        return out
    }

    /// Thermal state sits under CPU, not Memory.  `ProcessInfo.thermalState` is
    /// a single machine-wide reading of the SoC die, so it has nothing to do
    /// with RAM -- what it predicts is clock throttling, which is what the CPU
    /// meter above it is measuring.
    private var thermalPills: [Pill] {
        guard store.pulse.thermalState != .nominal else { return [] }
        return [Pill(
            text: "Thermal \(Self.thermalLabel(store.pulse.thermalState))",
            severity: Self.thermalSeverity(store.pulse.thermalState),
            help: "How hot the CPU and GPU are running.  macOS slows the machine down when this stays high."
        )]
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
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

    /// All three pickers on one row.
    ///
    /// A segmented picker given no width takes its ideal width -- which for
    /// "Past 24 Hours" is far wider than the words need, because every segment
    /// is padded to the longest label.  So the two short ones take exactly
    /// their ideal width and the time window, whose labels genuinely are long,
    /// gets the remainder.  That keeps "CPU" and "Memory" from each claiming a
    /// third of the window surrounded by empty track, and it is why the panel
    /// is 620 rather than 560 wide.
    /// Three distinct, labeled control groups: Time window, App grouping, and Sort with direction toggle.
    private var controls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TIME")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Picker("Window", selection: $store.window) {
                    ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Self.windowPickerWidth)
                .animation(nil, value: store.window)
            }

            Divider()
                .frame(height: 20)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("SHOW")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Picker("Show", selection: $store.grouping) {
                    ForEach(HogGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Self.groupPickerWidth)
                .animation(nil, value: store.grouping)
            }

            Divider()
                .frame(height: 20)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("SORT")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Picker("Sort", selection: $store.sort) {
                        ForEach(HogSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Self.sortPickerWidth)
                    .animation(nil, value: store.sort)

                    Button {
                        store.sortAscending.toggle()
                    } label: {
                        Image(systemName: store.sortAscending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 22, height: 21)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(store.sortAscending ? "Sort lowest first (ascending)" : "Sort highest first (descending)")
                    .accessibilityLabel(store.sortAscending ? "Sort lowest first" : "Sort highest first")
                }
            }

            Spacer(minLength: 0)
        }
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

    /// Launch at Login moved to Settings -> Startup, where there is room to
    /// explain what it does and to report a failure.  What is left here is
    /// only what is true of the numbers on screen.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
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
