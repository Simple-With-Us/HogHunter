import WidgetKit
import SwiftUI

struct HogHunterWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionSnapshot?
    let cleanStatus: String
    let lastCleanDate: Date?
    let lastCleanBytes: String?
}

struct Provider: TimelineProvider {
    private let appGroupSuite = "group.com.simplewithus.hoghunter"

    func placeholder(in context: Context) -> HogHunterWidgetEntry {
        HogHunterWidgetEntry(
            date: Date(),
            snapshot: sampleSnapshot,
            cleanStatus: "Ready",
            lastCleanDate: Date().addingTimeInterval(-3600),
            lastCleanBytes: "3.8 GB"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (HogHunterWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HogHunterWidgetEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func currentEntry() -> HogHunterWidgetEntry {
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
            snapshot: snap ?? (ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ? sampleSnapshot : nil),
            cleanStatus: cleanStatus,
            lastCleanDate: lastCleanDate,
            lastCleanBytes: lastCleanBytes
        )
    }

    private var sampleSnapshot: CompanionSnapshot {
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
            ]
        )
    }
}

enum WidgetColor {
    static func severityColor(_ severity: String) -> Color {
        switch severity {
        case "hot":
            return Color(red: 0.75, green: 0.18, blue: 0.16)
        case "elevated":
            return Color(red: 0.80, green: 0.52, blue: 0.10)
        default:
            return Color(red: 0.18, green: 0.42, blue: 0.78)
        }
    }
}

struct EmptyWidgetView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.78))
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
        if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.78))
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
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(snap.pulse.cpuText)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                    }
                    ProgressView(value: min(max(snap.pulse.cpuPercent / 100, 0), 1))
                        .tint(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }

                // Memory
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("RAM")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(snap.pulse.memoryText)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                            .lineLimit(1)
                    }
                    ProgressView(value: min(max(snap.pulse.memoryPercent / 100, 0), 1))
                        .tint(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }

                Spacer(minLength: 0)

                // Clean status pill
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                    if let bytes = entry.lastCleanBytes {
                        Text("Clean: \(bytes)")
                            .font(.system(size: 9, weight: .medium))
                    } else {
                        Text(entry.cleanStatus)
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .widgetURL(URL(string: "hoghunter://clean"))
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open companion to view Mac")
                .widgetURL(URL(string: "hoghunter://open"))
        }
    }
}

struct HogHunterMediumWidgetView: View {
    let entry: HogHunterWidgetEntry

    var body: some View {
        if let snap = entry.snapshot {
            HStack(spacing: 12) {
                // Left Column: Telemetry
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.78))
                        Text(snap.hostName)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }

                    // CPU
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("CPU")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(snap.pulse.cpuText)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        }
                        ProgressView(value: min(max(snap.pulse.cpuPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                            .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    }

                    // Memory
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("RAM")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(snap.pulse.memoryText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                                .lineLimit(1)
                        }
                        ProgressView(value: min(max(snap.pulse.memoryPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                            .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    }

                    if let swap = snap.pulse.swapText {
                        Text(swap)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Right Column: Top Hog & Clean Action
                VStack(alignment: .leading, spacing: 6) {
                    if let topHog = snap.rows.first {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TOP HOG")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(topHog.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(topHog.cpuText)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(WidgetColor.severityColor(topHog.severity))
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    // Clean status & button
                    VStack(alignment: .leading, spacing: 4) {
                        if let bytes = entry.lastCleanBytes {
                            Text("Last: \(bytes) reclaimed")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Clean: \(entry.cleanStatus)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Link(destination: URL(string: "hoghunter://clean")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                Text("Clean Mac")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color(red: 0.18, green: 0.42, blue: 0.78))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open companion on iPhone to view Mac telemetry.")
                .widgetURL(URL(string: "hoghunter://open"))
        }
    }
}

struct HogHunterLargeWidgetView: View {
    let entry: HogHunterWidgetEntry

    var body: some View {
        if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "desktopcomputer")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.78))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.hostName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(snap.window) · \(snap.grouping)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(Color.green)
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
                            .foregroundStyle(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        ProgressView(value: min(max(snap.pulse.cpuPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.cpuSeverity))
                        Text(snap.pulse.cpuCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Memory")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(snap.pulse.memoryText)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                            .lineLimit(1)
                        ProgressView(value: min(max(snap.pulse.memoryPercent / 100, 0), 1))
                            .tint(WidgetColor.severityColor(snap.pulse.pressureSeverity))
                        Text(snap.pulse.swapText ?? snap.pulse.memoryCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }

                // Top Hogs Section
                VStack(alignment: .leading, spacing: 4) {
                    Text("BUSY PROCESSES")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)

                    ForEach(snap.rows.prefix(3)) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.isApp ? "app.fill" : "gearshape")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(row.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(row.cpuText)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(WidgetColor.severityColor(row.severity))
                            Text(row.memoryText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Disk & Clutter Cleaning Card
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Safe Mac Clean", systemImage: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.78))
                        Spacer()
                        if let bytes = entry.lastCleanBytes {
                            Text("Reclaimed \(bytes)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                        } else {
                            Text(entry.cleanStatus)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "hoghunter://clean")!) {
                        HStack {
                            Spacer()
                            Image(systemName: "sparkles")
                            Text("Clean Mac Clutter (Safe)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .background(Color(red: 0.18, green: 0.42, blue: 0.78))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            EmptyWidgetView(title: "Hog Hunter", message: "Open Hog Hunter on iPhone to connect to your Mac.")
                .widgetURL(URL(string: "hoghunter://open"))
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

@main
struct HogHunterWidgets: Widget {
    let kind: String = "HogHunterWidgets"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HogHunterWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hog Hunter")
        .description("Track Mac CPU, RAM, and trigger safe disk cleaning.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
