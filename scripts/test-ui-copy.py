#!/usr/bin/env python3
"""User-facing copy must stay plain.  No Mac or phone build is launched."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

SCAN_ROOTS = [
    ROOT / "Sources" / "UI",
    ROOT / "ios" / "Sources",
    ROOT / "ios" / "Widgets",
]
SCAN_FILES = [
    ROOT / "Sources" / "Store" / "HogStore.swift",
    ROOT / "Sources" / "Network" / "NetworkScanner.swift",
    ROOT / "Sources" / "Storage" / "DiskCleaner.swift",
    ROOT / "Sources" / "Storage" / "DiskCleanerStore.swift",
    ROOT / "Sources" / "Storage" / "TempFileSafetyPolicy.swift",
    ROOT / "Sources" / "Companion" / "CompanionSnapshot.swift",
]

# Phrases that named tools, shouted, or used internal scheduling words.
FORBIDDEN = (
    "Sampling behind",
    "Reading lsof",
    "Explore Demo Mode",
    "App Review",
    "TAMED",
    "EXTREME ONLY",
    "FROM IPHONE",
    "Minimum Untouched Time",
    "nice priority",
    "background QoS",
    "Creating APFS safety snapshot",
    "Deep / AI Artifacts",
    "Open companion",
    "lsof snapshot",
    "lsof denied",
    "lsof binary",
    "private APIs",
)


def swift_strings(text):
    """Yield the contents of Swift string literals, skipping comments."""
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            if end < 0:
                return
            yield text[i + 3:end]
            i = end + 3
            continue
        if text[i] == '"':
            j = i + 1
            chars = []
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    chars.append(text[j:j + 2])
                    j += 2
                    continue
                if text[j] == '"':
                    break
                chars.append(text[j])
                j += 1
            yield "".join(chars)
            i = j + 1
            continue
        i += 1


def scanned_files():
    files = list(SCAN_FILES)
    for root in SCAN_ROOTS:
        files.extend(sorted(root.rglob("*.swift")))
    return files


class UICopyTests(unittest.TestCase):
    def test_user_facing_strings_drop_internal_words(self):
        hits = []
        for path in scanned_files():
            literals = "\n".join(swift_strings(path.read_text(encoding="utf-8")))
            for phrase in FORBIDDEN:
                if phrase in literals:
                    hits.append(f"{path.relative_to(ROOT)}: {phrase}")
        self.assertEqual(hits, [])

    def test_safety_copy_progress_is_not_detected_by_the_word_snapshot(self):
        cleaner = (ROOT / "Sources" / "Storage" / "DiskCleaner.swift").read_text(encoding="utf-8")
        self.assertIn('static let safetyCopyProgressMark = "Saving a safety copy"', cleaner)
        self.assertIn('static let thinningSnapshotsProgressTitle = "Thinning APFS local snapshots…"', cleaner)
        self.assertIn("isSafetyCopyProgress(title) || title == thinningSnapshotsProgressTitle", cleaner)
        for relative, predicate in (
            ("Sources/Storage/DiskCleanerStore.swift", "DiskCleaner.isSnapshotProgress"),
            ("Sources/Store/HogStore.swift", "DiskCleaner.isSnapshotProgress"),
            ("Sources/UI/DiskCleanerView.swift", "DiskCleaner.isSafetyCopyProgress"),
        ):
            text = (ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn('.contains("snapshot")', text, relative)
            self.assertIn(predicate, text, relative)

    def test_snapshot_reporters_keep_milestones_in_snapshot_phase(self):
        for relative, title in (
            ("Sources/Storage/DiskCleanerStore.swift", "currentItem"),
            ("Sources/Store/HogStore.swift", "itemTitle"),
        ):
            text = (ROOT / relative).read_text(encoding="utf-8")
            self.assertIn(f'phase: DiskCleaner.isSnapshotProgress({title}) ? "snapshot"', text, relative)
            self.assertIn(f'statusText: DiskCleaner.isSnapshotProgress({title}) ? {title} :', text, relative)

    def test_connection_list_errors_stay_plain_and_match_the_unit_tests(self):
        text = (ROOT / "Sources" / "Network" / "NetworkScanner.swift").read_text(encoding="utf-8")
        literals = "\n".join(swift_strings(text))
        self.assertIn("The connection list is missing.", literals)
        self.assertIn("macOS denied the connection list.", literals)
        lowered = literals.lower()
        for phrase in ("lsof denied", "lsof binary", "lsof exit", "lsof parse"):
            self.assertNotIn(phrase, lowered)

    def test_demo_banner_uses_the_sentence_gap(self):
        text = (ROOT / "ios" / "Sources" / "CompanionViews.swift").read_text(encoding="utf-8")
        self.assertIn('Text("Sample data.\\u{00A0} This is not your Mac.")', text)
        self.assertNotIn('Text("Sample data. This is not your Mac.")', text)


if __name__ == "__main__":
    unittest.main()
