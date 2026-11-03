#!/usr/bin/env python3
"""Linux-side checks for the Clean widget screenshot lane."""

import os
import struct
import tempfile
import unittest
import zlib
import json
import subprocess
from unittest.mock import patch
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


class OCRAndSimulatorBoundaries(unittest.TestCase):
    def test_compile_once_and_execute_prepared_binary_for_multiple_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary, report = Path(tmp) / "ocr", Path(tmp) / "compile.json"
            calls = []
            def run(command, **kwargs):
                calls.append((command, kwargs))
                if "swiftc" in command:
                    binary.write_text("fixture executable")
                    binary.chmod(0o700)
                    return subprocess.CompletedProcess(command, 0, "", "")
                return subprocess.CompletedProcess(command, 0, '["Saved pixel text"]', "")
            checks.prepare_ocr_helper(binary, report, run=run)
            for frame in ("first.png", "second.png"):
                self.assertEqual(checks.recognize_text(frame, run=run, binary=binary), "Saved pixel text")
            self.assertEqual(sum("swiftc" in c for c, _ in calls), 1)
            self.assertEqual([c for c, _ in calls[1:]], [[str(binary), "first.png"], [str(binary), "second.png"]])
            self.assertEqual([k["timeout"] for _, k in calls[1:]], [90, 90])
            metadata = json.loads(report.read_text())
            self.assertTrue(metadata["verified"])
            self.assertEqual(metadata["phase"], "compile")
            self.assertIn("bounded-process.py", calls[0][0][1])

    def test_compilation_failure_is_distinct_and_cannot_leave_stale_binary(self):
        for failure in (subprocess.TimeoutExpired("compiler", 180), subprocess.CalledProcessError(124, "compiler")):
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as tmp:
                binary, report = Path(tmp) / "ocr", Path(tmp) / "compile.json"
                binary.touch()
                def run(command, **kwargs):
                    binary.touch()
                    raise failure
                with self.assertRaisesRegex(RuntimeError, "compilation failed"):
                    checks.prepare_ocr_helper(binary, report, run=run)
                self.assertFalse(binary.exists())
                metadata = json.loads(report.read_text())
                self.assertFalse(metadata["verified"])
                self.assertEqual(metadata["phase"], "compile")

    def test_vision_timeout_is_distinct_from_compilation(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "ocr"
            binary.touch()
            binary.chmod(0o700)
            def run(command, **kwargs):
                raise subprocess.TimeoutExpired(command, kwargs["timeout"])
            with self.assertRaisesRegex(RuntimeError, "Vision OCR execution exceeded 90s"):
                checks.recognize_text("frame.png", run=run, binary=binary)
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "not prepared"):
                checks.recognize_text("frame.png")

    def test_simulator_reuse_readiness_and_shutdown_boot_are_distinct(self):
        for state in ("Booted", "Booting", "Shutdown"):
            with self.subTest(state=state):
                commands = []
                def run(command, **kwargs):
                    commands.append(command)
                    value = json.dumps({"devices": {"iOS": [{"udid": "U", "state": state}]}}) if "list" in command else ""
                    return subprocess.CompletedProcess(command, 0, value, "")
                self.assertIsNone(checks.boot_simulator("U", run=run))
                self.assertEqual(sum("boot" in c for c in commands), int(state == "Shutdown"))
                self.assertEqual(sum("bootstatus" in c for c in commands), 1)
        self.assertEqual(checks.preferred_device(["A", "B"], {"A": "a", "B": "b"}, {"a": "Shutdown", "b": "Booted"}), ["B", "A"])

    def test_simulator_readiness_failure_remains_failure(self):
        def run(command, **kwargs):
            if "list" in command:
                return subprocess.CompletedProcess(command, 0, '{"devices":{"iOS":[{"udid":"U","state":"Booted"}]}}', "")
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
        self.assertIn("timed out", checks.boot_simulator("U", run=run, timeout=420))

    def test_both_job_entrypoints_prepare_once_and_do_not_erase_scene_failures(self):
        for name in ("scripts/capture-app-screenshots.sh", ".github/workflows/screenshots.yml"):
            text = (ROOT / name).read_text()
            self.assertEqual(text.count("--prepare-ocr"), 1)
            self.assertIn("HOGHUNTER_SCREENSHOT_OCR_BINARY", text)
            self.assertIn("boot_simulator", text)
        workflow = (ROOT / ".github/workflows/screenshots.yml").read_text()
        self.assertIn('if [ "$CAPTURE_STATUS" -eq 2 ]', workflow)
        self.assertNotIn('"shutdown", "all"', (ROOT / "scripts/capture-app-screenshots.sh").read_text())


