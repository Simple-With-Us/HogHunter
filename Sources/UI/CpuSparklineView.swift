#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Micro-sparkline tracking recent machine CPU pressure for the macOS menu bar and header.
struct CpuSparklineView: View {
    let samples: [Double]
    var width: CGFloat = 36
    var height: CGFloat = 14

    var body: some View {
        #if os(macOS)
        Image(nsImage: Self.makeImage(samples: samples, width: width, height: height))
            .frame(width: width, height: height)
        #else
        Canvas { context, size in
            guard samples.count >= 2 else {
                // Draw simple idle baseline
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height - 1))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                return
            }

            let step = size.width / CGFloat(max(1, samples.count - 1))
            var path = Path()
            var areaPath = Path()

            let firstY = yCoordinate(for: samples[0], height: size.height)
            path.move(to: CGPoint(x: 0, y: firstY))
            areaPath.move(to: CGPoint(x: 0, y: size.height))
            areaPath.addLine(to: CGPoint(x: 0, y: firstY))

            for (index, sample) in samples.enumerated().dropFirst() {
                let x = CGFloat(index) * step
                let y = yCoordinate(for: sample, height: size.height)
                path.addLine(to: CGPoint(x: x, y: y))
                areaPath.addLine(to: CGPoint(x: x, y: y))
            }

            areaPath.addLine(to: CGPoint(x: size.width, y: size.height))
            areaPath.closeSubpath()

            let latest = samples.last ?? 0
            let color: Color
            if latest >= 85 {
                color = Color(red: 0.75, green: 0.18, blue: 0.16)
            } else if latest >= 60 {
                color = Color(red: 0.80, green: 0.52, blue: 0.10)
            } else {
                color = Color.primary.opacity(0.85)
            }

            context.fill(areaPath, with: .color(color.opacity(0.18)))
            context.stroke(path, with: .color(color), lineWidth: 1.25)

            // Current value indicator dot
            let lastX = size.width
            let lastY = yCoordinate(for: latest, height: size.height)
            let dotRect = CGRect(x: lastX - 2, y: lastY - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
        }
        .frame(width: width, height: height)
        #endif
    }

    #if !os(macOS)
    private func yCoordinate(for percent: Double, height: CGFloat) -> CGFloat {
        let clamped = max(0, min(100, percent))
        // Invert Y coordinate so 100% is near the top (with 1pt inset)
        let usableHeight = height - 2
        return (height - 1) - CGFloat(clamped / 100.0) * usableHeight
    }
    #endif

    #if os(macOS)
    // MARK: - AppKit Rasterization for macOS Menu Bar

    /// Rasterizes a micro-sparkline into an `NSImage` for use in `NSStatusBarButton` or other AppKit surfaces.
    static func makeImage(samples: [Double], width: CGFloat = 36, height: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            drawSparkline(in: rect, samples: samples)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Rasterizes both the Hog profile icon and the micro-sparkline into a single combined `NSImage`
    /// so macOS `NSStatusBarButton` displays both simultaneously without dropping either subview.
    static func makeHogAndSparklineImage(
        samples: [Double],
        sparklineWidth: CGFloat = 36,
        sparklineHeight: CGFloat = 14
    ) -> NSImage {
        let hogWidth: CGFloat = 18
        let hogHeight: CGFloat = 15
        let spacing: CGFloat = 4
        let totalWidth = hogWidth + spacing + sparklineWidth
        let totalHeight: CGFloat = 16

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            let hogRect = NSRect(x: 0, y: (totalHeight - hogHeight) / 2.0, width: hogWidth, height: hogHeight)
            if let hog = NSImage(named: NSImage.Name("HogProfile")) ?? Bundle.main.image(forResource: "HogProfile") {
                hog.draw(in: hogRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            let sparklineRect = NSRect(
                x: hogWidth + spacing,
                y: (totalHeight - sparklineHeight) / 2.0,
                width: sparklineWidth,
                height: sparklineHeight
            )
            drawSparkline(in: sparklineRect, samples: samples)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func drawSparkline(in rect: NSRect, samples: [Double]) {
        guard samples.count >= 2 else {
            let baselineY = rect.minY + 1.0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: baselineY))
            path.line(to: NSPoint(x: rect.maxX, y: baselineY))
            path.lineWidth = 1.0
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            path.stroke()
            return
        }

        let step = rect.width / CGFloat(max(1, samples.count - 1))
        let usableHeight = max(1.0, rect.height - 2.0)

        func yFor(percent: Double) -> CGFloat {
            let clamped = max(0.0, min(100.0, percent))
            return rect.minY + 1.0 + CGFloat(clamped / 100.0) * usableHeight
        }

        let linePath = NSBezierPath()
        let areaPath = NSBezierPath()

        let firstY = yFor(percent: samples[0])
        let startPoint = NSPoint(x: rect.minX, y: firstY)
        linePath.move(to: startPoint)

        areaPath.move(to: NSPoint(x: rect.minX, y: rect.minY))
        areaPath.line(to: startPoint)

        for (index, sample) in samples.enumerated().dropFirst() {
            let x = rect.minX + CGFloat(index) * step
            let y = yFor(percent: sample)
            let pt = NSPoint(x: x, y: y)
            linePath.line(to: pt)
            areaPath.line(to: pt)
        }

        areaPath.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        areaPath.close()

        let latest = samples.last ?? 0
        let color: NSColor
        if latest >= 85 {
            color = NSColor(red: 0.75, green: 0.18, blue: 0.16, alpha: 1.0)
        } else if latest >= 60 {
            color = NSColor(red: 0.80, green: 0.52, blue: 0.10, alpha: 1.0)
        } else {
            color = NSColor.labelColor.withAlphaComponent(0.85)
        }

        color.withAlphaComponent(0.18).setFill()
        areaPath.fill()

        color.setStroke()
        linePath.lineWidth = 1.25
        linePath.stroke()

        let lastX = rect.maxX
        let lastY = yFor(percent: latest)
        let dotRect = NSRect(x: lastX - 2.0, y: lastY - 2.0, width: 4.0, height: 4.0)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        color.setFill()
        dotPath.fill()
    }
    #endif
}
