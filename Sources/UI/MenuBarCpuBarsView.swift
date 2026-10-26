import AppKit
import SwiftUI

/// Mini menu bar item showing recent CPU history bars with the machine CPU % on top.
///
/// Designed to fit comfortably in the 22 pt macOS menu bar item height.  The percentage
/// is rendered in monospaced bold text colored by CPU severity, directly over 14 mini
/// vertical bars reflecting minute-by-minute CPU history.
///
/// Rendered directly into an `NSImage` so macOS `NSStatusBarButton` displays both the
/// percentage and the history bars without dropping subviews in `MenuBarExtra`.
struct MenuBarCpuBarsView: View {
    let history: CpuMinuteHistory
    let cpuPercent: Double

    var body: some View {
        Image(nsImage: Self.makeImage(history: history, cpuPercent: cpuPercent))
    }

    static func makeImage(history: CpuMinuteHistory, cpuPercent: Double) -> NSImage {
        let width: CGFloat = 36
        let height: CGFloat = 20
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Draw CPU % on top (y: 9.5 .. 20.0)
            let percentString = String(format: "%.0f%%", min(999, max(0, cpuPercent)))
            let textColor = self.textColor(for: cpuPercent)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
            let textRect = NSRect(x: 0, y: 9.5, width: width, height: 10.5)
            (percentString as NSString).draw(in: textRect, withAttributes: attrs)

            // Draw 14 bars on bottom (y: 0.5 .. 9.0)
            let recentBars = Array(history.bars(at: Date()).suffix(14))
            let barWidth: CGFloat = 1.5
            let barSpacing: CGFloat = 1.0
            let totalBarsWidth = CGFloat(recentBars.count) * barWidth + CGFloat(max(0, recentBars.count - 1)) * barSpacing
            let startX = (width - totalBarsWidth) / 2.0
            let maxBarHeight: CGFloat = 8.5

            for (index, val) in recentBars.enumerated() {
                let x = startX + CGFloat(index) * (barWidth + barSpacing)
                let valHeight: CGFloat
                let barColor: NSColor
                if let val = val {
                    let clamped = min(100.0, max(0.0, val))
                    valHeight = max(1.5, maxBarHeight * CGFloat(clamped / 100.0))
                    barColor = self.barColor(for: val)
                } else {
                    valHeight = 1.5
                    barColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25)
                }
                let barRect = NSRect(x: x, y: 0.5, width: barWidth, height: valHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: 0.5, yRadius: 0.5)
                barColor.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func textColor(for percent: Double) -> NSColor {
        let severity = Severity.forMachineCpu(percent)
        switch severity {
        case .calm:
            return .labelColor
        case .elevated:
            return NSColor(red: 0.90, green: 0.58, blue: 0.12, alpha: 1.0)
        case .hot:
            return NSColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1.0)
        }
    }

    private static func barColor(for value: Double) -> NSColor {
        let severity = Severity.forMachineCpu(value)
        switch severity {
        case .calm:
            return NSColor.labelColor.withAlphaComponent(0.70)
        case .elevated:
            return NSColor(red: 0.90, green: 0.58, blue: 0.12, alpha: 1.0)
        case .hot:
            return NSColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1.0)
        }
    }
}
