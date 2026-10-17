#!/usr/bin/env python3
"""Checks the iOS screenshot lane can share with CI and with a Linux test.

The macOS runner still has to boot a simulator.  This module is the part
that does not: how a captured PNG is judged, and the exact simctl commands
the Clean widget lane must run.
"""

import os
import struct
import zlib

# A solid-colour frame compresses to ~0.1% of its raw size; a rendered screen
# is an order of magnitude above this.
MIN_COMPRESSED_RATIO = 0.003

CLEAN_URL = "hoghunter://clean"
WIDGET_APPEX_NAME = "HogHunterWidgets.appex"
WIDGET_PREVIEW_LAUNCH_ARGS = ["-HogHunterSample", "-HogHunterWidgetPreview"]
COLD_CLEAN_LAUNCH_ARGS = ["-HogHunterSample", "-HogHunterCleanConfirm"]
WARM_CLEAN_LAUNCH_ARGS = ["-HogHunterSample"]

REQUIRED_FRAMES = (
    "screenshots/ios/widget-small.png",
    "screenshots/ios/clean-cold-start.png",
    "screenshots/ios/clean-deep-link.png",
)


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
