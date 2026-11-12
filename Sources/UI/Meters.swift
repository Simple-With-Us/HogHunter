import AppKit
import SwiftUI

/// A headline number: a labeled bar, tinted by severity, with a caption under
/// it.  The whole thing reads as one element to VoiceOver: the title is the
/// label and the caption is the value.
struct Meter: View {
    let title: String
    /// 0-100.  Values outside the range are clamped for the bar.
    let value: Double
    let caption: String
    let severity: Severity
    /// Spoken instead of `caption` when the visible caption is abbreviated.
    var accessibilityDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            ProgressView(value: min(max(value / 100, 0), 1))
                .tint(severity.color)
            Text(caption)
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityDetail ?? caption)
    }
}

/// A secondary fact that sits under a meter: swap, memory pressure, thermal
/// state.  Small, tinted by severity, and never competing with the meter.
struct MeterPill: View {
    let text: String
    var severity: Severity = .calm
    var help: String?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            // A pill is one fact on one line.  Without `fixedSize` the Text
            // takes the width it is offered and wraps "16.9 GB swapped" into
            // two ragged lines inside a two-line-tall box, which is where the
            // "lazily arranged" look came from.
            .fixedSize(horizontal: true, vertical: false)
            .multilineTextAlignment(.center)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 0.5)
            )
            .help(help ?? text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    /// Calm facts stay neutral; only a warning earns a color.
    private var tint: Color {
        severity == .calm ? Color.secondary : severity.color
    }

    private var fill: Color {
        severity == .calm ? Color.primary.opacity(0.06) : severity.color.opacity(0.12)
    }
}

/// Lays subviews out left to right and starts a new line when the next one
/// would not fit.
///
/// `HStack` has no wrapping mode, so a set of pills that outgrows the panel has
/// historically been handled by squeezing the window, clipping, or letting a
/// wrapped `HStack` spill over the row below it.  This measures every subview
/// at its own ideal width, fills lines in order, and reports the true height,
/// so three pills either sit on one even row or break into two even rows --
/// never a ragged edge.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    /// One origin per subview, in order, plus the size they were laid out at.
    struct Cache {
        var origins: [CGPoint]
        var size: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(origins: Array(repeating: .zero, count: subviews.count), size: .zero)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let available = proposal.width ?? .greatestFiniteMagnitude
        var origins: [CGPoint] = []
        origins.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > available {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }

        cache = Cache(origins: origins, size: CGSize(width: widest, height: y + lineHeight))
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (index, subview) in subviews.enumerated() where index < cache.origins.count {
            subview.place(
                at: CGPoint(x: bounds.minX + cache.origins[index].x, y: bounds.minY + cache.origins[index].y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }
}

/// A short status label.  System orange and green fail WCAG AA as text, so
/// the ink and the fill are chosen to stay above 4.5:1 in light and dark.
struct ContrastChip: View {
    enum Tone { case neutral, caution, notice }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.ink(tone))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.wash(tone)))
    }

    private static func ink(_ tone: Tone) -> Color { color(tone, text: true) }
    private static func wash(_ tone: Tone) -> Color { color(tone, text: false) }

    private static func color(_ tone: Tone, text: Bool) -> Color {
        let pair = pairs(tone, text: text)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }))
    }

    private static func pairs(_ tone: Tone, text: Bool) -> (light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) {
        switch (tone, text) {
        case (.neutral, true): return ((0.04, 0.24, 0.51), (0.77, 0.87, 1.0))
        case (.neutral, false): return ((0.89, 0.93, 0.98), (0.06, 0.14, 0.24))
        case (.caution, true): return ((0.45, 0.24, 0.0), (1.0, 0.86, 0.62))
        case (.caution, false): return ((1.0, 0.93, 0.82), (0.28, 0.18, 0.08))
        case (.notice, true): return ((0.0, 0.36, 0.16), (0.72, 0.94, 0.78))
        case (.notice, false): return ((0.85, 0.95, 0.89), (0.05, 0.16, 0.09))
        }
    }
}
