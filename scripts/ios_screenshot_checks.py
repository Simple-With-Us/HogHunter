#!/usr/bin/env python3
"""Checks the iOS screenshot lane can share with CI and with a Linux test.

The macOS runner still has to boot a simulator.  This module is the part
that does not: how a captured PNG is judged, and the exact simctl commands
the Clean widget lane must run.
"""

import os
import argparse
import hashlib
import time
import sys
import json
import re
import subprocess
import struct
import zlib
from pathlib import Path

# A solid-colour frame compresses to ~0.1% of its raw size; a rendered screen
# is an order of magnitude above this.
MIN_COMPRESSED_RATIO = 0.003

CLEAN_URL = "hoghunter://clean"
WIDGET_APPEX_NAME = "HogHunterWidgets.appex"
WIDGET_PREVIEW_LAUNCH_ARGS = ["-HogHunterSample", "-HogHunterWidgetPreview"]
COLD_CLEAN_LAUNCH_ARGS = ["-HogHunterSample", "-HogHunterCleanConfirm"]
WARM_CLEAN_LAUNCH_ARGS = ["-HogHunterSample"]
CLEANER_LAUNCH_ARGS = ["-HogHunterSample", "-HogHunterCleaner"]
PARTIAL_CLEANER_LAUNCH_ARGS = CLEANER_LAUNCH_ARGS + ["-HogHunterCleanerPartial"]

REQUIRED_FRAMES = (
    "screenshots/ios/widget-small.png",
    "screenshots/ios/clean-cold-start.png",
    "screenshots/ios/cleaner-quick.png",
    "screenshots/ios/cleaner-partial.png",
)


OCR_COMPILE_TIMEOUT_S = 180
OCR_EXECUTION_TIMEOUT_S = 90


