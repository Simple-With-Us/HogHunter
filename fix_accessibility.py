import re

with open('ios/Widgets/HogHunterWidgets.swift', 'r') as f:
    content = f.read()

# Small widget CPU
content = re.sub(
    r'(// CPU\n *VStack\(alignment: \.leading, spacing: 2\) \{\n *HStack \{\n.*?\n.*?\n.*?\n.*?\n *\}\n *ProgressView.*?\n *\.tint.*?\n *\})',
    r'\1\n                .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

# Small widget RAM
content = re.sub(
    r'(// Memory\n *VStack\(alignment: \.leading, spacing: 2\) \{\n *HStack \{\n.*?\n.*?\n.*?\n.*?\n.*?\n *\}\n *ProgressView.*?\n *\.tint.*?\n *\})',
    r'\1\n                .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

# Medium widget CPU
content = re.sub(
    r'(// CPU\n *VStack\(alignment: \.leading, spacing: 1\) \{\n *HStack \{\n.*?\n.*?\n.*?\n.*?\n *\}\n *ProgressView.*?\n *\.tint.*?\n *\})',
    r'\1\n                        .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

# Medium widget RAM
content = re.sub(
    r'(// Memory\n *VStack\(alignment: \.leading, spacing: 1\) \{\n *HStack \{\n.*?\n.*?\n.*?\n.*?\n.*?\n *\}\n *ProgressView.*?\n *\.tint.*?\n *\})',
    r'\1\n                        .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

# Large widget CPU
content = re.sub(
    r'(VStack\(alignment: \.leading, spacing: 3\) \{\n *Text\("CPU"\).*?\n.*?\n.*?\n *ProgressView.*?\n *\.tint.*?\n *Text\(snap\.pulse\.cpuCaption\).*?\n.*?\n.*?\n *\}\n *\.padding\(8\)\n *\.frame\(maxWidth: \.infinity, alignment: \.leading\)\n *\.background\(Color\.primary\.opacity\(0\.04\), in: RoundedRectangle\(cornerRadius: 8\)\))',
    r'\1\n                    .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

# Large widget RAM
content = re.sub(
    r'(VStack\(alignment: \.leading, spacing: 3\) \{\n *Text\("Memory"\).*?\n.*?\n.*?\n.*?\n *ProgressView.*?\n *\.tint.*?\n *Text\(snap\.pulse\.swapText \?\? snap\.pulse\.memoryCaption\).*?\n.*?\n.*?\n *\}\n *\.padding\(8\)\n *\.frame\(maxWidth: \.infinity, alignment: \.leading\)\n *\.background\(Color\.primary\.opacity\(0\.04\), in: RoundedRectangle\(cornerRadius: 8\)\))',
    r'\1\n                    .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

# Top Hog row in Large widget
content = re.sub(
    r'(ForEach\(snap\.rows\.prefix\(3\)\) \{ row in\n *HStack\(spacing: 6\) \{\n.*?\n.*?\n.*?\n.*?\n *Text\(row\.name\).*?\n.*?\n.*?\n *Spacer\(\)\n *Text\(row\.cpuText\).*?\n.*?\n.*?\n *Text\(row\.memoryText\).*?\n.*?\n.*?\n *\})',
    r'\1\n                            .accessibilityElement(children: .combine)',
    content,
    flags=re.DOTALL
)

with open('ios/Widgets/HogHunterWidgets.swift', 'w') as f:
    f.write(content)

