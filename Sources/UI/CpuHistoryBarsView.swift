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
        .help("Last 30 minutes.\u{00A0} Each bar is one minute's average; empty minutes have no reading.")
    }
}

/// The dashboard preference is local to this Mac; it does not change the
/// menu-bar icon or any of the CPU readings.
enum DashboardCpuChartStyle: String, CaseIterable, Identifiable {
    case line = "Line"
    case historyBars = "History Bars"

    static let preferenceKey = "dashboardCpuChartStyle"
    var id: String { rawValue }
}

struct DashboardCpuHistoryView: View {
    let history: CpuMinuteHistory
    let height: CGFloat
    @AppStorage(DashboardCpuChartStyle.preferenceKey) private var style = DashboardCpuChartStyle.line.rawValue

    var body: some View {
        if DashboardCpuChartStyle(rawValue: style) == .historyBars {
            CpuHistoryBarsView(history: history, height: height)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let values = history.bars(at: context.date)
                Canvas { graphics, size in
                    let step = size.width / CGFloat(max(1, values.count - 1))
                    var previous: CGPoint?
                    var line = Path()
                    for (index, value) in values.enumerated() {
                        guard let value else {
                            previous = nil
                            continue
                        }
                        let point = CGPoint(x: CGFloat(index) * step,
                                            y: 2 + max(0, size.height - 4) * CGFloat(1 - value / 100))
                        if let previous {
                            line.move(to: previous)
                            line.addLine(to: point)
                        } else {
                            graphics.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1,
                                                                width: 2, height: 2)),
                                          with: .color(.accentColor))
                        }
                        previous = point
                    }
                    graphics.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
                }
                .frame(height: height)
                .accessibilityLabel("CPU usage over the last 30 minutes")
                .accessibilityValue(values.compactMap { $0 }.last.map {
                    String(format: "Last reading %.0f%%", $0)
                } ?? "No readings")
            }
        }
    }
}
