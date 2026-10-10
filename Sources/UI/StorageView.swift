import SwiftUI
import AppKit

enum StorageTab: String, CaseIterable, Identifiable {
    case appStorage = "App Storage"
    case diskCleaner = "Disk Cleaner"
    case maintain = "Maintain"

    var id: String { rawValue }
}

/// Storage pane.  Shows top apps by disk usage with the bundle-vs-hidden
/// split and, when a row is expanded, the per-category breakdown, plus
/// a disk cleaner mode.
///
/// The view holds its own `StorageStore` so the panel does not pollute the
/// shared `HogStore`, and so opening it has no incidental effect on the CPU
/// panel's cadence.
struct StorageView: View {
    @StateObject private var store: StorageStore
    @StateObject private var cleanerStore = DiskCleanerStore()
    /// Owned by `HogStore`, which the iPhone route also uses, so the Mac and
    /// the phone cannot start a second run over each other.
    @ObservedObject private var maintainStore: MaintainStore
    @State private var selectedTab: StorageTab = .diskCleaner
    @State private var sortOrder: StorageSort = .total
    @State private var sortAscending: Bool = false
    @State private var filter: StorageFilter = .all
    @State private var expandedUsageId: String?

    private let embeddedInPanel: Bool
    private let isTabActive: Bool

    /// `initialTab` is the mode the view opens on.  The app always takes the
    /// default; a layout test opens the Maintain mode directly instead of
    /// clicking the segmented control.
    init(runningBundleIds: @escaping () -> Set<String>, maintainStore: MaintainStore, embeddedInPanel: Bool = false, isTabActive: Bool = true, initialTab: StorageTab = .diskCleaner) {
        _store = StateObject(wrappedValue: StorageStore(runningBundleIds: runningBundleIds))
        _selectedTab = State(initialValue: initialTab)
        self.maintainStore = maintainStore
        self.embeddedInPanel = embeddedInPanel
        self.isTabActive = isTabActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.top, embeddedInPanel ? 0 : 4)

