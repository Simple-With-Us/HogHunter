import SwiftUI

struct CpuHistoryBarsView: View {
    let history: CpuMinuteHistory
    /// The height of the graph.  It fills the width it is given, so the same
    /// view serves a wide dashboard card and a half-width panel column.
    var height: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(history.bars(at: timeline.date).enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(value.map { Severity.forMachineCpu($0).color } ?? .clear)
                            .frame(maxWidth: .infinity)
                            .frame(height: value.map { max(1, geometry.size.height * $0 / 100) } ?? 1)
                    }
                }
                .frame(height: geometry.size.height, alignment: .bottom)
            }
        }
        .frame(height: height)
        .accessibilityLabel("CPU over the last 30 minutes")
        .help("Last 30 minutes.  Each bar is one minute's average; empty minutes have no reading.")
    }
}
