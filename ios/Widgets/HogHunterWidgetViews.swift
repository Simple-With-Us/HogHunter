import AppIntents
import WidgetKit
import SwiftUI

/// Which machines one widget instance watches.  The Mac and the server
/// are peers here as on the phone: a person can pin a Mac widget, a
/// Server widget, or one that shows both, instead of every widget
/// leading with the Mac and squeezing the server underneath.
enum HostFocus: String, AppEnum {
    case both
    case mac
    case server

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Machines" }

    static var caseDisplayRepresentations: [HostFocus: DisplayRepresentation] {
        [.both: "Mac and Server", .mac: "Mac Only", .server: "Server Only"]
    }

    var showsMac: Bool { self == .both || self == .mac }
    var showsServer: Bool { self == .both || self == .server }
}

/// What the busy list is ranked by, the same choice the phone's
/// Activity list offers through the Mac's sort.
enum BusyRank: String, AppEnum {
    case cpu
    case memory

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Rank Busy By" }

    static var caseDisplayRepresentations: [BusyRank: DisplayRepresentation] {
        [.cpu: "CPU", .memory: "Memory"]
    }
}

/// Which phone tab a tap on the widget opens.  The raw values are the
/// `hoghunter://open/<tab>` path names `CompanionDeepLink` accepts.
enum WidgetTab: String, AppEnum {
    case overview
    case mac
    case server
    case upkeep

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Tap Opens" }

    static var caseDisplayRepresentations: [WidgetTab: DisplayRepresentation] {
        [.overview: "Overview", .mac: "Mac", .server: "Server", .upkeep: "Upkeep"]
    }

    var url: URL { URL(string: "hoghunter://open/\(rawValue)")! }
}

struct SelectHostIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Machines"
    static var description = IntentDescription("Show your Mac, your server, or both.")

    @Parameter(title: "Show", default: .both)
    var hostFocus: HostFocus

    @Parameter(title: "Rank Busy By", default: .cpu)
    var busyRank: BusyRank

    @Parameter(title: "Show Clean Button", default: true)
    var showCleanButton: Bool

    @Parameter(title: "Tap Opens", default: .overview)
    var opensTab: WidgetTab
}

struct HogHunterWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionSnapshot?
    let cleanStatus: String
    let lastCleanDate: Date?
    let lastCleanBytes: String?
    var hostFocus: HostFocus = .both
    var busyRank: BusyRank = .cpu
    var showClean: Bool = true
    var opensTab: WidgetTab = .overview

    /// The snapshot's rows in this instance's chosen order.  Both ranks
    /// are the shared total orders the phone Overview uses, so a widget
    /// and the app never disagree about what busiest means.
    var busyRows: [CompanionRow] {
        guard let snapshot else { return [] }
        return busyRank == .memory ? snapshot.rows.rankedByMemory() : snapshot.rows.rankedByActivity()
    }
}

struct Provider: AppIntentTimelineProvider {
    private let appGroupSuite = "group.com.simplewithus.hoghunter"

    func placeholder(in context: Context) -> HogHunterWidgetEntry {
        Self.sampleEntry()
    }

    /// The entry the screenshot lane renders.  It does not read the App Group,
    /// so the Clean pill is on screen even while issue #65 blocks live data.
    static func sampleEntry(focus: HostFocus = .both, busyRank: BusyRank = .cpu, showClean: Bool = true, opensTab: WidgetTab = .overview) -> HogHunterWidgetEntry {
        HogHunterWidgetEntry(
            date: Date(),
            snapshot: sampleSnapshot(),
            cleanStatus: "Ready",
            lastCleanDate: Date().addingTimeInterval(-3600),
            lastCleanBytes: "3.8 GB",
            hostFocus: focus,
            busyRank: busyRank,
            showClean: showClean,
            opensTab: opensTab
        )
    }

    func snapshot(for configuration: SelectHostIntent, in context: Context) async -> HogHunterWidgetEntry {
        let entry = currentEntry(configuration: configuration)
        // The widget gallery has no reading yet; show the fixture in the
        // chosen options so each previews as it will look pinned.
        if context.isPreview, entry.snapshot == nil {
            return Self.sampleEntry(
                focus: configuration.hostFocus,
                busyRank: configuration.busyRank,
                showClean: configuration.showCleanButton,
                opensTab: configuration.opensTab
            )
        }
        return entry
    }