            switch selectedTab {
            case .appStorage:
                appStorageControls
                statusRow
                list
                footer
            case .diskCleaner:
                DiskCleanerView(store: cleanerStore, isTabActive: isTabActive)
            case .maintain:
                MaintainView(store: maintainStore)
            }
        }
        .padding(embeddedInPanel ? 0 : 16)
        .modifier(PanelFrameModifier(embeddedInPanel: embeddedInPanel))
        .onAppear {
            if !embeddedInPanel {
                WindowActivator.front()
            }
            if isTabActive {
                if selectedTab == .appStorage, case .idle = store.state {
                    store.refresh()
                }
                startRefreshTimer()
            }
        }
        .onChange(of: isTabActive) { active in
            if active {
                if selectedTab == .appStorage, case .idle = store.state {
                    store.refresh()
                }
                startRefreshTimer()
            } else {
                refreshTask?.cancel()
                refreshTask = nil
            }
        }
        .onChange(of: selectedTab) { newTab in
            if isTabActive, newTab == .appStorage, case .idle = store.state {
                store.refresh()
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .navigationTitle("Storage — Hog Hunter")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hog Hunter Storage — top apps and disk cleaner")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedTab == .diskCleaner ? "sparkles" : (selectedTab == .maintain ? "fanblades.fill" : "internaldrive"))
                .font(.system(size: 20))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            // The label is hidden because the 260 pt frame covers label and
            // control together: "Mode" took its share, wrapped to "Mod" over
            // "e", and the Apps segment was pushed off the right edge.  The
            // segments say what they are, and VoiceOver still reads "Mode".
            Picker("Mode", selection: $selectedTab) {
                Text("Clean").tag(StorageTab.diskCleaner)
                Text("Maintain").tag(StorageTab.maintain)
                Text("Apps").tag(StorageTab.appStorage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .disabled(cleanerStore.isCleaning)
        }
    }

    // MARK: - App Storage Controls

    private var appStorageControls: some View {
        HStack(spacing: 10) {
            // `labelsHidden` is what was missing: the picker's "Filter" label
            // was rendering inside a 140 pt control and wrapping mid-word as
            // "Filt / er".  The segmented control only needs room for the two
            // segments, so it now sizes to them.
            Picker("Filter", selection: $filter) {
                Text("All").tag(StorageFilter.all)
                Text("Running").tag(StorageFilter.running)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            HStack(spacing: 4) {
                Text("Sort:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $sortOrder) {
                    Text("Total").tag(StorageSort.total)
                    Text("Hidden").tag(StorageSort.hidden)
                    Text("Bundle").tag(StorageSort.bundle)
                }
                .pickerStyle(.menu)
                .frame(width: 115)

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(sortAscending ? "Sort lowest first (ascending)" : "Sort highest first (descending)")
                .accessibilityLabel(sortAscending ? "Sort lowest first" : "Sort highest first")
            }
        }
    }

    private var headerTitle: String {
        switch selectedTab {
        case .diskCleaner: return "Clean"
        case .maintain: return "Maintain"
        case .appStorage: return "Storage"
        }
    }

    /// Keep each line short: the header is pinned to the panel's inner width, and
    /// a longer one pushes the mode control past the right edge.
    private var headerSubtitle: String {
        switch selectedTab {
        case .diskCleaner: return "Find clutter and remove what you choose"
        case .maintain: return "Scheduled upkeep, with a record of every run"
        case .appStorage: return subtitle
        }
    }

    private var subtitle: String {
        guard let when = store.state.completedAt else { return "Loading…" }
        return "Scanned \(Self.relativeTimeFormatter.localizedString(for: when, relativeTo: Date()))."
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        switch store.state {
        case .idle, .scanning:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Scanning installed apps…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { store.refresh() }
                    .disabled(true)
            }
        case .completed:
            HStack(spacing: 6) {
                Text("Showing \(store.apps.count) of \(store.installedAppCount) installed apps.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { store.refresh() }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Try again") { store.refresh() }
            }
        }
    }

    // MARK: - List

    private var filteredApps: [StorageUsage] {
        let base = filter == .running ? store.apps.filter(\.isRunning) : store.apps
        let sorted: [StorageUsage]
        switch sortOrder {
        case .total:
            sorted = base.sorted(by: { a, b in
                if a.totalBytes != b.totalBytes { return a.totalBytes > b.totalBytes }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        case .hidden:
            sorted = base.sorted(by: { a, b in
                if a.hiddenBytes != b.hiddenBytes { return a.hiddenBytes > b.hiddenBytes }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        case .bundle:
            sorted = base.sorted(by: { a, b in
                if a.bundleBytes != b.bundleBytes { return a.bundleBytes > b.bundleBytes }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        }
        return sortAscending ? sorted.reversed() : sorted
    }

    private var list: some View {
        Group {
            if store.apps.isEmpty, case .completed = store.state {
                Text("No installed apps found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.apps.isEmpty {
                Text("Scanning…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        flagLegend
                        ForEach(filteredApps) { app in
                            StorageRowView(
                                usage: app,
                                isExpanded: expandedUsageId == app.id,
                                onToggle: {
                                    expandedUsageId = (expandedUsageId == app.id) ? nil : app.id
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Flag legend

    /// Explains the red outline once, at the top of the list, whenever any app
    /// is flagged.  Owner 2026-10-03: the flags had no explanation anywhere a
    /// person would actually look — the row said nothing and the only text was
    /// behind a 10pt hover target.  A legend costs one line and removes the
    /// guesswork permanently.  Hidden entirely when nothing is flagged, so a
    /// clean machine does not grow a paragraph of caveats.
    @ViewBuilder
    private var flagLegend: some View {
        let flagged = filteredApps.filter(\.isHiddenHeavy)
        if !flagged.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 9.5))
                Text("\(flagged.count) \(flagged.count == 1 ? "app is" : "apps are") outlined in red: their supporting files are at least 5× the .app bundle and over 200 MB.  The reason is in each row's caption.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.red.opacity(0.07))
            )
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let caption = store.hiddenShareCaption() {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Click a row to see the breakdown.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Refresh timer

    /// Re-scans every 5 minutes while the window is open.  Storage doesn't
    /// change minute-to-minute; the value of the panel is in the per-app
    /// picture, not the per-second.
    @State private var refreshTask: Task<Void, Never>?

    private func startRefreshTimer() {
        refreshTask?.cancel()
        let store = self.store
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                if Task.isCancelled { return }
                if isTabActive && selectedTab == .appStorage {
                    store.refresh()
                }
            }
        }
    }
}

enum StorageSort: Hashable { case total, hidden, bundle }
enum StorageFilter: Hashable { case all, running }

private extension StorageStore.State {
    var completedAt: Date? {
        if case .completed(let at) = self { return at }
        return nil
    }
}

private struct PanelFrameModifier: ViewModifier {
    let embeddedInPanel: Bool

    func body(content: Content) -> some View {
        if embeddedInPanel {
            content
        } else {
            content
                .frame(minWidth: 540, minHeight: 640)
                .background(Color(nsColor: .windowBackgroundColor))
                .background(WindowActivator())
        }
    }
}
