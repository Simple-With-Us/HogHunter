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

# How many times a required scene is taken before it is called a failure, and
# how long the app is given to settle between those takes.  The first take is
# the normal one;  the extra takes are for the frames that were taken while the
# app was still working.
SCENE_ATTEMPTS = 3
SCENE_RETRY_SETTLE = 5


def capture_scenes(udid, bundle_id, app_path, output, run=subprocess.run, settle=time.sleep, recognize=recognize_text):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    # A retry must never expose a previous attempt's scene or route evidence.
    for name in ("widget-small.png", "clean-cold-start.png", "cleaner-quick.png",
                 "cleaner-partial.png", "clean-deep-link.png", "unverified/clean-deep-link.png"):
        (output / name).unlink(missing_ok=True)
    (output / "scene-verification.json").write_text("[]\n")
    (output / "deep-link-verification.json").write_text(json.dumps({
        "url": CLEAN_URL, "verified": False, "frame": None,
        "problem": "not attempted: required scene capture has not completed",
    }, indent=2) + "\n")
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
        path = output / (name + ".png")
        text = ""
        stage = "launch"
        problem = None
        # One frame is not proof.  The app can still be working when the frame
        # is taken:  a deeper cleaner scan has to finish before its partial
        # result is on screen, and a loaded runner makes that slower still.
        # So the scene is re-taken a few times before it is called a failure,
        # and the last reason is the one that is reported.
        for attempt in range(SCENE_ATTEMPTS):
            text = ""
            stage = "launch"
            try:
                launch(args)
                stage = "capture"
                capture(path)
                stage = "OCR"
                text = recognize(path)
                problem = scene_problem(scene, text)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                problem = ("OCR unavailable: " if stage == "OCR" else stage + " failed: ") + str(error)
            if problem is None:
                break
            if attempt + 1 < SCENE_ATTEMPTS:
                settle(SCENE_RETRY_SETTLE)
        results.append({"frame": path.name, "scene": scene, "verified": problem is None, "stage": stage, "problem": problem, "recognizedText": text})
        (output / "scene-verification.json").write_text(json.dumps(results, indent=2) + "\n")
        if problem:
            print("Rejected intended frame: " + path.name + ": " + problem, flush=True)
        else:
            print("Verified intended frame: " + str(path), flush=True)

    failed = [item for item in results if not item["verified"]]
    if failed:
        raise RuntimeError("required scenes failed: " + "; ".join(
            item["frame"] + ": " + item["problem"] for item in failed
        ))

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
