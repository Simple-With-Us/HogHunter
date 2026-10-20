import AppKit
import ApplicationServices
import SwiftUI

@MainActor
private enum DashboardMountedDrives {
    static let shared = MountedDriveStore()
}

enum PanelTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"
    case storage = "Storage"
    case maintenance = "Maintenance"
    case network = "Network"

    var id: String { rawValue }
}

struct HogHunterPanel: View {
    @EnvironmentObject private var store: HogStore
    /// SwiftUI's own "open the Settings scene" action.  Sending
    /// `showSettingsWindow:` to `NSApp` by hand is silently dropped here and
    /// the gear button did nothing; this is the supported path.
    @Environment(\.openSettings) private var openSettings
    @State private var selectedTab: PanelTab = .overview
    @AppStorage("dashboardHostScope") private var hostScopeRawValue = HostScope.mac.rawValue
    @ObservedObject private var mountedDrives: MountedDriveStore
    @State private var driveReadAttempted = false
    @State private var pendingQuit: HogRow?
    @State private var hasVisitedStorage = false
    @State private var hasVisitedNetwork = false
    @State private var beakX: CGFloat = HogHunterPanel.panelWidth - 55
    @State private var panelInstanceId = UUID()
    private var directoryUsage: DirectoryUsageStore { store.directoryUsage }
    let isQuickView: Bool

    init(isQuickView: Bool = false, initialTab: PanelTab = .overview,
         mountedDrives: MountedDriveStore? = nil) {
        self.isQuickView = isQuickView
        _mountedDrives = ObservedObject(wrappedValue: mountedDrives ?? DashboardMountedDrives.shared)
        _selectedTab = State(initialValue: initialTab)
        _hasVisitedStorage = State(initialValue: initialTab == .storage)
        _hasVisitedNetwork = State(initialValue: initialTab == .network)
    }

    private enum HostScope: String, CaseIterable, Identifiable {
        case mac = "This Mac"
        case server = "Server"
        var id: String { rawValue }
    }

    private var hostScope: HostScope {
        get { HostScope(rawValue: hostScopeRawValue) ?? .mac }
        nonmutating set { hostScopeRawValue = newValue.rawValue }
    }

