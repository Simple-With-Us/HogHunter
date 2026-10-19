import SwiftUI

/// Shared database and directory typography.  The time suffix is four points smaller.
struct SizeUsageRow: View {
    let name: String
    let bytes: Int64?
    let percentChange: Double?
    var unavailable = false
    var fontSize: CGFloat = 11

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
                SizeUsageRow(name: row.title == "Derived Data" ? row.title : displayPath(row.path), bytes: row.bytes,
                             percentChange: row.percentChange, unavailable: row.isUnavailable, fontSize: 10)
                    .help(row.path)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path == "/private/tmp" ? "/tmp" : path
    }
}
