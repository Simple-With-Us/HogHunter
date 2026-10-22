import SwiftUI

/// Shared database and directory typography with appreciable daily changes.
struct SizeUsageRow: View {
    let name: String
    let bytes: Int64?
    let percentChange: Double?
    var unavailable = false
    var fontSize: CGFloat = 11
    /// The short status line shown beside the size.  The prior layout showed it
    /// in the row; the redesigned panel moved it into the tooltip, which meant a
    /// directory that was still being measured looked like a finished one.
    var detail: String? = nil

    private let gap = "\u{00A0} "

    private var appreciableDelta: String? {
        guard !unavailable else { return nil }
        return SizeGrowthFormat.appreciableDelta(percentChange)
    }

    private var deltaColor: Color {
        guard let percentChange, percentChange.isFinite else { return .secondary }
        if percentChange > 0 { return .red }
        if percentChange < 0 { return .green }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name + gap)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(bytes.map { HogFormat.memory(UInt64(max(0, $0))) } ?? "—")
                .fontWeight(.semibold)
                .monospacedDigit()
                .fixedSize()
            if let appreciableDelta {
                Text(gap + "(" + appreciableDelta + ")")
                    .foregroundColor(deltaColor)
                    .monospacedDigit()
                    .fixedSize()
            }
            if let detail {
                Text(gap + detail)
                    .font(.system(size: max(8, fontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize))
        .foregroundStyle(unavailable ? .secondary : .primary)
        .help(unavailable ? "A current size is unavailable; any shown size is an earlier complete reading."
              : percentChange == nil ? "A full day of comparable size history is not available yet." : name)
        .accessibilityElement(children: .combine)
    }
}

struct CodingDirectoriesView: View {
    @ObservedObject var store: DirectoryUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Directories").font(.system(size: 11, weight: .semibold))
                Text("(daily change)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Measuring directories")
                }
            }
            ForEach(store.rows) { row in
                SizeUsageRow(name: row.title == "Derived Data" ? row.title : displayPath(row.displayPath), bytes: row.bytes,
                             percentChange: row.percentChange, unavailable: row.isUnavailable, fontSize: 10,
                             detail: status(row))
                    .help(detail(row))
                    .accessibilityHint(detail(row))
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// The one-line status the row shows beside the size.
    private func status(_ row: DirectoryUsageRow) -> String {
        row.statusLine
    }

    private func detail(_ row: DirectoryUsageRow) -> String {
        var lines = [row.path, row.statusText]
        if let sampledAt = row.sampledAt { lines.append("Last complete size: walk began " + DirectoryUsageRow.timestamp(sampledAt)) }
        if let completedAt = row.completedAt { lines.append("Walk finished " + DirectoryUsageRow.timestamp(completedAt)) }
        if let startedAt = row.scanStartedAt {
            lines.append("Current walk began " + DirectoryUsageRow.timestamp(startedAt))
            lines.append("\(row.progressEntries) entries, \(row.progressBytes) allocated bytes scanned; partial totals are not a complete size")
        }
        return lines.joined(separator: "\n")
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path == "/private/tmp" ? "/tmp" : path
    }
}