CONFIRMATION = "Clean This Mac? This will safely trigger a Standard Clean on This Mac. An APFS local snapshot will be taken first, and deleted items are moved to Trash. Run Safe Clean"
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

    def test_confirmation_sheet_and_popover_preserve_the_same_safety_proof(self):
        self.assertIsNone(checks.scene_problem("clean-confirmation", CONFIRMATION))
        self.assertIsNone(checks.scene_problem("clean-confirmation", CONFIRMATION + " Cancel"))
        for missing in ("Standard Clean", "snapshot", "moved to Trash", "Run Safe Clean"):
            with self.subTest(missing=missing):
                self.assertIn("missing intended text", checks.scene_problem("clean-confirmation", CONFIRMATION.replace(missing, "")))
        self.assertIn("unexpected alert", checks.scene_problem("clean-confirmation", CONFIRMATION + " Open in Hog Hunter?"))

    def test_clipped_mac_labels_do_not_pass(self):
        full = "Sampling & Display Active Refresh (When Open) Background Refresh (When Closed) Menu Bar Shows Show Percentage in Menu Bar CPU Rows Show"
        self.assertIsNone(checks.scene_problem("mac-settings", full))
        clipped = full.replace("Sampling & Display", "g & Display").replace("Active Refresh", "efresh")
        self.assertIn("missing intended text", checks.scene_problem("mac-settings", clipped))

    def run_capture(self, root, route_text, failure=None, command_failure=None, blank_frame=False, scene_failures=None, commands_sink=None):
        app = root / "App.app"
        (app / "PlugIns" / checks.WIDGET_APPEX_NAME).mkdir(parents=True, exist_ok=True)
        commands = commands_sink if commands_sink is not None else []
        def run(command, **kwargs):
            commands.append(command)
            if command_failure and command_failure in command:
                raise subprocess.CalledProcessError(1, command)
            if "screenshot" in command:
                payload = b"\x00" * 20 if blank_frame else os.urandom(8000)
                Path(command[-1]).write_bytes(png(400, 800, payload))
            return subprocess.CompletedProcess(command, 0, "", "")
        def recognize(path):
            if scene_failures and path.stem in scene_failures:
                raise scene_failures[path.stem]
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

    def test_launch_capture_and_blank_frame_failures_are_recorded(self):
        for failure, blank, stage in [("launch", False, "launch"), ("screenshot", False, "capture"), (None, True, "capture")]:
            with self.subTest(failure=failure, blank=blank), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                with self.assertRaisesRegex(RuntimeError, stage + " failed"):
                    self.run_capture(root, CONFIRMATION, command_failure=failure, blank_frame=blank)
                scenes = json.loads((root / "screens/scene-verification.json").read_text())
                self.assertEqual(len(scenes), 4)
                self.assertFalse(scenes[0]["verified"])
                self.assertEqual(scenes[0]["stage"], stage)
                self.assertEqual(scenes[0]["frame"], "widget-small.png")

    def test_independent_scene_failures_are_collected_before_gate_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            commands = []
            with self.assertRaisesRegex(RuntimeError, "required scenes failed"):
                self.run_capture(root, CONFIRMATION, scene_failures={
                    "widget-small": RuntimeError("OCR denied"),
                    "cleaner-quick": RuntimeError("OCR unavailable"),
                }, commands_sink=commands)
            scenes = json.loads((root / "screens/scene-verification.json").read_text())
            self.assertEqual([x["verified"] for x in scenes], [False, True, False, True])
            self.assertEqual(len([x for x in commands if "screenshot" in x]), 4)
            self.assertFalse(any("openurl" in x for x in commands))
            self.assertTrue(all((root / "screens" / x["frame"]).exists() for x in scenes))
            route = json.loads((root / "screens/deep-link-verification.json").read_text())
            self.assertFalse(route["verified"])
            self.assertIn("not attempted", route["problem"])

    def test_successful_retry_removes_stale_unverified_route_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.run_capture(root, "Open in Hog Hunter? " + CONFIRMATION)
            stale = root / "screens/unverified/clean-deep-link.png"
            self.assertTrue(stale.exists())
            (_, route), _ = self.run_capture(root, CONFIRMATION)
            self.assertTrue(route["verified"])
            self.assertFalse(stale.exists())
            self.assertTrue((root / "screens/clean-deep-link.png").exists())

    def test_failed_retry_cannot_retain_previous_success_or_route_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.run_capture(root, CONFIRMATION)
            with self.assertRaises(RuntimeError):
                self.run_capture(root, CONFIRMATION, command_failure="launch")
            output = root / "screens"
            self.assertFalse(list(output.glob("*.png")))
            route = json.loads((output / "deep-link-verification.json").read_text())
            self.assertFalse(route["verified"])
            self.assertIsNone(route["frame"])
            self.assertIn("not attempted", route["problem"])

    def test_hosted_gate_requires_named_nonempty_server_render(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        command = ci.split("- name: Require server maintenance render\n        run: ")[1].splitlines()[0]
        self.assertIn("hh207-server-maintenance-schedule-off.png", command)
        self.assertIn("hh207-server-maintenance-incomplete-inventory.png", command)
        self.assertIn("HOGHUNTER_RENDER_DIR:", ci)
        self.assertIn("TEST_RUNNER_HOGHUNTER_RENDER_DIR:", ci)
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOGHUNTER_RENDER_DIR=tmp)
            def gate():
                return subprocess.run(["bash", "-c", command], env=env).returncode
            self.assertNotEqual(gate(), 0)
            image = Path(tmp) / "hh207-server-maintenance-schedule-off.png"
            image.touch()
            self.assertNotEqual(gate(), 0)
            image.write_bytes(png(400, 800, os.urandom(8000)))
            self.assertNotEqual(gate(), 0)
            incomplete = Path(tmp) / "hh207-server-maintenance-incomplete-inventory.png"
            incomplete.touch()
            self.assertNotEqual(gate(), 0)
            incomplete.write_bytes(png(400, 800, os.urandom(8000)))
            self.assertEqual(gate(), 0)
            image.unlink()
            self.assertNotEqual(gate(), 0)

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