    private var dashboard: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Hog Hunter")
                    .font(.system(size: 17, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                ForEach(PanelTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tabSymbol(tab))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
            }
            .frame(width: 154)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selectedTab.rawValue)
                        .font(.system(size: 20, weight: .semibold))
                    if store.isStale {
                        Text("Sampling behind")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                    Picker("Host", selection: Binding(
                        get: { hostScope },
                        set: { hostScope = $0 }
                    )) {
                        ForEach(HostScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 215)
                    settingsMenu
                }
                Divider()
                ZStack(alignment: .topLeading) {
                    if selectedTab == .activity && hostScope == .mac {
                        activityContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if selectedTab == .maintenance && hostScope == .mac {
                        MaintainView(store: store.maintain, showHeader: true)
                    } else if (selectedTab != .network || hostScope != .mac)
                                && (selectedTab != .storage || hostScope != .mac) {
                        ScrollView {
                            dashboardPage
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    if hasVisitedStorage || selectedTab == .storage {
                        GeometryReader { stage in
                            VStack(alignment: .leading, spacing: 10) {
                                capacityCards
                                if externalDrives.count > 1 || timeMachineDrives.count > 1 {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            if externalDrives.count > 1 {
                                                driveDetails("External Drives", drives: externalDrives)
                                            }
                                            if timeMachineDrives.count > 1 {
                                                driveDetails("Time Machine Drives", drives: timeMachineDrives)
                                            }
                                        }
                                    }
                                    .frame(height: min(100, 24 + CGFloat(externalDrives.count + timeMachineDrives.count) * 16))
                                }
                                ScrollView { CodingDirectoriesView(store: directoryUsage) }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: min(260, max(200, stage.size.height * 0.4)))
                                StorageView(runningBundleIds: { store.runningBundleIdsSnapshot() },
                                            maintainStore: store.maintain, embeddedInPanel: true,
                                            isTabActive: selectedTab == .storage && hostScope == .mac,
                                            includesMaintenance: false, autoScanCleaner: false)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .opacity(selectedTab == .storage && hostScope == .mac ? 1 : 0)
                        .allowsHitTesting(selectedTab == .storage && hostScope == .mac)
                        .accessibilityHidden(selectedTab != .storage || hostScope != .mac)
                    }
                    if hasVisitedNetwork || selectedTab == .network {
                        // Kept mounted for the same reason as Storage: NetworkView
                        // owns a NetworkStore that scans with lsof, and rebuilding it
                        // on every tab switch would drop the snapshot, the sort order,
                        // and restart the scan.
                        NetworkView(bundleResolver: { pid in store.lookup(pid: pid) },
                                    bandwidth: store.bandwidth,
                                    cachedIconProvider: { store.cachedIcon(bundleIdentifier: $0) },
                                    embeddedInPanel: true,
                                    isTabActive: selectedTab == .network && hostScope == .mac)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .opacity(selectedTab == .network && hostScope == .mac ? 1 : 0)
                            .allowsHitTesting(selectedTab == .network && hostScope == .mac)
                            .accessibilityHidden(selectedTab != .network || hostScope != .mac)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: Self.dashboardMinimumWidth, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabSymbol(_ tab: PanelTab) -> String {
        switch tab {
        case .overview: return "house"
        case .activity: return "chart.bar.xaxis"
        case .storage: return "internaldrive"
        case .maintenance: return "wrench.and.screwdriver"
        case .network: return "network"
        }
    }

    @ViewBuilder
    private var dashboardPage: some View {
        if hostScope == .server {
            serverPage
        } else {
            switch selectedTab {
            case .overview: overview
            case .activity: activityContent
            case .storage: EmptyView()
            case .maintenance, .network: EmptyView()
            }
        }
    }

    private var serverPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedTab == .activity {
                Text("Remote per-process CPU and memory are unavailable.")
                    .foregroundStyle(.secondary)
            } else if selectedTab == .network {
                Text("Remote per-process connections and network rates are unavailable.")
                    .foregroundStyle(.secondary)
            } else if selectedTab == .maintenance {
                Text("Server tool status and significant directories")
                    .font(.headline)
            }
            ServerStatusView(store: store.maintain.vpsStore)
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                cpuHistoryCard.frame(width: 170)
                Meter(title: "Memory", value: store.pulse.memoryPercent,
                      caption: store.memorySizeCaption,
                      severity: Severity.forPressure(store.pulse.pressure),
                      accessibilityDetail: store.memoryCaption)
                    .frame(width: 170)
                Spacer(minLength: 0)
            }
            .frame(height: 75)
            pillRow(memoryPills + thermalPills)
            captions
            controls
            list.frame(maxHeight: .infinity)
            footer
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                cpuHistoryCard
                Meter(title: "Memory", value: store.pulse.memoryPercent,
                      caption: store.memorySizeCaption,
                      severity: Severity.forPressure(store.pulse.pressure),
                      accessibilityDetail: store.memoryCaption)
            }
            .frame(height: 94)
            pillRow(memoryPills + thermalPills)
            capacityCards
            HStack {
                Text("Top Activity").font(.headline)
                Spacer()
                Button("Open Activity") { selectedTab = .activity }
                    .buttonStyle(.link)
            }
            ForEach(Array(store.rows.prefix(6))) { row in
                HStack(spacing: 8) {
                    Text(row.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(HogFormat.cpu(row.cpuPercent, scale: store.cpuScale,
                                       coreCount: store.pulse.coreCount))
                    Text(HogFormat.memory(row.memoryBytes))
                }
                .font(.system(size: 11).monospacedDigit())
            }
            if store.rows.isEmpty {
                Text(store.hasBaseline ? "Nothing heavy right now." : "Measuring…")
                    .foregroundStyle(.secondary)
            }
            if !store.maintain.vpsStore.configuredHost.isEmpty {
                Text("Server").font(.headline)
                serverStrip
            }
            captions
        }
    }

    private var quickView: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Hog Hunter").font(.headline)
                Spacer()
                if store.isStale { Text("Sampling behind").foregroundStyle(.orange) }
                settingsMenu
            }
            HStack {
                Text("CPU").fontWeight(.medium)
                Spacer()
                Text(store.hasBaseline ? String(format: "%.0f%%", store.pulse.cpuPercent) : "—")
            }
            HStack {
                Text("Memory").fontWeight(.medium)
                Spacer()
                Text(store.memorySizeCaption)
            }
            HStack {
                Text("Internal Storage").fontWeight(.medium)
                Spacer()
                Text(store.diskSpaceCaption)
            }
            HStack {
                Text("External").fontWeight(.medium)
                Spacer(minLength: 6)
                Text(quickExternalText)
                    .foregroundStyle(quickExternalColor)
                    .lineLimit(1)
            }
            HStack {
                Text("Time Machine").fontWeight(.medium)
                Spacer(minLength: 6)
                Text(quickTimeMachineText)
                    .foregroundStyle(quickTimeMachineColor)
                    .lineLimit(1)
            }
            Divider()
            ForEach(Array(store.rows.prefix(3))) { row in
                HStack {
                    Text(row.name).lineLimit(1)
                    Spacer()
                    Text(HogFormat.cpu(row.cpuPercent, scale: store.cpuScale,
                                       coreCount: store.pulse.coreCount))
                }
            }
            if !store.maintain.vpsStore.configuredHost.isEmpty {
                Button {
                    hostScope = .server
                    DetachedWindowManager.shared.openDetachedWindow(store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server").fontWeight(.semibold)
                        if let snapshot = store.maintain.vpsStore.snapshot {
                            Text(snapshot.host).lineLimit(1)
                            HStack {
                                Text("CPU \(snapshot.headline?.cpuText ?? "—")")
                                Text("RAM \(snapshot.headline?.memoryText ?? "—")")
                                Spacer()
                                Text(snapshot.relativeTimeString())
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Text("No readings yet").foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Open Dashboard") {
                DetachedWindowManager.shared.openDetachedWindow(store: store)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 11))
        .padding(16)
        .frame(width: Self.panelWidth)
        .background(DockedPanelShape(beakX: beakX, isDocked: true)
            .fill(Color(nsColor: .windowBackgroundColor)))
        .background(MenuBarAnchorFinder { x in beakX = x })
    }

    private var capacityCards: some View {
        HStack(alignment: .top, spacing: 8) {
            capacityCard("Internal", value: store.diskSpaceCaption,
                         percent: store.diskSpace.map { $0.usedFraction * 100 })
            capacityCard("External", value: externalCapacityText,
                         percent: externalDrives.count == 1 ? externalDrives[0].usedPercent : nil)
            capacityCard("Time Machine", value: timeMachineCapacityText,
                         percent: timeMachineDrives.count == 1 ? timeMachineDrive?.usedPercent : nil)
        }
    }

    private var timeMachineDrives: [MountedDriveUsage] {
        mountedDrives.rows.filter { $0.name.localizedCaseInsensitiveContains("Time Machine") }
    }

    private var timeMachineDrive: MountedDriveUsage? {
        timeMachineDrives.first
    }

    private var externalDrives: [MountedDriveUsage] {
        // Every mounted Time Machine destination belongs in the Time Machine card, not
        // the External one, so match on the name rather than the single selected id.
        mountedDrives.rows.filter { !$0.name.localizedCaseInsensitiveContains("Time Machine") }
    }

    private var externalCapacityText: String {
        if externalDrives.count > 1 {
            return selectedTab == .storage ? "\(externalDrives.count) drives · details below"
                : "\(externalDrives.count) drives · see Storage"
        }
        return externalDrives.first.map(capacityText) ?? unrecognizedDriveText
    }

    private var timeMachineCapacityText: String {
        if timeMachineDrives.count > 1 {
            return selectedTab == .storage ? "\(timeMachineDrives.count) destinations · details below"
                : "\(timeMachineDrives.count) destinations · see Storage"
        }
        return timeMachineDrive.map(capacityText) ?? unrecognizedDriveText
    }

    private var unrecognizedDriveText: String {
        (!driveReadAttempted || mountedDrives.isRefreshing) && mountedDrives.rows.isEmpty
            ? "Reading…" : "Not identified"
    }

    private var quickExternalText: String {
        if externalDrives.count > 1 {
            let highest = externalDrives.compactMap(\.usedPercent).max()
            return highest.map { "\(externalDrives.count) drives · up to \(Int($0.rounded()))% used" }
                ?? "\(externalDrives.count) drives · see Storage"
        }
        return externalDrives.first.map(quickDriveText) ?? unrecognizedDriveText
    }

    private var quickExternalColor: Color {
        guard let highest = externalDrives.compactMap(\.usedPercent).max() else { return .secondary }
        return Severity.forDisk(highest / 100).color
    }

    private var quickTimeMachineText: String {
        if timeMachineDrives.count > 1 {
            let highest = timeMachineDrives.compactMap(\.usedPercent).max()
            return highest.map { "\(timeMachineDrives.count) backups · up to \(Int($0.rounded()))% used" }
                ?? "\(timeMachineDrives.count) backups · see Storage"
        }
        return timeMachineDrive.map(quickDriveText) ?? unrecognizedDriveText
    }

    private var quickTimeMachineColor: Color {
        guard let highest = timeMachineDrives.compactMap(\.usedPercent).max() else { return .secondary }
        return Severity.forDisk(highest / 100).color
    }

    private func driveDetails(_ title: String, drives: [MountedDriveUsage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            ForEach(drives) { drive in
                HStack {
                    Text(drive.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(capacityAmountsText(drive)).lineLimit(1)
                }
                .font(.system(size: 10))
            }
        }
    }

    private func quickDriveText(_ drive: MountedDriveUsage) -> String {
        guard let percent = drive.usedPercent, let available = drive.availableBytes else { return "Unavailable" }
        return "\(Int(percent.rounded()))% used · \(HogFormat.memory(UInt64(available))) free"
    }

    private func capacityText(_ drive: MountedDriveUsage) -> String {
        "\(drive.name) · \(capacityAmountsText(drive))"
    }

    private func capacityAmountsText(_ drive: MountedDriveUsage) -> String {
        guard let available = drive.availableBytes, let total = drive.totalBytes else { return "Unavailable" }
        return "\(HogFormat.memory(UInt64(available))) free of \(HogFormat.memory(UInt64(total)))"
    }

    private func capacityCard(_ title: String, value: String, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            if let percent { ProgressView(value: percent, total: 100) }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        Group {
            if isQuickView { quickView }
            else { dashboard }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .task(id: selectedTab.rawValue + hostScope.rawValue) {
            while !Task.isCancelled {
                let storageForeground = !isQuickView && selectedTab == .storage && hostScope == .mac
                await directoryUsage.refreshIfNeeded(background: !storageForeground)
                // Background pauses leave `nextAttempt` in the past, so the raw delay
                // collapses to a second and this loop spins.  Match the idle floor.
                let delay = storageForeground ? directoryUsage.nextRefreshDelay
                                              : max(15, directoryUsage.nextRefreshDelay)
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                await mountedDrives.refresh()
                driveReadAttempted = true
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
            }
        }
        .onChange(of: selectedTab) { tab in
            if tab == .storage { hasVisitedStorage = true }
            if tab == .network { hasVisitedNetwork = true }
        }
        .onAppear {
            store.registerPanelVisible(panelInstanceId)
            // The server readings are the store's own business: it polls
            // whenever a host is configured, so the strip is never stale and
            // nothing depends on this view's lifetime.
            store.maintain.refresh()
        }
        .onDisappear {
            store.unregisterPanelVisible(panelInstanceId)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelAccessibilityLabel)
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

    /// The menu-bar quick view has a fixed width and a content-fitting height.
    static let panelWidth: CGFloat = 360
    /// The maximum expected quick-view height, including an optional server summary.
    static let panelHeight: CGFloat = 410
    static let dashboardWidth: CGFloat = 900
    static let dashboardHeight: CGFloat = 700
    static let dashboardMinimumWidth: CGFloat = 860
    static let inset: CGFloat = 14
    /// What is left of the panel once the inset is taken off both sides.
    static var contentWidth: CGFloat { panelWidth - inset * 2 }

    /// What the panel is showing, for screen readers.
    private var panelAccessibilityLabel: String {
        if hostScope == .server {
            switch selectedTab {
            case .overview: return "Hog Hunter — server overview"
            case .activity, .network: return "Hog Hunter — server status"
            case .storage: return "Hog Hunter — server storage"
            case .maintenance: return "Hog Hunter — server maintenance"
            }
        }
        switch selectedTab {
        case .overview: return "Hog Hunter — overview"
        case .activity: return "Hog Hunter — top processes"
        case .storage: return "Hog Hunter — storage and disk cleaner"
        case .maintenance: return "Hog Hunter — maintenance"
        case .network: return "Hog Hunter — network activity"
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

    /// Settings dropdown menu using the standard gear icon.  Holds Settings,
    /// Activity Monitor, Launch at Login, and Quit.
    private var settingsMenu: some View {
        Menu {
            Button("Settings…") {
                openSettingsWindow()
            }
            Button("Activity Monitor") {
                HogActions.openActivityMonitor()
            }
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { store.launchesAtLogin },
                set: { _ in store.toggleLoginItem() }
            ))
            Toggle("Attach to Menu Bar", isOn: Binding(
                get: { store.dockedToMenuBar },
                set: { newValue in
                    store.dockedToMenuBar = newValue
                    if !newValue {
                        DetachedWindowManager.shared.openDetachedWindow(store: store)
                    } else {
                        DetachedWindowManager.shared.closeDetachedWindow()
                    }
                }
            ))
            Divider()
            Button("Quit Hog Hunter") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and options")
        .accessibilityLabel("Settings and options")
    }

    private func openSettingsWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        // openSettings() from Environment sometimes fails for accessory apps.
        // sendAction is the robust fallback.
        NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, from: nil)
        openSettings()
        // The scene builds its window asynchronously, so the "already
        // open? come forward" pass has to be retried, not run once.
        HogActions.scheduleFrontSettingsWindow()
    }

    // MARK: - Server

    /// The remote server's headline, on Overview and the quick view.  Hidden when
    /// no host is configured: with no server there is nothing to report, and
    /// the Server tab says how to set one up.
    @ViewBuilder
    private var serverStrip: some View {
        if !store.maintain.vpsStore.configuredHost.isEmpty {
            VPSStatusStripView(store: store.maintain.vpsStore) {
                hostScope = .server
                selectedTab = .overview
                if isQuickView { DetachedWindowManager.shared.openDetachedWindow(store: store) }
            }
        }
    }

    // MARK: - Meters

    private var cpuHistoryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CPU").fontWeight(.semibold)
                Spacer()
                Text(store.hasBaseline ? String(format: "%.0f%%", store.pulse.cpuPercent) : "—")
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            CpuHistoryBarsView(history: store.cpuMinuteHistory)
            Text("30 min")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
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
            let severity: Severity = pct <= 20 ? .hot : (pct <= 40 ? .elevated : .calm)
            let icon = isCharging ? "⚡ " : ""
            let text = "\(icon)\(pct)% Battery"
            out.append(Pill(
                text: text,
                severity: severity,
                help: isCharging ? "Charging (\(pct)%)." : isBattery
                    ? "Running on battery (\(pct)%).  High CPU processes increase discharge rate."
                    : "Battery at \(pct)%."
            ))
        }
        return out
    }

    /// Thermal state sits under CPU, not Memory.  `ProcessInfo.thermalState` is
    /// a single machine-wide reading of the SoC die, so it has nothing to do
    /// with RAM -- what it predicts is clock throttling, which is what the CPU
    /// meter above it is measuring.
    private var thermalPills: [Pill] {
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

    /// The control row: three labeled groups (TIME / SHOW / SORT) distributed
    /// evenly across the row, with the sort-direction arrow pinned to the
    /// far right.
    ///
    /// Each group uses `SegmentedToggleGroup` instead of a stock segmented
    /// `Picker`.  A stock segmented picker pads every segment to the widest
    /// one, which makes short labels like "Now" feel hollow inside the row
    /// and wastes the room "Past 24 Hours" needs.  The custom group gives
    /// every segment the same L/R internal padding (8 pt) so the spacing
    /// feels even, lets "Now" stay narrower than its neighbours, and lets
    /// the three groups sit on equal ground across the row.
    private var controls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TIME")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                SegmentedToggleGroup(
                    options: TimeWindow.allCases,
                    label: { Text($0.rawValue) },
                    selection: $store.window
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SHOW")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                SegmentedToggleGroup(
                    options: HogGrouping.allCases,
                    label: { Text($0.rawValue) },
                    selection: $store.grouping
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SORT")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                SegmentedToggleGroup(
                    options: HogSort.allCases,
                    label: { Text($0.rawValue) },
                    selection: $store.sort
                )
            }

            // Even stretch across the row, then anchor the sort-direction
            // arrow on the far right.
            Spacer(minLength: 0)
            sortDirectionButton
                .padding(.bottom, 4)
        }
    }

