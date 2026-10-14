#!/usr/bin/env python3
"""Linux-side checks for the Clean widget screenshot lane."""

import os
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

import ios_screenshot_checks as checks

ROOT = Path(__file__).resolve().parents[1]


def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def png(width, height, idat):
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


class FrameChecks(unittest.TestCase):
    def test_blank_and_real_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            blank = Path(tmp) / "blank.png"
            real = Path(tmp) / "real.png"
            small = Path(tmp) / "small.png"
            junk = Path(tmp) / "junk.png"
            blank.write_bytes(png(400, 800, b"\x00" * 20))
            # Incompressible payload, above the 0.003 ratio for 400x800.
            real.write_bytes(png(400, 800, os.urandom(8000)))
            small.write_bytes(png(20, 20, os.urandom(400)))
            junk.write_bytes(b"not a png")
            self.assertIn("looks blank", checks.screenshot_problem(str(blank)))
            self.assertIsNone(checks.screenshot_problem(str(real)))
            self.assertIn("unexpected size", checks.screenshot_problem(str(small)))
            self.assertEqual(checks.screenshot_problem(str(junk)), "not a PNG")

    def test_missing_file(self):
        problem = checks.screenshot_problem("/tmp/hoghunter-no-such-screenshot.png")
        self.assertTrue(problem.startswith("unreadable:"))

    def test_widget_appex_detection(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "HogHunter.app"
            appex = app / "PlugIns" / "HogHunterWidgets.appex"
            appex.mkdir(parents=True)
            (appex / "Info.plist").write_text("widget")
            self.assertTrue(checks.widget_appex_present(str(app)))
            self.assertFalse(checks.widget_appex_present(str(Path(tmp) / "missing.app")))

    def test_clean_commands_match_the_review(self):
        self.assertEqual(
            checks.clean_openurl_command("BOOTED-UDID"),
            ["xcrun", "simctl", "openurl", "BOOTED-UDID", "hoghunter://clean"],
        )
        self.assertEqual(
            checks.screenshot_command("BOOTED-UDID", "screenshots/ios/clean-deep-link.png"),
            ["xcrun", "simctl", "io", "BOOTED-UDID", "screenshot", "screenshots/ios/clean-deep-link.png"],
        )
        self.assertIn("-HogHunterWidgetPreview", checks.WIDGET_PREVIEW_LAUNCH_ARGS)
        self.assertIn("-HogHunterCleanConfirm", checks.COLD_CLEAN_LAUNCH_ARGS)
        self.assertEqual(checks.WARM_CLEAN_LAUNCH_ARGS, ["-HogHunterSample"])

    def test_capture_script_uses_the_commands(self):
        script = (ROOT / "scripts" / "capture-app-screenshots.sh").read_text()
        for needle in (
            "clean_openurl_command",
            "screenshot_command",
            "widget_appex_present",
            "capture_required_frames",
            "screenshot_problem",
        ):
            self.assertIn(needle, script)
        workflow = (ROOT / ".github" / "workflows" / "screenshots.yml").read_text()
        self.assertIn('xcrun simctl openurl "$UDID" "hoghunter://clean"', workflow)
        self.assertIn("xcrun simctl io", workflow)
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("scripts/test-ios-screenshot-checks.py", ci)
        self.assertIn("scripts/capture-app-screenshots.sh", ci)


if __name__ == "__main__":
    unittest.main()
