import AppKit
import SwiftUI

/// Mini menu bar item showing recent CPU history bars with the machine CPU % on top.
///
/// Designed to fit comfortably in the 22 pt macOS menu bar item height.  The percentage
/// is rendered in monospaced bold text colored by CPU severity, directly over 14 mini
/// vertical bars reflecting minute-by-minute CPU history.
///
/// Rendered into one status-bar bitmap so `MenuBarExtra` keeps both the
/// percentage and the history bars.  `MenuBarStatus` holds that bitmap and
/// replaces it only when the quantized picture changes.
struct MenuBarCpuBarsView: View {
    static let pointSize = NSSize(width: 36, height: 20)

    let history: CpuMinuteHistory
    let cpuPercent: Double
    var showPercent: Bool = true

    var body: some View {
        let image = Self.makeImage(history: history, cpuPercent: cpuPercent, showPercent: showPercent)
        Image(nsImage: image)
            .frame(width: image.size.width, height: image.size.height)
    }

    static func makeImage(
        history: CpuMinuteHistory,
        cpuPercent: Double,
        showPercent: Bool = true,
        at date: Date = Date()
    ) -> NSImage {
        render(
            percent: MenuBarQuantize.displayedPercent(cpuPercent),
            bars: MenuBarQuantize.historyBars(history, at: date),
            showPercent: showPercent,
            appearance: .current
        )
    }

    static func render(percent: Int, bars: [Int?], showPercent: Bool, appearance: MenuBarChrome) -> NSImage {
        let graphic = MenuBarPicture.Graphic.historyBars(percent: percent, bars: bars, showPercent: showPercent)
        let monochrome = !graphic.bakesAppearance
        let image = MenuBarBitmap.rasterize(size: pointSize, appearance: appearance) { _ in
            draw(percent: percent, bars: bars, showPercent: showPercent, monochrome: monochrome)
        }
        image.isTemplate = monochrome
        return image
    }

    private static func draw(percent: Int, bars: [Int?], showPercent: Bool, monochrome: Bool) {
        let width = pointSize.width
        let height = pointSize.height
        if showPercent {
            let percentString = String(format: "%.0f%%", Double(percent))
            let textColor = textColor(for: Double(percent), monochrome: monochrome)
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
        }

        let barWidth: CGFloat = 1.5
        let barSpacing: CGFloat = 1.0
        let totalBarsWidth = CGFloat(bars.count) * barWidth + CGFloat(max(0, bars.count - 1)) * barSpacing
        let startX = (width - totalBarsWidth) / 2.0
        let maxBarHeight: CGFloat = showPercent ? 8.5 : 15.0
        let baseY: CGFloat = showPercent ? 0.5 : (height - maxBarHeight) / 2.0

        for (index, val) in bars.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + barSpacing)
            let valHeight: CGFloat
            let color: NSColor
            if let val {
                let clamped = min(100.0, max(0.0, Double(val)))
                valHeight = max(1.5, maxBarHeight * CGFloat(clamped / 100.0))
                color = barColor(for: clamped, monochrome: monochrome)
            } else {
                valHeight = 1.5
                color = monochrome
                    ? NSColor.black.withAlphaComponent(0.25)
                    : NSColor.secondaryLabelColor.withAlphaComponent(0.25)
            }
            let barRect = NSRect(x: x, y: baseY, width: barWidth, height: valHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 0.5, yRadius: 0.5)
            color.setFill()
            path.fill()
        }
    }

    private static func textColor(for percent: Double, monochrome: Bool) -> NSColor {
        if monochrome { return .black }
        switch Severity.forMachineCpu(percent) {
        case .calm:
            return .labelColor
        case .elevated:
            return NSColor(red: 0.90, green: 0.58, blue: 0.12, alpha: 1.0)
        case .hot:
            return NSColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1.0)
        }
    }

    private static func barColor(for value: Double, monochrome: Bool) -> NSColor {
        if monochrome { return NSColor.black.withAlphaComponent(0.70) }
        switch Severity.forMachineCpu(value) {
        case .calm:
            return NSColor.labelColor.withAlphaComponent(0.70)
        case .elevated:
            return NSColor(red: 0.90, green: 0.58, blue: 0.12, alpha: 1.0)
        case .hot:
            return NSColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1.0)
        }
    }
}
