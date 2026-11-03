#!/usr/bin/env python3
"""Capture real fixture views; report URL routing separately from scene proof."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from ios_screenshot_checks import (
    CLEAN_URL, COLD_CLEAN_LAUNCH_ARGS, WARM_CLEAN_LAUNCH_ARGS,
    WIDGET_PREVIEW_LAUNCH_ARGS, CLEANER_LAUNCH_ARGS, PARTIAL_CLEANER_LAUNCH_ARGS,
    clean_openurl_command, screenshot_command, screenshot_problem, widget_appex_present,
    recognize_text, scene_problem,
)


def capture_scenes(udid, bundle_id, app_path, output, run=subprocess.run, settle=time.sleep, recognize=recognize_text):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    if not widget_appex_present(app_path):
        raise RuntimeError("embedded widget extension missing")

    def command(args):
        return run(args, capture_output=True, text=True, timeout=60, check=True)

    def launch(args):
        run(["xcrun", "simctl", "terminate", udid, bundle_id], capture_output=True, timeout=30)
        command(["xcrun", "simctl", "launch", udid, bundle_id, *args])
        settle(5)

    def capture(path):
        command(screenshot_command(udid, str(path)))
        problem = screenshot_problem(path)
        if problem:
            raise RuntimeError(str(path) + ": " + problem)

    results = []
    for name, args, scene in (
        ("widget-small", WIDGET_PREVIEW_LAUNCH_ARGS, "widget-preview"),
        ("clean-cold-start", COLD_CLEAN_LAUNCH_ARGS, "clean-confirmation"),
        ("cleaner-quick", CLEANER_LAUNCH_ARGS, "cleaner-quick"),
        ("cleaner-partial", PARTIAL_CLEANER_LAUNCH_ARGS, "cleaner-partial"),
    ):
        launch(args)
        path = output / (name + ".png")
        capture(path)
        text = ""
        try:
            text = recognize(path)
            problem = scene_problem(scene, text)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            problem = "OCR unavailable: " + str(error)
        results.append({"frame": path.name, "scene": scene, "verified": problem is None, "problem": problem, "recognizedText": text})
        (output / "scene-verification.json").write_text(json.dumps(results, indent=2) + "\n")
        if problem:
            raise RuntimeError(path.name + ": " + problem)
        print("Verified intended frame: " + str(path), flush=True)

    # The OS may ask the user to approve opening the URL.  Never auto-accept it,
    # never count it as destination proof, and run this LAST so it cannot cover
    # any required scene or extra capture on this simulator.
    route = {"url": CLEAN_URL, "verified": False, "frame": None}
    path = output / "clean-deep-link.png"
    path.unlink(missing_ok=True)
    try:
        launch(WARM_CLEAN_LAUNCH_ARGS)
        command(clean_openurl_command(udid))
        settle(3)
        capture(path)
        text = recognize(path)
        problem = scene_problem("clean-confirmation", text)
        route.update(verified=problem is None, problem=problem, recognizedText=text)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        route["problem"] = str(error)
    if path.exists():
        if not route["verified"]:
            destination = output / "unverified" / path.name
            destination.parent.mkdir(exist_ok=True)
            path.replace(destination)
            path = destination
        route["frame"] = str(path.relative_to(output))
    (output / "deep-link-verification.json").write_text(json.dumps(route, indent=2) + "\n")
    print("Deep link destination: " + ("verified" if route["verified"] else "UNVERIFIED (see deep-link-verification.json)"), flush=True)
    return results, route


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--app-path", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    capture_scenes(args.udid, args.bundle_id, args.app_path, args.output)
