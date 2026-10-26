import AppKit
import ApplicationServices
import SwiftUI

@MainActor
private enum DashboardMountedDrives {
    /// The same store the companion snapshot reads, so the panel and the
    /// phone always agree about what is mounted.
    static let shared = MountedDriveStore.shared
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
    enum StorageSubTab: String, CaseIterable, Identifiable {
        case apps = "Installed Apps"
        case clean = "Disk Cleaner"
        case drives = "Drives & Folders"

        var id: String { rawValue }
    }

    @ObservedObject private var mountedDrives: MountedDriveStore
    @State private var driveReadAttempted = false
    @State private var pendingQuit: HogRow?
    @State private var hasVisitedStorage = false
    @State private var hasVisitedNetwork = false
    @State private var storageSubTab: StorageSubTab = .apps
    private var storageViewTabBinding: Binding<StorageTab> {
        Binding(
            get: {
                storageSubTab == .clean ? .diskCleaner : .appStorage
            },
            set: { newTab in
                if newTab == .diskCleaner {
                    storageSubTab = .clean
                } else if newTab == .appStorage {
                    storageSubTab = .apps
                }
            }
        )
    }
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

    enum HostScope: String, CaseIterable, Identifiable {
        case mac = "This Mac"
        case server = "Server"
        var id: String { rawValue }
    }

    /// Which part of the server snapshot a section shows.  Every section has
    /// an answer, and no two sections answer with the same readings, so a
    /// section can never look like the one before it.  Network is the one
    /// section the snapshot cannot answer, and it says so instead.
    static func serverSection(for tab: PanelTab) -> VPSResourceSection? {
        switch tab {
        case .overview: return .all
        case .activity: return .activity
        case .storage: return .storage
        case .maintenance: return .maintenance
        case .network: return nil
        }
    }

    private var hostScope: HostScope {
        get { HostScope(rawValue: hostScopeRawValue) ?? .mac }
        nonmutating set { hostScopeRawValue = newValue.rawValue }
    }

