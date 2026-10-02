import SwiftUI

/// Network pane.  Shows the apps currently holding the most open network
/// connections and the most distinct remote hosts.  Refreshes on a 10 s
/// timer while the window is visible, with a manual button as the override.
struct NetworkView: View {
    @StateObject private var store: NetworkStore
    @ObservedObject private var bandwidth: BandwidthStore
    @State private var sortOrder: NetworkSort = .established
    @State private var refreshTask: Task<Void, Never>?

    private let embeddedInPanel: Bool
    private let isTabActive: Bool

    init(
        bundleResolver: @escaping (pid_t) -> (bundleId: String?, name: String),
        bandwidth: BandwidthStore,
        embeddedInPanel: Bool = false,
        isTabActive: Bool = true
    ) {
        _store = StateObject(wrappedValue: NetworkStore(bundleResolver: bundleResolver))
        _bandwidth = ObservedObject(wrappedValue: bandwidth)
        self.embeddedInPanel = embeddedInPanel
        self.isTabActive = isTabActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.top, embeddedInPanel ? 0 : 4)
            bandwidthStrip
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
            bandwidth.refreshPeaks()
            if isTabActive {
                store.refresh()
                startRefreshTimer()
            }
        }
        .onChange(of: isTabActive) { active in
            if active {
                store.refresh()
                bandwidth.refreshPeaks()
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
        .accessibilityLabel("Hog Hunter Network — bandwidth and apps with open connections")
    }

    // MARK: - Bandwidth

    /// Real bytes, read from the kernel's per-interface counters.
    ///
    /// "Now" is a short rolling average rather than a single tick, because a
    /// one-sample difference off a lifetime counter is mostly a packet burst.
    /// The peak is the highest sustained rate seen over the last 24 hours and
    /// survives restarts, because it is read back out of the history database
    /// rather than kept in memory for the life of the window.
    private var bandwidthStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            BandwidthCard(
                title: "Now",
                down: bandwidth.reading.downBytesPerSecond,
                up: bandwidth.reading.upBytesPerSecond,
                footnote: nowFootnote,
                help: "Average bytes per second over the last \(Int(bandwidth.reading.windowSeconds.rounded())) seconds."
            )
            BandwidthCard(
                title: "24-Hour Peak",
                down: bandwidth.peaks.peakDownBytesPerSecond,
                up: bandwidth.peaks.peakUpBytesPerSecond,
                footnote: peakFootnote,
                help: peakHelp
            )
        }
    }

    private var nowFootnote: String {
        guard bandwidth.reading.isMeasured else { return "Measuring…" }
        return "Last \(Int(bandwidth.reading.windowSeconds.rounded())) s"
    }

    private var peakFootnote: String {
        guard bandwidth.peaks.hasSamples else { return "No History Yet" }
        return "Sampled \(HogFormat.duration(bandwidth.peaks.sampledSeconds))"
    }

    private var peakHelp: String {
        guard let at = bandwidth.peaks.peakAt else {
            return "The fastest sustained download or upload seen in the last 24 hours."
        }
        let when = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short)
        return "The fastest sustained rate in the last 24 hours, reached at \(when)."
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
                Text("Remote Hosts").tag(NetworkSort.remoteHosts)
                Text("Open Sockets").tag(NetworkSort.open)
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
        VStack(alignment: .leading, spacing: 3) {
            Text("The list below is an lsof snapshot of who holds which connection.  Bandwidth above is the whole machine, read from the kernel's interface counters.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS has no public per-process byte counter.  For which app moved which bytes, use Activity Monitor's Network tab.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// One bandwidth number: download on the left, upload on the right, both with
/// the arrow that says which way the bytes are going.  Styled like the panel's
/// meters so the two panes read as one app.
struct BandwidthCard: View {
    let title: String
    let down: Double
    let up: Double
    let footnote: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rateLabel(down, arrow: "arrow.down", word: "Down")
                rateLabel(up, arrow: "arrow.up", word: "Up")
            }
            Text(footnote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("Download \(HogFormat.rate(down)), Upload \(HogFormat.rate(up)).  \(footnote)")
    }

    private func rateLabel(_ bytesPerSecond: Double, arrow: String, word: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(HogFormat.rate(bytesPerSecond))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .accessibilityLabel(word)
    }
}

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
