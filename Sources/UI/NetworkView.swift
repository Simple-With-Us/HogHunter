import SwiftUI

/// Network pane.  Shows the apps currently holding the most open network
/// connections and the most distinct remote hosts.  Refreshes on a 10 s
/// timer while the window is visible, with a manual button as the override.
struct NetworkView: View {
    @StateObject private var store: NetworkStore
    @State private var sortOrder: NetworkSort = .established
    @State private var refreshTask: Task<Void, Never>?

    private let embeddedInPanel: Bool
    private let isTabActive: Bool

    init(
        bundleResolver: @escaping (pid_t) -> (bundleId: String?, name: String),
        embeddedInPanel: Bool = false,
        isTabActive: Bool = true
    ) {
        _store = StateObject(wrappedValue: NetworkStore(bundleResolver: bundleResolver))
        self.embeddedInPanel = embeddedInPanel
        self.isTabActive = isTabActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.top, embeddedInPanel ? 0 : 4)
            statusRow
            list
            footer
        }
        .padding(embeddedInPanel ? 0 : 16)
        .modifier(NetworkPanelFrameModifier(embeddedInPanel: embeddedInPanel))
        .onAppear {
            if !embeddedInPanel {
                WindowActivator.front()
            }
            if isTabActive {
                store.refresh()
                startRefreshTimer()
            }
        }
        .onChange(of: isTabActive) { active in
            if active {
                store.refresh()
                startRefreshTimer()
            } else {
                refreshTask?.cancel()
                refreshTask = nil
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .navigationTitle("Network — Hog Hunter")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hog Hunter Network — apps with open connections")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Network")
                    .font(.system(size: 18, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Sort", selection: $sortOrder) {
                Text("Established").tag(NetworkSort.established)
                Text("Remote hosts").tag(NetworkSort.remoteHosts)
                Text("Open sockets").tag(NetworkSort.open)
            }
            .pickerStyle(.menu)
            .frame(width: 160)
        }
    }

    private var subtitle: String {
        guard case .completed(let at) = store.state else { return "Snapshotting…" }
        return "Updated \(Self.relative.localizedString(for: at, relativeTo: Date()))"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            switch store.state {
            case .idle, .scanning:
                ProgressView().scaleEffect(0.6)
                Text("Reading lsof…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .completed:
                Text("\(store.usages.count) apps with open connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .unavailable(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { store.refresh() }
        }
    }

    private var sortedUsages: [NetworkUsage] {
        switch sortOrder {
        case .established:
            return store.usages.sorted { $0.establishedSockets > $1.establishedSockets }
        case .remoteHosts:
            return store.usages.sorted { $0.remoteHostCount > $1.remoteHostCount }
        case .open:
            return store.usages.sorted { $0.openSockets > $1.openSockets }
        }
    }

    private var list: some View {
        Group {
            if store.usages.isEmpty, case .completed = store.state {
                Text("No open network connections right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.usages.isEmpty {
                Text("Snapshotting…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedUsages) { usage in
                            NetworkRowView(usage: usage)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var footer: some View {
        Text("lsof snapshot only — refreshes every 10 s while this window is open.  Per-process byte counters are not in the public API; for those, use Activity Monitor's Network tab.")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
    }

    private func startRefreshTimer() {
        refreshTask?.cancel()
        let store = self.store
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                if Task.isCancelled { return }
                store.refresh()
            }
        }
    }
}

enum NetworkSort: Hashable { case established, remoteHosts, open }

struct NetworkRowView: View {
    let usage: NetworkUsage

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            iconView
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(usage.topRemoteHosts.prefix(3).joined(separator: ", "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(usage.establishedSockets)/\(usage.openSockets)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text("\(usage.remoteHostCount) hosts")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(usage.name), \(usage.establishedSockets) established of \(usage.openSockets) open connections across \(usage.remoteHostCount) hosts")
    }

    private var iconView: some View {
        Group {
            if let bundleId = usage.bundleId,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               let icon = NSWorkspace.shared.icon(forFile: url.path) as NSImage? {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NetworkPanelFrameModifier: ViewModifier {
    let embeddedInPanel: Bool

    func body(content: Content) -> some View {
        if embeddedInPanel {
            content
        } else {
            content
                .frame(width: 520, height: 540)
                .background(Color(nsColor: .windowBackgroundColor))
                .background(WindowActivator())
        }
    }
}
