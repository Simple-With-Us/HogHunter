import AppKit

/// Light or dark chrome for a menu-bar bitmap.
///
/// Calm drawings are template images, so they pick up the menu bar tint when
/// AppKit draws them.  Severity colours are fixed RGB and are baked for the
/// appearance in force when the picture last changed.
enum MenuBarChrome: Equatable {
    case light
    case dark

    static var current: MenuBarChrome {
        let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    var nsAppearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

/// Whole numbers the status item actually shows.  A fraction of a percent
/// does not move a bar that is only a few points tall, and it must not mint
/// a new bitmap.
enum MenuBarQuantize {
    /// The history-bar percent text.  Matches `String(format: "%.0f")` on the
    /// 0...999 value the menu-bar image has always drawn.
    static func displayedPercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(999, max(0, value)).rounded())
    }

    /// 0...100, for a bar or a sparkline vertex.
    static func unit(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(100, max(0, value)).rounded())
    }

    static func historyBars(_ history: CpuMinuteHistory, at date: Date) -> [Int?] {
        history.bars(at: date).suffix(14).map { $0.map(unit) }
    }

    static func sparkline(_ samples: [Double]) -> [Int] {
        samples.suffix(30).map(unit)
    }
}

/// What the menu bar is showing, after quantization.  Equal pictures share
/// one image.
struct MenuBarPicture: Equatable {
    enum Graphic: Equatable {
        case historyBars(percent: Int, bars: [Int?], showPercent: Bool)
        case sparkline(samples: [Int], showIcon: Bool)
        /// Machine CPU and Top Hog are text, not a generated bitmap.
        case none

        /// True when a calm template image cannot carry this drawing.
        /// Hot and elevated colours are fixed RGB, and the hog icon is too.
        var bakesAppearance: Bool {
            switch self {
            case .none:
                return false
            case .sparkline(let samples, let showIcon):
                if showIcon { return true }
                return Severity.forMachineCpu(Double(samples.last ?? 0)) != .calm
            case .historyBars(let percent, let bars, let showPercent):
                if showPercent, Severity.forMachineCpu(Double(percent)) != .calm { return true }
                return bars.contains { bar in
                    guard let bar else { return false }
                    return Severity.forMachineCpu(Double(bar)) != .calm
                }
            }
        }
    }

    var mode: MenuBarLabelMode
    var graphic: Graphic
    var appearance: MenuBarChrome
    var label: String
    var showIcon: Bool
    var showPercent: Bool
    var help: String
    var accessibility: String

    static func capture(
        mode: MenuBarLabelMode,
        showIcon: Bool,
        showPercent: Bool,
        cpuPercent: Double,
        history: CpuMinuteHistory,
        samples: [Double],
        label: String,
        help: String,
        accessibility: String,
        at date: Date,
        appearance: MenuBarChrome
    ) -> MenuBarPicture {
        let graphic: Graphic
        switch mode {
        case .historyBars:
            graphic = .historyBars(
                percent: MenuBarQuantize.displayedPercent(cpuPercent),
                bars: MenuBarQuantize.historyBars(history, at: date),
                showPercent: showPercent
            )
        case .sparkline:
            graphic = .sparkline(samples: MenuBarQuantize.sparkline(samples), showIcon: showIcon)
        case .machinePercent, .topHogName:
            graphic = .none
        }
        return MenuBarPicture(
            mode: mode,
            graphic: graphic,
            appearance: appearance,
            label: label,
            showIcon: showIcon,
            showPercent: showPercent,
            help: help,
            accessibility: accessibility
        )
    }
}

/// A status-bar bitmap, never a drawing-handler image.
///
/// `NSStatusItem` snapshots its button on the main thread and frees the
/// previous snapshot there (`HOGHUNTER-6`).  A drawing-handler image is
/// re-rendered into whatever rect the replicant asks for, which is how a
/// menu-bar refresh became a multi-megabyte `munmap`.  This helper allocates
/// one 2x bitmap at the point size it is given, and refuses anything larger
/// than a menu-bar image.
enum MenuBarBitmap {
    static let scale: CGFloat = 2
    /// Wide enough for the hog-and-sparkline image, short enough for the bar.
    static let maxPointSize = NSSize(width: 256, height: 64)

    static func rasterize(
        size: NSSize,
        appearance: MenuBarChrome,
        draw: (NSRect) -> Void
    ) -> NSImage {
        let clamped = NSSize(
            width: min(max(1, size.width), maxPointSize.width),
            height: min(max(1, size.height), maxPointSize.height)
        )
        let pixelsWide = max(1, Int((clamped.width * scale).rounded()))
        let pixelsHigh = max(1, Int((clamped.height * scale).rounded()))
        let image = NSImage(size: clamped)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        rep.size = clamped

        let previousAppearance = NSAppearance.current
        NSAppearance.current = appearance.nsAppearance
        defer { NSAppearance.current = previousAppearance }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.current = graphics
        // Some bitmap contexts are already in points (one unit equals
        // `scale` pixels).  Others are in pixels.  Scale only the pixel ones
        // so a point-space drawing fills this rep exactly once.
        let ctm = graphics.cgContext.ctm
        let unitsToPixels = (ctm.a * ctm.a + ctm.b * ctm.b).squareRoot()
        if unitsToPixels < scale * 0.75 {
            let factor = scale / max(unitsToPixels, 1)
            graphics.cgContext.scaleBy(x: factor, y: factor)
        }
        draw(NSRect(origin: .zero, size: clamped))
        graphics.flushGraphics()

        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
