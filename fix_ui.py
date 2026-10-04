import re

def process_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Replacements for font sizes
    replacements = [
        (r'\.font\(\.system\(size: 44\)\)', r'.font(.largeTitle)'),
        (r'\.font\(\.system\(size: 10\)\)', r'.font(.caption)'),
        (r'\.font\(\.system\(size: 8, weight: \.bold\)\)', r'.font(.caption2.weight(.bold))'),
        (r'\.font\(\.system\(size: 18\)\)', r'.font(.title3)'),
        (r'\.font\(\.system\(size: 9, weight: \.bold\)\)', r'.font(.caption2.weight(.bold))'),
        (r'\.font\(\.system\(size: 11, weight: \.semibold, design: \.monospaced\)\)', r'.font(.system(.footnote, design: .monospaced).weight(.semibold))'),
        (r'\.font\(\.system\(size: 10, weight: \.semibold, design: \.monospaced\)\)', r'.font(.system(.caption, design: .monospaced).weight(.semibold))'),
        (r'\.font\(\.system\(size: 8\)\)', r'.font(.caption2)'),
        (r'\.font\(\.system\(size: 9, weight: \.medium\)\)', r'.font(.caption2.weight(.medium))'),
        (r'\.font\(\.system\(size: 9, weight: \.semibold\)\)', r'.font(.caption2.weight(.semibold))'),
        (r'\.font\(\.system\(size: 11, weight: \.bold, design: \.monospaced\)\)', r'.font(.system(.footnote, design: .monospaced).weight(.bold))'),
        (r'\.font\(\.system\(size: 10, weight: \.bold, design: \.monospaced\)\)', r'.font(.system(.caption, design: .monospaced).weight(.bold))'),
        (r'\.font\(\.system\(size: 9\)\)', r'.font(.caption2)'),
        (r'\.font\(\.system\(size: 11, weight: \.semibold\)\)', r'.font(.footnote.weight(.semibold))'),
        (r'\.font\(\.system\(size: 11\)\)', r'.font(.footnote)'),
        (r'\.font\(\.system\(size: 10, weight: \.semibold\)\)', r'.font(.caption.weight(.semibold))'),
    ]

    for p, r in replacements:
        content = re.sub(p, r, content)

    # Accessibility grouping in Widgets
    # We want to add .accessibilityElement(children: .combine) to the VStack for CPU and RAM
    # In small widget:
    content = content.replace(
        '.scaleEffect(x: 1, y: 0.6, anchor: .center)',
        ''
    )

    with open(filepath, 'w') as f:
        f.write(content)

process_file('ios/Sources/CompanionViews.swift')
process_file('ios/Widgets/HogHunterWidgets.swift')
