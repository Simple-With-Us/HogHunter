import SwiftUI

/// Custom segmented-toggle row used by the Mac Activity panel.
///
/// Replaces `Picker` with `.pickerStyle(.segmented)` for the Window / Show /
/// Sort rows.  The stock segmented picker pads every segment to the widest
/// one, which makes short labels like "Now" feel hollow inside the row and
/// wastes the room "Past 24 Hours" needs.  This view gives every segment
/// the same L/R internal padding (8 pt) so the spacing feels even, lets
/// "Now" stay narrower than its neighbours, and matches the height of the
/// adjacent sort-direction button.
struct SegmentedToggleGroup<Selection: Hashable, Label: View>: View {
    let options: [Selection]
    let label: (Selection) -> Label
    @Binding var selection: Selection
    /// Background color used for the selected segment.  Defaults to the
    /// system selection tint so light and dark themes follow the user's
    /// accent preference without extra wiring.
    var selectedBackground: Color = Color.accentColor.opacity(0.18)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option
                } label: {
                    label(option)
                        .font(.system(size: 11, weight: selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(minHeight: 21)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selection == option ? selectedBackground : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }
}