    /// Sort-direction toggle, pinned to the right edge of the controls row.
    /// Lives at the same baseline as the toggle groups so the row reads as
    /// one tidy band.
    private var sortDirectionButton: some View {
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
                        store: store,
                        sort: store.sort
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

    /// Bottom of the pop up window: attribution/coverage note left-aligned and
    /// CPU core relation right-aligned on the same line to save vertical space.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.coverageNote)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("CPU % relative to all \(max(1, store.pulse.coreCount)) cores")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

/// The outline of the Hog Hunter panel.  When docked to the menu bar, the top
/// edge features a smooth curved triangular beak (anchor notch) pointing up to
/// touch the menu bar item, with the shoulders inset by 8 pt.  When detached,
/// it draws a standard rounded rectangle.
struct DockedPanelShape: Shape {
    var beakX: CGFloat
    var isDocked: Bool
    var cornerRadius: CGFloat = 10
    var beakHeight: CGFloat = 8
    var beakHalfWidth: CGFloat = 14

    var animatableData: CGFloat {
        get { beakX }
        set { beakX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard isDocked else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius)
        }
        var path = Path()
        let minX = rect.minX + cornerRadius + beakHalfWidth + 4
        let maxX = rect.maxX - cornerRadius - beakHalfWidth - 4
        let bx = min(max(beakX, minX), maxX)
        let topY = rect.minY + beakHeight

        // Top edge left segment: starts at corner
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: topY))

