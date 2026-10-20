import SwiftUI

/// Shared database and directory typography.  The time suffix is four points smaller.
struct SizeUsageRow: View {
    let name: String
    let bytes: Int64?
    let percentChange: Double?
    var unavailable = false
    var fontSize: CGFloat = 11
    var detail: String? = nil

    private let gap = "\u{00A0} "

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name + gap)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(bytes.map { HogFormat.memory(UInt64(max(0, $0))) } ?? "—")
                .fontWeight(.semibold)
                .monospacedDigit()
                .fixedSize()
            (
                Text(gap + "(" + (unavailable ? "—" : SizeGrowthFormat.delta(percentChange) ?? "—") + "⁄")
                + Text("24h").font(.system(size: max(7, fontSize - 4)))
                + Text(")")
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
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
        .help(unavailable ? "The latest size could not be measured; any shown size is an earlier reading."
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
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.mini) }
            }
            ForEach(store.rows) { row in
                SizeUsageRow(name: row.title == "Derived Data" ? row.title : displayPath(row.displayPath), bytes: row.bytes,
                             percentChange: row.percentChange, unavailable: row.isUnavailable, fontSize: 10,
                             detail: status(row))
                    .help(detail(row))
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func status(_ row: DirectoryUsageRow) -> String {
        if row.scanStartedAt != nil, row.progressEntries > 0 {
            return "\(HogFormat.memory(UInt64(max(0, row.progressBytes)))) scanned · \(row.progressEntries) entries · \(row.statusText.lowercased())"
        }
        if row.statusText == "Complete", let sampledAt = row.sampledAt {
            return "walk began " + timestamp(sampledAt)
        }
        return row.statusText
    }

    private func detail(_ row: DirectoryUsageRow) -> String {
        var lines = [row.path, row.statusText]
        if let sampledAt = row.sampledAt { lines.append("Last complete size: walk began " + timestamp(sampledAt)) }
        if let completedAt = row.completedAt { lines.append("Walk finished " + timestamp(completedAt)) }
        if let startedAt = row.scanStartedAt {
            lines.append("Current walk began " + timestamp(startedAt))
            lines.append("\(row.progressEntries) entries, \(row.progressBytes) allocated bytes scanned; partial totals are not a complete size")
        }
        return lines.joined(separator: "\n")
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, h:mma"
        return formatter.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path == "/private/tmp" ? "/tmp" : path
    }
}