def prepare_ocr_helper(binary, report, run=subprocess.run):
    """Compile the trusted Vision source once, separately from image execution."""
    helper = Path(__file__).with_name("screenshot-text.swift")
    binary, report = Path(binary), Path(report)
    binary.parent.mkdir(parents=True, exist_ok=True)
    report.parent.mkdir(parents=True, exist_ok=True)
    binary.unlink(missing_ok=True)
    started = time.monotonic()
    result = {"phase": "compile", "verified": False,
              "sourceSHA256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "timeoutSeconds": OCR_COMPILE_TIMEOUT_S}
    try:
        supervisor = Path(__file__).with_name("bounded-process.py")
        run([sys.executable, str(supervisor), "--timeout", str(OCR_COMPILE_TIMEOUT_S),
             "--grace", "2", "--", "xcrun", "swiftc", str(helper), "-o", str(binary)],
            capture_output=True, text=True, timeout=OCR_COMPILE_TIMEOUT_S + 15, check=True)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError("compiler did not produce an executable")
        result["verified"] = True
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        result["problem"] = "OCR helper compilation failed: " + str(error)
        binary.unlink(missing_ok=True)
        raise RuntimeError(result["problem"]) from error
    finally:
        result["elapsedSeconds"] = round(time.monotonic() - started, 3)
        report.write_text(json.dumps(result, indent=2) + "\n")
    return binary


def recognize_text(path, run=subprocess.run, binary=None):
    """Run the prepared Vision binary on saved pixels; never compile per frame."""
    binary = binary or os.environ.get("HOGHUNTER_SCREENSHOT_OCR_BINARY")
    if not binary or not Path(binary).is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError("OCR helper not prepared; compile it once before capture")
    try:
        result = run([str(binary), str(path)], capture_output=True, text=True,
                     timeout=OCR_EXECUTION_TIMEOUT_S, check=True)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Vision OCR execution exceeded {OCR_EXECUTION_TIMEOUT_S}s") from error
    lines = json.loads(result.stdout)
    if not isinstance(lines, list) or not all(isinstance(line, str) for line in lines):
        raise ValueError("invalid screenshot OCR response")
    return "\n".join(lines)


def boot_simulator(udid, run=subprocess.run, timeout=420):
    """Reuse a booted/booting device and verify readiness without a second boot."""
    stage, budget = "device listing", 30
    try:
        listing = run(["xcrun", "simctl", "list", "-j", "devices", "available"],
                      capture_output=True, text=True, timeout=30, check=True)
        devices = [d for group in json.loads(listing.stdout)["devices"].values() for d in group]
        state = next((d.get("state") for d in devices if d.get("udid") == udid), None)
        if state not in ("Booted", "Booting"):
            stage, budget = "boot request", 30
            boot = run(["xcrun", "simctl", "boot", udid], capture_output=True, text=True, timeout=30)
            if boot.returncode != 0 and "current state: Booted" not in (boot.stderr or ""):
                return "boot failed: " + (boot.stderr or boot.stdout or str(boot.returncode)).strip()
        stage, budget = "bootstatus", timeout
        status = run(["xcrun", "simctl", "bootstatus", udid, "-b"],
                     capture_output=True, text=True, timeout=timeout)
        if status.returncode != 0:
            return "bootstatus failed: " + (status.stderr or status.stdout or str(status.returncode)).strip()
    except subprocess.TimeoutExpired:
        return f"{stage} timed out after {budget}s"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        return "simulator readiness unavailable: " + str(error)
    return None


def preferred_device(candidates, available_devices, device_states):
    """Prefer an already booted compatible device without changing its format."""
    return sorted(candidates, key=lambda name: device_states.get(available_devices.get(name)) != "Booted")


def scene_problem(scene, text):
    """Require the intended view and reject known OS/network alert overlays."""
    normalized = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
    for alert in ("open in", "the mac did not accept that", "looking for your mac", "not connected to your mac", "could not connect", "would like to", "don t allow", "local network access", "access your local network"):
        if alert in normalized:
            return "unexpected alert: " + alert
    required = {
        "widget-preview": ("hog hunter widget", "cpu", "ram", "clean mac"),
        # Confirmation dialogs can use a dismiss-outside popover with no Cancel
        # row.  Require the real safety explanation, title and destructive action.
        "clean-confirmation": ("clean this mac", "run safe clean", "standard clean", "snapshot", "moved to trash"),
        "cleaner-quick": ("disk cleaner", "estimated to move or remove", "rescan", "clean selected"),
        "cleaner-partial": ("disk cleaner", "partial scan", "lower bounds", "scan deeper", "clean selected"),
        "cleaner-extreme": ("disk cleaner", "extreme clean", "estimated to move or remove", "rescan"),
        "issue-actions": ("flagged issues", "runaway cpu hog", "quit", "clean", "retry"),
        # The Server tab's sections (HH-224).  The details and controls frames
        # start the Overview further down; the others show the picker.
        "server-details": ("server disks", "memory backed", "app databases"),
        "server-controls": ("top server processes", "coolify workloads", "protected database"),
        "server-activity": ("overview", "activity", "storage", "maintenance", "server activity", "paging activity"),
        "server-storage": ("overview", "maintenance", "server disks", "memory backed", "app databases"),
        "server-maintenance": ("overview", "activity", "include in mac maintenance", "server maintenance", "package cache"),
        # The scan and run buttons sit below the switch, so this frame leaves the switch out.
        "server-scan": ("overview", "maintenance", "server maintenance", "package cache", "scan server", "run server maintenance"),
        "mac-settings": ("sampling display", "active refresh when open", "background refresh when closed", "menu bar shows", "show percentage in menu bar", "cpu rows show"),
    }
    if scene not in required:
        raise ValueError("unknown screenshot scene: " + scene)
    missing = [phrase for phrase in required[scene] if phrase not in normalized]
    return "missing intended text: " + ", ".join(missing) if missing else None


def clean_openurl_command(udid):
    """Open the Clean pill's URL on a booted simulator (`simctl openurl`)."""
    return ["xcrun", "simctl", "openurl", udid, CLEAN_URL]


def screenshot_command(udid, path):
    """`xcrun simctl io <udid> screenshot`.  The udid is the booted device.

    `simctl io booted` is ambiguous when the runner has more than one
    simulator, so the lane passes that booted device's udid.
    """
    return ["xcrun", "simctl", "io", udid, "screenshot", path]


def widget_appex_present(app_path):
    """The built .app embeds the widget extension the lane installs."""
    if not app_path or not os.path.isdir(app_path):
        return False
    for root, dirs, _files in os.walk(app_path):
        if os.path.basename(root) == WIDGET_APPEX_NAME:
            return True
        # Don't walk into other bundles once we are inside an appex.
        dirs[:] = [d for d in dirs if not d.endswith(".appex") or d == WIDGET_APPEX_NAME]
    return False


def screenshot_problem(path):
    """Sanity-check a captured PNG.  None when it looks like real UI.

    Stdlib only: the PNG header must be valid and device-sized, and the
    compressed image data must not be nearly empty (a blank, black or
    single-colour frame compresses to a tiny fraction of a rendered
    screen).  This catches a blank or black frame, not a dialog drawn
    over an otherwise normal screen.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        return "unreadable: %s" % exc
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return "not a PNG"
    pos, width, height, idat = 8, 0, 0, 0
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if kind == b"IHDR":
            if pos + 16 > len(data):
                return "truncated IHDR"
            width, height = struct.unpack(">II", data[pos + 8:pos + 16])
        elif kind == b"IDAT":
            idat += length
        if length > len(data):
            return "bad chunk length"
        pos += 12 + length
    if width < 300 or height < 300:
        return "unexpected size %sx%s" % (width, height)
    if width * height == 0:
        return "unexpected size %sx%s" % (width, height)
    if idat / (width * height * 4) < MIN_COMPRESSED_RATIO:
        return "looks blank (%s compressed bytes for %sx%s)" % (idat, width, height)
    return None


# Two captures of the same screen are byte-near-identical once
# decompressed (the encoder is deterministic, so the same pixels get the
# same filters); a foregrounded app changes the frame dramatically.  Note
# the comparison is on the *decompressed* image data: comparing the
# compressed IDAT payloads is unreliable, because a tiny visual change
# (a clock ticking in the status bar) can cascade through the
# compressor and flip most of the payload bytes.
UNCHANGED_MAX_FRACTION = 0.02


def _png_image_data(path):
    """Decompressed image bytes and dimensions of a PNG, stdlib only.

    Returns ((image_bytes, width, height), None) on success, or
    (None, problem_string) when the file is unreadable or not a PNG.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        return None, "unreadable: %s" % exc
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None, "not a PNG"
    pos, width, height, idat = 8, 0, 0, bytearray()
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if length > len(data):
            return None, "bad chunk length"
        if kind == b"IHDR":
            if pos + 16 > len(data):
                return None, "truncated IHDR"
            width, height = struct.unpack(">II", data[pos + 8:pos + 16])
        elif kind == b"IDAT":
            idat += data[pos + 8:pos + 8 + length]
        pos += 12 + length
    if width < 300 or height < 300:
        return None, "unexpected size %sx%s" % (width, height)
    try:
        image = zlib.decompress(bytes(idat))
    except Exception as exc:
        return None, "IDAT decompress failed: %s" % exc
    return (image, width, height), None


def screenshot_unchanged_problem(before_path, after_path):
    """Fail-loud check that the app actually reached the foreground.

    `before_path` is captured right after the simulator boots (the home
    screen, a pairing screen, or whatever the device shows without the
    app); `after_path` is captured after launching the app.  Returns None
    when the two frames clearly differ -- the app is showing -- or a
    problem string when they are near-identical, which means the launch
    did not foreground the app (e.g. the shot is still the "Looking for
    Your Mac" pairing screen).  Stdlib only.
    """
    before, problem = _png_image_data(before_path)
    if problem is not None:
        return "baseline shot: %s" % problem
    after, problem = _png_image_data(after_path)
    if problem is not None:
        return "app shot: %s" % problem
    (before_img, before_w, before_h) = before
    (after_img, after_w, after_h) = after
    if (before_w, before_h) != (after_w, after_h) or len(before_img) != len(after_img):
        return None
    total = len(before_img)
    if total == 0:
        return "empty image data in both shots"
    changed = sum(1 for a, b in zip(before_img, after_img) if a != b)
    if changed / total < UNCHANGED_MAX_FRACTION:
        return "screen unchanged after launch (%.2f%% of image bytes differ)" % (
            100.0 * changed / total)
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prepare the screenshot OCR helper once per capture job")
    parser.add_argument("--prepare-ocr", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    prepare_ocr_helper(args.prepare_ocr, args.report)
