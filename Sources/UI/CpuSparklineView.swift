import SwiftUI

/// Micro-sparkline tracking recent machine CPU pressure for the macOS menu bar and header.
struct CpuSparklineView: View {
    let samples: [Double]
    var width: CGFloat = 36
    var height: CGFloat = 14

    var body: some View {
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
    }

    private func yCoordinate(for percent: Double, height: CGFloat) -> CGFloat {
        let clamped = max(0, min(100, percent))
        // Invert Y coordinate so 100% is near the top (with 1pt inset)
        let usableHeight = height - 2
        return (height - 1) - CGFloat(clamped / 100.0) * usableHeight
    }
}
