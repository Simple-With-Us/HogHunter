import SwiftUI

/// Mini menu bar item showing recent CPU history bars with the machine CPU % on top.
///
/// Designed to fit comfortably in the 22 pt macOS menu bar item height.  The percentage
/// is rendered in monospaced bold text colored by CPU severity, directly over 14 mini
/// vertical bars reflecting minute-by-minute CPU history.
struct MenuBarCpuBarsView: View {
    let history: CpuMinuteHistory
    let cpuPercent: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .center, spacing: 1) {
                Text(String(format: "%.0f%%", min(999, max(0, cpuPercent))))
                    .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(textColor(for: cpuPercent))
                    .lineLimit(1)

                HStack(alignment: .bottom, spacing: 1) {
                    let recentBars = history.bars(at: timeline.date).suffix(14)
                    ForEach(Array(recentBars.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(barColor(for: value))
                            .frame(width: 1.5, height: barHeight(for: value))
                    }
                }
                .frame(height: 8.5, alignment: .bottom)
            }
            .frame(width: 36, height: 20)
        }
    }

    private func textColor(for percent: Double) -> Color {
        let severity = Severity.forMachineCpu(percent)
        switch severity {
        case .calm:
            return .primary
        case .elevated:
            return Color(red: 0.90, green: 0.58, blue: 0.12)
        case .hot:
            return Color(red: 0.90, green: 0.22, blue: 0.20)
        }
    }

    private func barColor(for value: Double?) -> Color {
        guard let value else { return Color.secondary.opacity(0.25) }
        return Severity.forMachineCpu(value).color
    }

    private func barHeight(for value: Double?) -> CGFloat {
        guard let value else { return 1.5 }
        let clamped = min(100, max(0, value))
        return max(1.5, 8.5 * CGFloat(clamped / 100))
    }
}
