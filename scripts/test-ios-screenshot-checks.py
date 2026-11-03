#!/usr/bin/env python3
"""Linux-side checks for the Clean widget screenshot lane."""

import os
import struct
import tempfile
import unittest
import zlib
import json
import subprocess
from pathlib import Path

import ios_screenshot_checks as checks
from ios_capture_scenes import capture_scenes

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
            "widget_appex_present",
            "capture_scenes",
            "screenshot_problem",
        ):
            self.assertIn(needle, script)
        workflow = (ROOT / ".github" / "workflows" / "screenshots.yml").read_text()
        self.assertIn('python3 scripts/ios_capture_scenes.py', workflow)
        self.assertIn("xcrun simctl io", workflow)
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("scripts/test-ios-screenshot-checks.py", ci)
        self.assertIn("scripts/capture-app-screenshots.sh", ci)


CONFIRMATION = "Clean This Mac? Run Safe Clean Cancel"
QUICK = "Disk Cleaner 9.8 GB estimated to move or remove Rescan Clean Selected"
PARTIAL = "Disk Cleaner Partial scan; listed sizes are lower bounds Scan Deeper Clean Selected"


class SceneChecks(unittest.TestCase):
    def test_intended_scene_and_alert_overlay_are_both_checked(self):
        for scene, text in [("clean-confirmation", CONFIRMATION), ("cleaner-quick", QUICK), ("cleaner-partial", PARTIAL)]:
            self.assertIsNone(checks.scene_problem(scene, text))
            for overlay in ['Open in “Hog Hunter”? Cancel Open', "The Mac Did Not Accept That", "Hog Hunter Would Like To Find Devices on Your Local Network", "Local Network Access Allow Don't Allow"]:
                self.assertIn("unexpected alert", checks.scene_problem(scene, text + "\n" + overlay))
        self.assertIn("missing intended text", checks.scene_problem("cleaner-partial", QUICK))
        self.assertIn("missing intended text", checks.scene_problem("clean-confirmation", "Hog Hunter Activity CPU Memory"))
        with self.assertRaises(ValueError):
            checks.scene_problem("unknown", QUICK)

    def test_clipped_mac_labels_do_not_pass(self):
        full = "Sampling & Display Active Refresh (When Open) Background Refresh (When Closed) Menu Bar Shows Show Percentage in Menu Bar CPU Rows Show"
        self.assertIsNone(checks.scene_problem("mac-settings", full))
        clipped = full.replace("Sampling & Display", "g & Display").replace("Active Refresh", "efresh")
        self.assertIn("missing intended text", checks.scene_problem("mac-settings", clipped))

    def run_capture(self, root, route_text, failure=None):
        app = root / "App.app"
        (app / "PlugIns" / checks.WIDGET_APPEX_NAME).mkdir(parents=True)
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            if "screenshot" in command:
                Path(command[-1]).write_bytes(png(400, 800, os.urandom(8000)))
            return subprocess.CompletedProcess(command, 0, "", "")
        def recognize(path):
            if failure:
                raise failure
            return {"widget-small": "Hog Hunter Widget CPU RAM Clean Mac", "clean-cold-start": CONFIRMATION, "cleaner-quick": QUICK, "cleaner-partial": PARTIAL, "clean-deep-link": route_text}[path.stem]
        result = capture_scenes("UDID", "test.fixture", app, root / "screens", run=run, settle=lambda _: None, recognize=recognize)
        return result, commands

    def test_unaccepted_url_prompt_is_segregated_and_attempted_last(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (scenes, route), commands = self.run_capture(root, 'Open in “Hog Hunter”? Cancel Open ' + CONFIRMATION)
            self.assertTrue(all(item["verified"] for item in scenes))
            self.assertFalse(route["verified"])
            self.assertEqual(route["frame"], "unverified/clean-deep-link.png")
            self.assertFalse((root / "screens/clean-deep-link.png").exists())
            open_index = next(i for i, command in enumerate(commands) if "openurl" in command)
            self.assertFalse(any("launch" in command for command in commands[open_index + 1:]))
            self.assertFalse(json.loads((root / "screens/deep-link-verification.json").read_text())["verified"])

    def test_url_destination_is_only_verified_with_observed_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            (_, route), _ = self.run_capture(Path(tmp), CONFIRMATION)
            self.assertTrue(route["verified"])
            self.assertEqual(route["frame"], "clean-deep-link.png")

    def test_unknown_ocr_fails_required_scene_and_records_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(RuntimeError, "OCR unavailable"):
                self.run_capture(root, CONFIRMATION, failure=RuntimeError("access denied"))
            scenes = json.loads((root / "screens/scene-verification.json").read_text())
            self.assertFalse(scenes[-1]["verified"])
            self.assertIn("access denied", scenes[-1]["problem"])

    def test_sample_safety_and_shared_mac_size_contract(self):
        model = (ROOT / "ios/Sources/CompanionModel.swift").read_text()
        sample = model.split('if ProcessInfo.processInfo.arguments.contains("-HogHunterSample") {')[1].split('saved = loadSaved()')[0]
        self.assertIn('isDemoMode = true', sample)
        reachability = model.split('var controlsReachable: Bool {')[1].split('return CompanionPeer.isTrustedEndpoint')[0]
        self.assertIn('if isDemoMode && ProcessInfo.processInfo.arguments.contains("-HogHunterSample")', reachability)
        self.assertIn('guard let saved, let endpoint', reachability)
        harness = (ROOT / "Sources/App/HogHunterApp.swift").read_text().split('presenting Settings NSWindow directly')[1].split('@main')[0]
        self.assertIn('SettingsView.windowWidth', harness)
        self.assertIn('SettingsView.windowHeight', harness)
        self.assertNotIn('width: 560', harness)


if __name__ == "__main__":
    unittest.main()
