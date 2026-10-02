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
                .foregroundStyle(.secondary)
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
