import AppKit
import ApplicationServices
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case storage = "Storage"
    case network = "Network"
    case server = "Server"

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
    @State private var hasVisitedServer: Bool = false
    @State private var beakX: CGFloat = HogHunterPanel.panelWidth - 55
    @State private var panelInstanceId = UUID()
    private var directoryUsage: DirectoryUsageStore { store.directoryUsage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .frame(width: Self.contentWidth)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    meters
                    serverStrip
                    captions
                    controls
                    list
                    footer
                }
                .opacity(selectedTab == .activity ? 1 : 0)
                .allowsHitTesting(selectedTab == .activity)
                .accessibilityHidden(selectedTab != .activity)

                if hasVisitedStorage {
                    StorageView(runningBundleIds: { store.runningBundleIdsSnapshot() }, maintainStore: store.maintain, embeddedInPanel: true, isTabActive: selectedTab == .storage)
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

                if hasVisitedServer {
                    ServerStatusView(store: store.maintain.vpsStore)
                        .frame(width: Self.contentWidth, alignment: .topLeading)
                        .opacity(selectedTab == .server ? 1 : 0)
                        .allowsHitTesting(selectedTab == .server)
                        .accessibilityHidden(selectedTab != .server)
                }
            }
            // Every child is laid out at exactly the panel's inner width.  A
            // `VStack` sizes itself to its widest child's *ideal* width, and a
            // long unwrapped caption -- the attribution line especially -- is
            // wider than the panel, so without this the whole column is laid
            // out past the edge and clipped on both sides instead of wrapping.
            .frame(width: Self.contentWidth, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        .padding(.top, (store.dockedToMenuBar ? 8 : 0) + Self.inset)
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(
            DockedPanelShape(beakX: beakX, isDocked: store.dockedToMenuBar)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            DockedPanelShape(beakX: beakX, isDocked: store.dockedToMenuBar)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .background(MenuBarAnchorFinder { x in beakX = x })
        .preferredColorScheme(store.appearance.colorScheme)
        .task(id: selectedTab) {
            guard selectedTab == .activity else { return }
            while !Task.isCancelled {
                await directoryUsage.refreshIfNeeded()
                try? await Task.sleep(for: .seconds(directoryUsage.nextRefreshDelay))
            }
        }
        .onChange(of: selectedTab) { newTab in
            if newTab == .storage {
                hasVisitedStorage = true
            } else if newTab == .network {
                hasVisitedNetwork = true
            } else if newTab == .server {
                hasVisitedServer = true
            }
        }
        .onAppear {
            store.registerPanelVisible(panelInstanceId)
            // The server readings are the store's own business: it polls
            // whenever a host is configured, so the strip is never stale and
            // nothing depends on this view's lifetime.
            store.maintain.refresh()
            if selectedTab == .storage {
                hasVisitedStorage = true
            } else if selectedTab == .network {
                hasVisitedNetwork = true
            } else if selectedTab == .server {
                hasVisitedServer = true
            }
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

    /// A little bigger than it was: the server strip below the meters needs a
    /// line of its own, and four tab segments need room for their labels.
    static let panelWidth: CGFloat = 680
    static let panelHeight: CGFloat = 720
    static let inset: CGFloat = 14
    /// What is left of the panel once the inset is taken off both sides.
    static var contentWidth: CGFloat { panelWidth - inset * 2 }
    /// Fixed so the control row cannot resize itself when a segment changes.

    /// What the panel is showing, for screen readers.
    private var panelAccessibilityLabel: String {
        switch selectedTab {
        case .activity: return "Hog Hunter — top processes"
        case .storage: return "Hog Hunter — storage and disk cleaner"
        case .network: return "Hog Hunter — network activity"
        case .server: return "Hog Hunter — remote server status"
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

    // MARK: - Controls

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image("HogProfile")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 30)
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
            .accessibilityLabel(store.isStale ? "Hog Hunter, sampling is behind" : "Hog Hunter")

            Spacer()

            Picker("Tab", selection: $selectedTab) {
                Label("Activity", image: "HogProfile").tag(PanelTab.activity)
                Label("Storage", systemImage: "internaldrive").tag(PanelTab.storage)
                Label("Network", systemImage: "network").tag(PanelTab.network)
                Label("Server", systemImage: "server.rack").tag(PanelTab.server)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            Spacer()

            settingsMenu
        }
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

    /// The remote server's headline, always on the Activity tab.  Hidden when
    /// no host is configured: with no server there is nothing to report, and
    /// the Server tab says how to set one up.
    @ViewBuilder
    private var serverStrip: some View {
        if !store.maintain.vpsStore.configuredHost.isEmpty {
            VPSStatusStripView(store: store.maintain.vpsStore) {
                selectedTab = .server
                hasVisitedServer = true
            }
        }
    }

    // MARK: - Meters

    private var meters: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    cpuHistoryCard
                    Meter(
                        title: "Memory",
                        value: store.pulse.memoryPercent,
                        caption: store.memorySizeCaption,
                        severity: Severity.forPressure(store.pulse.pressure),
                        accessibilityDetail: store.memoryCaption
                    )
                }
                pillRow(thermalPills)
                diskCard
                MountedDriveUsageView()
                pillRow(memoryPills)
            }
            .frame(width: Self.contentWidth * 0.48)
            CodingDirectoriesView(store: directoryUsage)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

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