    private var dashboard: some View {
        HStack(spacing: 0) {
            sidebar

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(pageTitle)
                        .font(.system(size: 20, weight: .semibold))
                    if store.isStale {
                        Text("Sampling behind")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
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
                        VStack(alignment: .leading, spacing: 12) {
                            capacityCards

                            Picker("Storage Section", selection: $storageSubTab) {
                                ForEach(StorageSubTab.allCases) { tab in
                                    Text(tab.rawValue).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            // A clean in flight lives in the Disk Cleaner view's
                            // store, so switching sub-tabs mid-clean would destroy
                            // it and cancel the clean while the companion snapshot
                            // still reports cleaning.  The picker waits instead.
                            .disabled(store.activeCleanProgress?.isCleaning == true)

                            ZStack {
                                StorageView(runningBundleIds: { store.runningBundleIdsSnapshot() },
                                            maintainStore: store.maintain, embeddedInPanel: true,
                                            isTabActive: selectedTab == .storage && hostScope == .mac && storageSubTab != .drives,
                                            externalTab: storageViewTabBinding,
                                            initialTab: .appStorage,
                                            includesMaintenance: false, autoScanCleaner: true,
                                            showModePicker: false)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .opacity(storageSubTab == .drives ? 0 : 1)
                                    .allowsHitTesting(storageSubTab != .drives)
                                    .accessibilityHidden(storageSubTab == .drives)

                                if storageSubTab == .drives {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 14) {
                                            mountedDriveList
                                            Divider()
                                            CodingDirectoriesView(store: directoryUsage)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The left rail: which host the sections below are about, the sections
    /// themselves, and Settings at the bottom.
    ///
    /// The host used to be a picker in the window header, above the content.
    /// From there it read like a setting rather than a destination, and the
    /// section list underneath kept its Mac meaning while the server was on,
    /// so choosing a section looked like it did nothing.  The host now sits
    /// at the top of the same rail as the sections it governs, every section
    /// renders for the host that is selected, and Settings is a rail item
    /// instead of a gear in the header.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            // No wordmark here: the window's title bar already says "Hog
            // Hunter", and the rail starts with the host it is about.
            scopeTabs
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 8)
            ForEach(PanelTab.allCases) { tab in
                sectionButton(tab)
            }
            Spacer(minLength: 0)
            Button {
                openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Open Hog Hunter Settings")
            .accessibilityLabel("Settings")
        }
        .frame(width: 154)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// "This Mac" and "Server" as a pair of tabs at the top of the rail.
    private var scopeTabs: some View {
        HStack(spacing: 4) {
            ForEach(HostScope.allCases) { scope in
                Button {
                    hostScope = scope
                } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 11, weight: hostScope == scope ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(hostScope == scope ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(hostScope == scope ? [.isSelected] : [])
                .accessibilityLabel(scope.rawValue)
            }
        }
    }

    private func sectionButton(_ tab: PanelTab) -> some View {
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

    /// The header names the section, and says which host it is about when the
    /// server is the one being looked at.
    private var pageTitle: String {
        hostScope == .server ? "Server \(selectedTab.rawValue)" : selectedTab.rawValue
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

    /// The server's answer for the selected section.
    ///
    /// The snapshot carries the server's CPU, memory, disks, app databases,
    /// directories and tool states, so each section shows the part of it that
    /// belongs there.  The two sections the snapshot cannot answer say so
    /// plainly instead of showing the same card every other section shows.
    private var serverPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch selectedTab {
            case .activity:
                // The card below carries the server's CPU and memory, the
                // processes it is running and the workloads they belong to.
                Text("The server's busiest processes, and the Coolify workloads they belong to.")
                    .foregroundStyle(.secondary)
            case .network:
                Text("Remote per-process connections and network rates are unavailable.")
                    .foregroundStyle(.secondary)
            case .storage:
                Text("Server disks, app databases and largest directories")
                    .font(.headline)
            case .maintenance:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Status")
                        .font(.headline)
                    remoteMaintenanceCard
                }
            case .overview:
                EmptyView()
            }
            if let section = Self.serverSection(for: selectedTab) {
                ServerStatusView(store: store.maintain.vpsStore, section: section)
            }
        }
    }

    /// The one action the server scope can take.
    ///
    /// The server scope used to be display-only: the owner could read the
    /// server's CPU, memory and disks but could not act on them.  The remote
    /// maintenance step is the step that belongs to the server, and it is the
    /// same step the Mac's Maintenance tab runs, against the same configured
    /// host.
    private var remoteMaintenanceCard: some View {
        RemoteMaintenanceCard(maintain: store.maintain)
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
                    // The memory meter keeps its size; the CPU graph takes
                    // the rest of the width, because a graph squeezed into
                    // half a card is not worth having.
                    .frame(width: 260)
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
            captions
            // The server is a separate thing from this Mac's readings, so it
            // sits at the bottom of the window with a rule above it rather
            // than tucked under Top Activity as if it were one more row.
            if !store.maintain.vpsStore.configuredHost.isEmpty {
                Divider()
                    .padding(.top, 4)
                Text("Server").font(.headline)
                serverStrip
            }
        }
    }

    /// True while the pointer is over the activity list, which opens it up.
    @State private var activityHovered = false

    /// Consolidated drop-down menu bar window.  Combines system alerts/flagged issues,
    /// graphical CPU meters, RAM usage, storage of all kinds (Mac internal/external and
    /// Server root / fleet-extra), and active hogs in a single high-density view.
    private var quickView: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header
            HStack(spacing: 6) {
                Image("HogProfile")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 14)
                Text("Hog Hunter")
                    .font(.system(size: 13, weight: .semibold))
                if store.isStale {
                    Text("Sampling behind")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                settingsMenu
            }

            // Area for prioritized flagged issues / system alerts
            flaggedIssuesSection

            // Scrollable consolidated telemetry
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    cpuSection
                    ramSection
                    storageSection
                    activitySection
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 520)

            Divider()

            // Footer
            HStack {
                Button("Open Dashboard") {
                    DetachedWindowManager.shared.openDetachedWindow(store: store)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button("Clean…") {
                    DetachedWindowManager.shared.openDetachedWindow(store: store)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 18)
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(
            DockedPanelShape(beakX: beakX, isDocked: true)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            DockedPanelShape(beakX: beakX, isDocked: true)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        )
        .background(MenuBarAnchorFinder { x in beakX = x })
    }

    // MARK: - Flagged Issues Section

    private var flaggedIssuesSection: some View {
        let issues = store.flaggedIssues
        return Group {
            if issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text("All Systems Calm")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0 alerts")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.green.opacity(0.25), lineWidth: 1)
                )
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: issues.first?.priority.systemImage ?? "exclamationmark.triangle.fill")
                            .foregroundStyle(issues.first?.priority.color ?? .orange)
                            .font(.system(size: 11))
                        Text("Flagged Issues")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text("\(issues.count) \(issues.count == 1 ? "alert" : "alerts")")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Show top 2 to 5 prioritized issues
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(issues.prefix(3))) { issue in
                            flaggedIssueRow(issue)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke((issues.first?.priority.color ?? Color.secondary).opacity(0.35), lineWidth: 1)
                )
            }
        }
    }

    private func flaggedIssueRow(_ issue: FlaggedIssue) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(issue.priority.badgeText)
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(issue.priority.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(issue.priority.color)

            HStack(spacing: 2) {
                Image(systemName: issue.host.systemImage)
                    .font(.system(size: 8))
                Text(issue.host.rawValue)
                    .font(.system(size: 8.5, weight: .medium))
            }
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(issue.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                Text(issue.message)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if let action = issue.actionTitle {
                Button(action) {
                    handleIssueAction(issue)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 8.5))
            }
        }
    }

    private func handleIssueAction(_ issue: FlaggedIssue) {
        switch issue.actionTitle {
        case "Clean":
            DetachedWindowManager.shared.openDetachedWindow(store: store)
        case "Retry":
            store.maintain.vpsStore.fetch(force: true)
        case "Quit":
            if let hog = store.rows.first(where: { "mac.cpu.hog.\($0.id)" == issue.id }) {
                pendingQuit = hog
            }
        default:
            DetachedWindowManager.shared.openDetachedWindow(store: store)
        }
    }

    // MARK: - CPU Section (Mac & Server side by side)

    /// The two machines, side by side, each with its own graph.
    ///
    /// They used to stack, and the Mac's graph was a sparkline pinned to 36
    /// points inside a full-width row, so it read as a small drawing in a
    /// large space.  Now each machine has half the width and a bar graph
    /// that fills it, and the two can be read against each other.
    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text("CPU")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
            }