        // Line to left base of beak
        path.addLine(to: CGPoint(x: bx - beakHalfWidth, y: topY))

        // Smooth curve up to rounded apex of beak
        path.addCurve(
            to: CGPoint(x: bx, y: rect.minY),
            control1: CGPoint(x: bx - beakHalfWidth * 0.5, y: topY),
            control2: CGPoint(x: bx - beakHalfWidth * 0.2, y: rect.minY)
        )

        // Smooth curve down from apex to right base of beak
        path.addCurve(
            to: CGPoint(x: bx + beakHalfWidth, y: topY),
            control1: CGPoint(x: bx + beakHalfWidth * 0.2, y: rect.minY),
            control2: CGPoint(x: bx + beakHalfWidth * 0.5, y: topY)
        )

        // Line to top right corner
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: topY))

        // Top right rounded corner
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: topY),
                    tangent2End: CGPoint(x: rect.maxX, y: topY + cornerRadius),
                    radius: cornerRadius)

        // Right edge
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))

        // Bottom right rounded corner
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
                    radius: cornerRadius)

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))

        // Bottom left rounded corner
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
                    radius: cornerRadius)

        // Left edge
        path.addLine(to: CGPoint(x: rect.minX, y: topY + cornerRadius))

        // Top left rounded corner
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: topY),
                    tangent2End: CGPoint(x: rect.minX + cornerRadius, y: topY),
                    radius: cornerRadius)

        path.closeSubpath()
        return path
    }
}