    func timeline(for configuration: SelectHostIntent, in context: Context) async -> Timeline<HogHunterWidgetEntry> {
        let entry = currentEntry(configuration: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func currentEntry(configuration: SelectHostIntent) -> HogHunterWidgetEntry {
        let defaults = UserDefaults(suiteName: appGroupSuite)
        var snap: CompanionSnapshot? = nil
        if let data = defaults?.data(forKey: "last_snapshot") {
            snap = try? CompanionJSON.decode(data)
        }
        let cleanStatus = defaults?.string(forKey: "clean_status") ?? "Ready"
        let lastCleanEpoch = defaults?.double(forKey: "last_clean_date") ?? 0
        let lastCleanDate = lastCleanEpoch > 0 ? Date(timeIntervalSince1970: lastCleanEpoch) : nil
        let lastCleanBytes = defaults?.string(forKey: "last_clean_bytes")

        return HogHunterWidgetEntry(
            date: Date(),
            snapshot: snap ?? (ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ? Self.sampleSnapshot() : nil),
            cleanStatus: cleanStatus,
            lastCleanDate: lastCleanDate,
            lastCleanBytes: lastCleanBytes,
            hostFocus: configuration.hostFocus,
            busyRank: configuration.busyRank,
            showClean: configuration.showCleanButton,
            opensTab: configuration.opensTab
        )
    }

    private static func sampleSnapshot() -> CompanionSnapshot {
        CompanionSnapshot(
            version: 1,
            hostName: "MacBook Pro",
            sampledAt: Date(),
            hasBaseline: true,
            window: "Now",
            grouping: "Apps",
            cpuScale: "Per Core",
            pulse: CompanionPulse(
                cpuPercent: 34,
                cpuText: "34%",
                cpuCaption: "of all 10 cores",
                cpuSeverity: "calm",
                memoryPercent: 68,
                memoryText: "10.9 of 16 GB",
                memoryCaption: "Memory in use",
                swapText: "820 MB swapped",
                pressureText: "Normal",
                pressureSeverity: "calm"
            ),
            rows: [
                CompanionRow(id: "chrome", name: "Google Chrome", detail: "8 processes", cpuText: "142%", memoryText: "2.1 GB", severity: "elevated", isApp: true),
                CompanionRow(id: "xcode", name: "Xcode", detail: "4 processes", cpuText: "85%", memoryText: "1.8 GB", severity: "calm", isApp: true),
                CompanionRow(id: "node", name: "node", detail: "pid 5120", cpuText: "290%", memoryText: "680 MB", severity: "hot", isApp: false)
            ],
            // Only what `widgetCopy()` lets cross: state, times, and the
            // CPU and memory percentages.
            server: CompanionServerStatus(
                state: "ok",
                generatedAt: Date(),
                cpu: CompanionServerCPU(percent: 58, percentText: "58.0%", severity: "calm"),
                memory: CompanionServerMeter(percent: 46, percentText: "46%", severity: "calm")
            )
        )
    }
}

enum WidgetColor {
    static func severityColor(_ severity: String) -> Color {
        switch severity {
        case "hot":
            return Color.red
        case "elevated":
            return Color.orange
        default:
            return Color.accentColor
        }
    }
}

/// The server's side of the widget.  The Mac's snapshot carries the server's
/// last reading (`snapshot.server`); the widget used to read only the Mac half
/// of it, so a person with a server saw nothing about it here.  The state comes
/// first: a stale or failed reading is said so, never drawn as current.
struct WidgetServerBlock: View {
    let server: CompanionServerStatus?
    /// One line instead of two meters, for the small widget.
    var compact = false

    var body: some View {
        if let server {
            let state = server.resolvedState()
            switch state {
            case .notConfigured:
                EmptyView()
            case .noReading:
                note("Server: waiting for a reading")
            case .error:
                note("Server: last read failed")
            case .stale:
                note("Server: reading is stale")
            case .ok:
                if compact {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text(summary(server))
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Server \(summary(server))")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text("Server")
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                        }
                        meter("CPU", percent: server.cpu?.percent,
                              text: server.cpu?.percentText ?? server.headline?.cpuText,
                              severity: server.cpu?.severity ?? server.headline?.cpuSeverity)
                        meter("RAM", percent: server.memory?.percent,
                              text: server.memory?.percentText ?? server.headline?.memoryText,
                              severity: server.memory?.severity ?? server.headline?.memorySeverity)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func summary(_ server: CompanionServerStatus) -> String {
        let cpu = server.cpu?.percentText ?? server.headline?.cpuText
        let ram = server.memory?.percentText ?? server.headline?.memoryText
        var parts: [String] = []
        if let cpu { parts.append("CPU \(cpu)") }
        if let ram { parts.append("RAM \(ram)") }
        return parts.isEmpty ? "no readings" : parts.joined(separator: " · ")
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func meter(_ label: String, percent: Double?, text: String?, severity: String?) -> some View {
        if percent != nil || text != nil {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(text ?? CompanionServerStatus.dash)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .lineLimit(1)
                }
                if let percent {
                    ProgressView(value: min(max(percent / 100, 0), 1))
                        .tint(WidgetColor.severityColor(severity ?? "calm"))
                        .controlSize(.mini)
                }
            }
        }
    }
}

/// The one Clean control, sized like the readings it sits under.  It
/// used to be a full-width hero button on the medium and large widgets,
/// taller than a meter and clipped by the large widget's bottom edge.
/// Only this control asks to clean; the rest of the widget opens the app,
/// and the app confirms before anything is removed.
struct CleanPill: View {
    let entry: HogHunterWidgetEntry
    /// The small widget has no separate status line, so its pill carries
    /// the last reclaimed size.  Larger sizes print it beside the pill.
    var showsReclaimedBytes = true

    var body: some View {
        Link(destination: URL(string: "hoghunter://clean")!) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text(showsReclaimedBytes ? (entry.lastCleanBytes.map { "Clean: \($0)" } ?? "Clean Mac") : "Clean Mac")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor, in: Capsule())
        }
        .accessibilityLabel("Clean Mac")
    }
}

/// A Server-only widget instance.  The widget copy carries only the
/// server's state, reading times, and CPU and memory percentages (see
/// `widgetCopy()`), so this shows those and their age, with no Mac rows
/// and no Mac Clean control underneath.
struct ServerWidgetView: View {
    let entry: HogHunterWidgetEntry
    var large = false

    var body: some View {
        if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: large ? 8 : 6) {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color.accentColor)
                        .font(large ? .headline : .caption.weight(.semibold))
                    Text("Server")
                        .font(large ? .headline : .caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let generatedAt = snap.server?.generatedAt {
                        (Text("as of ") + Text(generatedAt, style: .relative))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if large, let server = snap.server, server.resolvedState() == .ok {
                    HStack(spacing: 8) {
                        gauge("CPU", percent: server.cpu?.percent,
                              text: server.cpu?.percentText ?? server.headline?.cpuText,
                              severity: server.cpu?.severity ?? server.headline?.cpuSeverity)
                        gauge("Memory", percent: server.memory?.percent,
                              text: server.memory?.percentText ?? server.headline?.memoryText,
                              severity: server.memory?.severity ?? server.headline?.memorySeverity)
                    }
                } else {
                    WidgetServerBlock(server: snap.server)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(entry.opensTab.url)
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open Hog Hunter to see your server.")
                .widgetURL(entry.opensTab.url)
        }
    }

    /// One large gauge card, matching the Mac gauges on the combined
    /// large widget so the two machines read at the same scale.
    private func gauge(_ title: String, percent: Double?, text: String?, severity: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text ?? CompanionServerStatus.dash)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let percent {
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .tint(WidgetColor.severityColor(severity ?? "calm"))
                    .controlSize(.mini)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyWidgetView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}

struct HogHunterSmallWidgetView: View {
    let entry: HogHunterWidgetEntry

    var body: some View {
        if entry.hostFocus == .server {
            ServerWidgetView(entry: entry)
        } else if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.weight(.semibold))
                    Text(snap.hostName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                // CPU
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("CPU")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(snap.pulse.cpuText)
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    ProgressView(value: min(max(snap.pulse.cpuPercent / 100, 0), 1))
                        .tint(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        .controlSize(.mini)
                        
                }
                .accessibilityElement(children: .combine)

                // Memory
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("RAM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(snap.pulse.memoryText)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    ProgressView(value: min(max(snap.pulse.memoryPercent / 100, 0), 1))
                        .tint(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                        .controlSize(.mini)
                        
                }
                .accessibilityElement(children: .combine)

                if entry.hostFocus.showsServer {
                    WidgetServerBlock(server: snap.server, compact: true)
                }

                Spacer(minLength: 0)

                if entry.showClean {
                    CleanPill(entry: entry)
                }
            }
            .widgetURL(entry.opensTab.url)
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open Hog Hunter to see your Mac.")
                .widgetURL(entry.opensTab.url)
        }
    }
}

struct HogHunterMediumWidgetView: View {
    let entry: HogHunterWidgetEntry

    var body: some View {
        if entry.hostFocus == .server {
            ServerWidgetView(entry: entry)
        } else if let snap = entry.snapshot {
            HStack(spacing: 12) {
                // Left Column: Telemetry
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(Color.accentColor)
                        Text(snap.hostName)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }

                    // CPU
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("CPU")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(snap.pulse.cpuText)
                                .font(.system(.footnote, design: .monospaced).weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        ProgressView(value: min(max(snap.pulse.cpuPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        .controlSize(.mini)
                            
                    }
                        .accessibilityElement(children: .combine)

                    // Memory
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("RAM")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(snap.pulse.memoryText)
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        ProgressView(value: min(max(snap.pulse.memoryPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                        .controlSize(.mini)
                            
                    }
                        .accessibilityElement(children: .combine)

                    if let swap = snap.pulse.swapText {
                        Text(swap)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Right Column: Top Hog & Clean Action
                VStack(alignment: .leading, spacing: 6) {
                    if entry.hostFocus.showsServer {
                        WidgetServerBlock(server: snap.server, compact: true)
                    }

                    if let topHog = entry.busyRows.first {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Top Hog")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            HStack {
                                Text(topHog.name)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.busyRank == .memory ? topHog.memoryText : topHog.cpuText)
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    // Clean status & button
                    if entry.showClean {
                        VStack(alignment: .leading, spacing: 4) {
                            if let bytes = entry.lastCleanBytes {
                                Text("Last: \(bytes) reclaimed")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("Clean: \(entry.cleanStatus)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            CleanPill(entry: entry, showsReclaimedBytes: false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .widgetURL(entry.opensTab.url)
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open Hog Hunter to see your Mac.")
                .widgetURL(entry.opensTab.url)
        }
    }
}

struct HogHunterLargeWidgetView: View {
    let entry: HogHunterWidgetEntry
    /// Past this the reading is stale.  Matches CompanionFreshness.staleAfter;
    /// restated because the widget target does not include that file.
    private static let staleAfter: TimeInterval = 15

    var body: some View {
        if entry.hostFocus == .server {
            ServerWidgetView(entry: entry, large: true)
        } else if let snap = entry.snapshot {
            // The timeline date, not now: the widget draws a frozen entry.
            let stale = entry.date.timeIntervalSince(snap.sampledAt) > Self.staleAfter
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "desktopcomputer")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.hostName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(snap.window) · \(snap.grouping)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        (Text("as of ") + Text(snap.sampledAt, style: .relative))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(stale ? Color.secondary : Color.green)
                        .frame(width: 8, height: 8)
                }

                // Gauges Row
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CPU")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(snap.pulse.cpuText)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                        ProgressView(value: min(max(snap.pulse.cpuPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        .controlSize(.mini)
                        Text(snap.pulse.cpuCaption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Memory")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(snap.pulse.memoryText)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ProgressView(value: min(max(snap.pulse.memoryPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                        .controlSize(.mini)
                        Text(snap.pulse.swapText ?? snap.pulse.memoryCaption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }

                if entry.hostFocus.showsServer, let server = snap.server, server.resolvedState() != .notConfigured {
                    WidgetServerBlock(server: server)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }

                // Top Hogs Section
                VStack(alignment: .leading, spacing: 4) {
                    Text("Busy Processes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    ForEach(entry.busyRows.prefix(3)) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.isApp ? "app.fill" : "gearshape")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(row.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(row.cpuText)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text(row.memoryText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                            .accessibilityElement(children: .combine)
                    }
                }

                Spacer(minLength: 0)

                // One compact row, not a card with a hero button: the
                // readings above are the content, Clean is a footnote.
                if entry.showClean {
                HStack(spacing: 8) {
                    Label("Safe Mac Clean", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let bytes = entry.lastCleanBytes {
                        Text("Reclaimed \(bytes)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(entry.cleanStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    CleanPill(entry: entry, showsReclaimedBytes: false)
                }
                }
            }
            .widgetURL(entry.opensTab.url)
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open Hog Hunter to see your Mac.")
                .widgetURL(entry.opensTab.url)
        }
    }
}

struct HogHunterWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            HogHunterSmallWidgetView(entry: entry)
        case .systemMedium:
            HogHunterMediumWidgetView(entry: entry)
        case .systemLarge:
            HogHunterLargeWidgetView(entry: entry)
        default:
            HogHunterSmallWidgetView(entry: entry)
        }
    }
}