            HStack(alignment: .top, spacing: 6) {
                macCPUColumn
                if !store.maintain.vpsStore.configuredHost.isEmpty {
                    serverCPUColumn
                }
            }

            if let topHog = store.rows.first {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("Top: \(topHog.name) (\(HogFormat.cpu(topHog.cpuPercent, scale: store.cpuScale, coreCount: store.pulse.coreCount)))")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var macCPUColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("Mac")
                    .font(.system(size: 9.5, weight: .medium))
                Spacer(minLength: 2)
                Text(store.hasBaseline ? String(format: "%.0f%%", store.pulse.cpuPercent) : "—")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Severity.forMachineCpu(store.pulse.cpuPercent).color)
            }

            CpuHistoryBarsView(history: store.cpuMinuteHistory, height: 26)

            Text("\(store.pulse.coreCount) cores · \(HogFormat.percent(store.pulse.cpuPercent / 100)) total")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity)
    }

    private var serverCPUColumn: some View {
        let cpu = store.maintain.vpsStore.snapshot?.cpu
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(store.maintain.vpsStore.snapshot?.host ?? store.maintain.vpsStore.configuredHost)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let cpu {
                    Text(String(format: "%.0f%%", cpu.pct))
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(cpu.severity.color)
                } else {
                    Text("—").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }

            CpuHistoryBarsView(history: store.maintain.vpsStore.cpuHistory, height: 26)

            if let cpu {
                Text("\(cpu.cores) cores · Load \(String(format: "%.2f", cpu.load1))")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(store.maintain.vpsStore.isLoading ? "Connecting to server…" : "No reading yet")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity)
    }

    // MARK: - RAM Usage Section (Mac & Server)

    private var ramSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text("RAM Usage")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
            }

            // Mac RAM
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("Mac")
                        .font(.system(size: 9.5, weight: .medium))
                    Spacer()
                    Text(store.memorySizeCaption)
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    Text(store.pulse.pressure.label)
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Severity.forPressure(store.pulse.pressure).color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(Severity.forPressure(store.pulse.pressure).color)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Severity.forPressure(store.pulse.pressure).color)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(store.pulse.memoryPercent / 100.0))))
                    }
                }
                .frame(height: 4)

                if store.pulse.swapUsedBytes > 0 {
                    HStack {
                        Text("Swap: \(HogFormat.memory(store.pulse.swapUsedBytes))")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            // Server RAM (if configured)
            if !store.maintain.vpsStore.configuredHost.isEmpty,
               let mem = store.maintain.vpsStore.snapshot?.memory {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("Server")
                            .font(.system(size: 9.5, weight: .medium))
                        Spacer()
                        Text(String(format: "%.0f%% (%@ / %@)", mem.usedPercentage, HogFormat.memory(UInt64(max(0, mem.usedBytes))), HogFormat.memory(UInt64(max(0, mem.totalBytes)))))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(mem.severity.color)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(mem.severity.color)
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(mem.usedPercentage / 100.0))))
                        }
                    }
                    .frame(height: 4)

                    if let swap = store.maintain.vpsStore.snapshot?.swap {
                        HStack {
                            Text("Swap: \(String(format: "%.0f%%", swap.usedPercentage)) (\(HogFormat.memory(UInt64(max(0, swap.usedBytes)))))")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Storage Section (Mac Internal/External & Server Root/Fleet-Extra)

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text("Storage (All Volumes)")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                // Mac Internal Boot Drive
                if let disk = store.diskSpace {
                    quickStorageRow(
                        name: "Mac (Internal /)",
                        icon: "laptopcomputer",
                        freeBytes: disk.freeBytes,
                        usedFraction: disk.usedFraction
                    )
                }

                // Mac External Drives
                ForEach(externalDrives.prefix(2)) { drive in
                    quickStorageRow(
                        name: "Mac (\(drive.name))",
                        icon: "externaldrive",
                        freeBytes: UInt64(max(0, drive.availableBytes ?? 0)),
                        usedFraction: (drive.usedPercent ?? 0) / 100.0
                    )
                }

                // Server Root /
                if let root = store.maintain.vpsStore.snapshot?.rootDevice {
                    quickStorageRow(
                        name: "Server (Root /)",
                        icon: "server.rack",
                        freeBytes: UInt64(max(0, root.freeBytes)),
                        usedFraction: root.usedFraction
                    )
                }

                // Server Fleet Extra /mnt/fleet-extra
                if let extra = store.maintain.vpsStore.snapshot?.fleetExtraDevice {
                    quickStorageRow(
                        name: "Server (/mnt/fleet-extra)",
                        icon: "externaldrive.connected.to.line.below",
                        freeBytes: UInt64(max(0, extra.freeBytes)),
                        usedFraction: extra.usedFraction
                    )
                }
            }
            .padding(5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func quickStorageRow(name: String, icon: String, freeBytes: UInt64, usedFraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let fraction = usedFraction {
                    Text("\(HogFormat.memory(freeBytes)) free (\(Int(fraction * 100))%)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Severity.forDisk(fraction).color)
                } else {
                    Text("\(HogFormat.memory(freeBytes)) free")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    if let fraction = usedFraction {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Severity.forDisk(fraction).color)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(fraction))))
                    }
                }
            }
            .frame(height: 3.5)
        }
    }

    // MARK: - Activity Section

    /// Which machine's activity the drop-down lists.
    enum ActivityScope: String, CaseIterable, Identifiable {
        case mac = "This Mac"
        case server = "Server"

        var id: String { rawValue }
    }

    @State private var activityScope: ActivityScope = .mac

    /// The server's processes, as its own collector saw them.
    private var serverProcesses: [VPSProcess] {
        store.maintain.vpsStore.snapshot?.processes ?? []
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Top Activity")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Text(activityScope == .mac
                     ? "\(store.rows.count) processes"
                     : "\(serverProcesses.count) processes")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                if activityScope == .mac {
                    ForEach(Array(store.rows.prefix(activityRowLimit))) { row in
                        HStack(spacing: 6) {
                            Text(row.name)
                                .font(.system(size: 9.5, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(HogFormat.cpu(row.cpuPercent, scale: store.cpuScale, coreCount: store.pulse.coreCount))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(row.cpuPercent >= 100 ? .orange : .primary)
                            Text(HogFormat.memory(row.memoryBytes))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if store.rows.isEmpty {
                        Text(store.hasBaseline ? "Nothing heavy right now." : "Measuring…")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(serverProcesses.prefix(activityRowLimit)) { process in
                        HStack(spacing: 6) {
                            Text(process.name)
                                .font(.system(size: 9.5, weight: .medium))
                                .lineLimit(1)
                            if let container = process.container, !container.isEmpty {
                                Text(container)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(String(format: "%.0f%%", process.cpuPercent))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(process.cpuPercent >= 100 ? .orange : .primary)
                            Text(process.memoryBytes.map { HogFormat.memory(UInt64(max(0, $0))) } ?? "—")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if serverProcesses.isEmpty {
                        Text(store.maintain.vpsStore.configuredHost.isEmpty
                             ? "No server configured."
                             : "No processes in the server's latest reading.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) { activityHovered = inside }
            }

            // The toggle sits at the bottom of the list it belongs to: the same
            // reading, taken from the other machine.
            HStack(spacing: 4) {
                ForEach(ActivityScope.allCases) { scope in
                    Button {
                        activityScope = scope
                    } label: {
                        Text(scope.rawValue)
                            .font(.system(size: 9, weight: activityScope == scope ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(activityScope == scope ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(activityScope == scope ? [.isSelected] : [])
                    .accessibilityLabel(scope.rawValue)
                }
            }
            .padding(2)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var activityRowLimit: Int {
        activityHovered ? 6 : 3
    }

    /// One wording for every volume: how much of it is spoken for, and how
    /// much room is left.  The internal disk used to say "17.0 of 460.4 GB
    /// free" while the external ones said "69% used · 145.4 GB free", which
    /// read as two different facts about two different things.
    private var quickInternalText: String {
        // The reading is pending until the first sample, which is a different
        // thing from a volume that cannot be read.
        guard let diskSpace = store.diskSpace else { return "Reading…" }
        return HogFormat.capacity(usedPercent: diskSpace.usedFraction * 100,
                                  freeBytes: diskSpace.freeBytes)
    }

    private var capacityCards: some View {
        HStack(alignment: .top, spacing: 8) {
            capacityCard("Internal", value: quickInternalText,
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
        return externalDrives.first.map(quickDriveText) ?? unrecognizedDriveText
    }

    private var timeMachineCapacityText: String {
        if timeMachineDrives.count > 1 {
            return selectedTab == .storage ? "\(timeMachineDrives.count) destinations · details below"
                : "\(timeMachineDrives.count) destinations · see Storage"
        }
        return timeMachineDrive.map(quickDriveText) ?? unrecognizedDriveText
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

    /// The mounted volumes, each with the path it is mounted at.
    ///
    /// The prior layout listed the drives with their mount paths and a
    /// severity bar.  The redesigned panel shows capacity cards only, so a
    /// drive that was nearly full looked the same as one with room to spare,
    /// and the path a drive was mounted at was hidden in a tooltip.
    private var mountedDriveList: some View {
        let drives = mountedDrives.rows
        return Group {
            if !drives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mounted Drives").font(.system(size: 11, weight: .semibold))
                    ForEach(drives) { drive in
                        mountedDriveRow(drive)
                    }
                }
            }
        }
    }

    private func mountedDriveRow(_ drive: MountedDriveUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label(drive.name, systemImage: "externaldrive")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(drive.usedPercent.map { String(format: "%.0f%% used", $0) } ?? "unavailable")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(driveSeverityColor(drive.severity))
            }
            Text(drive.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let percent = drive.usedPercent {
                ProgressView(value: percent, total: 100)
                    .tint(driveSeverityColor(drive.severity))
            }
            Text(capacityAmountsText(drive))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .help(drive.path)
    }

    private func driveSeverityColor(_ severity: MountedDriveUsage.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unavailable: return .secondary
        }
    }

    private func quickDriveText(_ drive: MountedDriveUsage) -> String {
        HogFormat.capacity(usedPercent: drive.usedPercent,
                           freeBytes: drive.availableBytes.map { UInt64(max(0, $0)) })
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
    /// The maximum expected quick-view height for the consolidated menu bar
    /// window with graphical CPU meters, RAM, storage of all kinds and alerts.
    static let panelHeight: CGFloat = 640
    static let dashboardWidth: CGFloat = 900
    static let dashboardHeight: CGFloat = 700
    static let dashboardMinimumWidth: CGFloat = 860
    static let inset: CGFloat = 14
    /// What is left of the panel once the inset is taken off both sides.
    static var contentWidth: CGFloat { panelWidth - inset * 2 }

    /// What the panel is showing, for screen readers.
    private var panelAccessibilityLabel: String {
        if isQuickView { return "Hog Hunter — this Mac quick view" }
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
    ///
    /// There is no attach/detach entry any more.  Detaching put a second copy
    /// of the same readings in a floating window beside a dashboard window
    /// that already showed them, so the small window had no reason to exist
    /// on its own; the dashboard opens from the menu bar window instead.
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

/// One row of the activity list: the app's name, the CPU it is using, and
/// the memory it is holding.
///
/// Both numbers, because the old row carried only CPU, so the apps that
/// were holding memory without burning CPU looked idle.
struct HogActivityRow: View {
    let name: String
    let cpuText: String
    let memoryText: String

    /// What a screen reader says for the row.
    var accessibilityLabel: String {
        "\(name), CPU \(cpuText), memory \(memoryText)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            Text(cpuText)
            Text(memoryText)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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
    /// The origin the view last asked the window to take.
    ///
    /// The move notification arrives after the move, on the main queue, so a
    /// flag cleared straight after the move would always read as false by the
    /// time the notification is handled.  The origin is what tells the
    /// observer apart: the window sitting at the origin the view asked for is
    /// the view's own move and starts no new pass.
    private var requestedOrigin: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        guard let window = self.window else { return }

        // Configure window transparency so the triangular beak and rounded
        // corners are transparent outside the DockedPanelShape, connecting
        // seamlessly to the menu bar status button like CodeCaps.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            if let requested = self.requestedOrigin {
                if window.frame.origin == requested {
                    // The move this view made itself.  The anchor for the new
                    // position was reported when the move was made, so the
                    // notification starts no new pass.
                    self.requestedOrigin = nil
                    return
                }
                // The window did not take the origin the view asked for.  The
                // request stays, so the view does not ask for the same place
                // again, and the pass below works out the anchor for where
                // the window actually is.
            }
            self.resolveAnchor()
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let winW = window.frame.width
        let anchor = Self.findStatusItemMidX()

        // The window hangs under the menu bar item.  Put the middle of the
        // window under the middle of the item, so the window sits centered on
        // the button instead of hanging off one side of it.  The beak keeps
        // pointing at the item either way.  Only an item that was positively
        // identified as ours may move the window: a guess may belong to
        // another status item, and the window would hang under that one.
        if let anchor, anchor.matched {
            centerWindow(on: anchor.midX)
        }

        let winX = window.frame.origin.x

        let targetX: CGFloat
        if let itemMidX = anchor?.midX {
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

    /// Moves the window so its middle sits under the menu bar item's middle.
    ///
    /// The item's position comes from the accessibility tree, the same place
    /// the beak gets its coordinate, so the beak and the window cannot
    /// disagree.  The window is kept on the screen it is already on.
    private func centerWindow(on itemMidX: CGFloat) {
        guard let window else { return }
        let frame = window.frame
        guard frame.width > 0 else { return }

        var targetX = itemMidX - frame.width / 2
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            let minX = screen.frame.minX + 8
            let maxX = screen.frame.maxX - frame.width - 8
            targetX = min(max(targetX, minX), max(minX, maxX))
        }
        let origin = NSPoint(x: targetX, y: frame.origin.y)
        guard abs(targetX - frame.origin.x) > 0.5 else { return }
        // The window did not take this origin last time; asking again would
        // only move it back and forth.
        guard requestedOrigin != origin else { return }

        requestedOrigin = origin
        window.setFrameOrigin(origin)
    }

    /// The middle of the menu bar status item, and whether that item was
    /// positively identified as Hog Hunter's own.
    ///
    /// The fallback below is the first extra menu bar item, which is a guess
    /// whenever the app carries more than one.  A guess is good enough for
    /// the beak, which only has to point at the menu bar, but the window is
    /// moved for an item that was positively identified and no other.
    static func findStatusItemMidX() -> (midX: CGFloat, matched: Bool)? {
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
                return (midX, true)
            }
        }

        // A guess: the first extra menu bar item, which is Hog Hunter's own
        // when it is the only one, and something else when it is not.
        if let first = children.first, let midX = axMidX(of: first) {
            return (midX, false)
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