/// Locates the horizontal coordinate of the menu bar status item relative to the
/// window frame so the anchor beak points directly at Hog Hunter's logo and % in the menu bar.
struct MenuBarAnchorFinder: NSViewRepresentable {
    var onPosition: (CGFloat) -> Void

    func makeNSView(context: Context) -> MenuBarAnchorView {
        let view = MenuBarAnchorView()
        view.onPosition = onPosition
        return view
    }

    func updateNSView(_ nsView: MenuBarAnchorView, context: Context) {
        nsView.onPosition = onPosition
    }
}

final class MenuBarAnchorView: NSView {
    var onPosition: ((CGFloat) -> Void)?
    private var moveObserver: NSObjectProtocol?
    private var lastReportedX: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        guard let window = self.window else { return }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.resolveAnchor()
        }

        resolveAnchor()
        DispatchQueue.main.async { [weak self] in
            self?.resolveAnchor()
        }
    }

    deinit {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func resolveAnchor() {
        guard let window = self.window, window.frame.width > 0 else { return }
        let winX = window.frame.origin.x
        let winW = window.frame.width

        let targetX: CGFloat
        if let itemMidX = Self.findStatusItemMidX() {
            let relX = itemMidX - winX
            // Verify relX is plausibly within or near the window
            if relX >= 20 && relX <= winW - 20 {
                targetX = relX
            } else {
                targetX = winW - 55
            }
        } else if let statusWindow = NSApp.windows.first(where: {
            $0.className.contains("StatusBar") && $0.frame.width < winW && $0.frame.origin.x > 0
        }) {
            let relX = statusWindow.frame.midX - winX
            if relX >= 20 && relX <= winW - 20 {
                targetX = relX
            } else {
                targetX = winW - 55
            }
        } else {
            // Default anchor position: Hog Hunter menu bar item sits on the right side
            // of the 620pt panel, ~55pt from the right edge.
            targetX = winW - 55
        }

        let minSafeX: CGFloat = 28
        let maxSafeX: CGFloat = winW - 28
        let clampedX = min(max(targetX, minSafeX), maxSafeX)

        if let last = lastReportedX, abs(last - clampedX) < 0.5 { return }
        lastReportedX = clampedX
        onPosition?(clampedX)
    }

    static func findStatusItemMidX() -> CGFloat? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appAX = AXUIElementCreateApplication(pid)

        guard let extrasElement = axElement(appAX, attribute: "AXExtrasMenuBar") else {
            return nil
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let rawChildren = childrenRef as? [AnyObject] else {
            return nil
        }
        // The array bridge checks only that this is an array; each element's
        // type is checked here.
        let children = rawChildren
            .filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
            .map { $0 as! AXUIElement }
        guard !children.isEmpty else { return nil }

        for item in children {
            var titleRef: CFTypeRef?
            var title: String?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
               let str = titleRef as? String {
                title = str
            }

            if children.count == 1 || title == "Hog Hunter" || (title?.contains("Hog") ?? false),
               let midX = axMidX(of: item) {
                return midX
            }
        }

        if let first = children.first {
            return axMidX(of: first)
        }

        return nil
    }

    /// `attribute` of `element` when it really is an `AXUIElement`.  A cast
    /// from `CFTypeRef` to a CoreFoundation type, `as!` or `as?`, is not
    /// checked at runtime, so the type ID is checked first and anything else
    /// is nil instead of undefined behaviour.
    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// The horizontal middle of `item`, or nil unless both its position and
    /// size come back as `AXValue`s of the right kind that unpack.
    private static func axMidX(of item: AXUIElement) -> CGFloat? {
        var point = CGPoint.zero
        var size = CGSize.zero
        guard let pos = axValue(item, attribute: kAXPositionAttribute, type: .cgPoint),
              AXValueGetValue(pos, .cgPoint, &point),
              let sz = axValue(item, attribute: kAXSizeAttribute, type: .cgSize),
              AXValueGetValue(sz, .cgSize, &size),
              size.width > 0 else {
            return nil
        }
        return point.x + size.width / 2.0
    }

    /// `attribute` of `item` when it really is an `AXValue` holding `type`.
    private static func axValue(_ item: AXUIElement, attribute: String, type: AXValueType) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }
}

