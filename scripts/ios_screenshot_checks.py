#!/usr/bin/env python3
"""Checks the iOS screenshot lane can share with CI and with a Linux test.

The macOS runner still has to boot a simulator.  This module is the part
that does not: how a captured PNG is judged, and the exact simctl commands
the Clean widget lane must run.
"""

import os
import struct

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
