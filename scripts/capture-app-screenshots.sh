#!/usr/bin/env bash
# Capture app screenshots across standard device formats.
# This lane is the visual-verification gate: it FAILS (exit 1) when any
# expected artifact is missing, so CI can never pass with no screenshots.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mkdir -p screenshots/ios screenshots/macos
failures=0

# 1. iOS Companion Screenshots
ios_app="$(find build-ios -name "HogHunter.app" -type d 2>/dev/null | head -n 1 || true)"
if [[ -z "$ios_app" ]]; then
  ios_app="$(find build -name "HogHunter.app" -path "*simulator*" -type d 2>/dev/null | head -n 1 || true)"
fi

if [[ -n "$ios_app" && -d "$ios_app" ]]; then
  echo "Found iOS app: $ios_app"
  bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$ios_app/Info.plist" 2>/dev/null || echo "com.simplewithus.hoghunter.ios")"
  echo "Bundle ID: $bundle_id"

  python3 - "$ios_app" "$bundle_id" <<'PYIOS' || failures=$((failures + 1))
import json, os, re, subprocess, sys, time

app_path, bundle_id = sys.argv[1], sys.argv[2]

BOOT_TIMEOUT_S = 180
# A solid-colour frame compresses to ~0.1% of its raw size; a rendered screen
# is an order of magnitude above this.
MIN_COMPRESSED_RATIO = 0.003


def boot_simulator(udid):
    """Boot and WAIT for the simulator, never a blind sleep.  `bootstatus`
    only blocks until boot completes with -b; without it, it prints the
    current state and returns at once.
    Returns None when it is booted, else the reason it is not."""
    boot = subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True, text=True)
    if boot.returncode != 0 and "current state: Booted" not in (boot.stderr or ""):
        return f"boot failed: {(boot.stderr or boot.stdout or '').strip() or f'exit {boot.returncode}'}"
    try:
        status = subprocess.run(
            ["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True, text=True, timeout=BOOT_TIMEOUT_S
        )
    except subprocess.TimeoutExpired:
        return f"not booted after {BOOT_TIMEOUT_S}s"
    if status.returncode != 0:
        return f"bootstatus failed: {(status.stderr or status.stdout or '').strip() or f'exit {status.returncode}'}"
    return None


def app_pid_from_launch(output):
    """`simctl launch` prints `<bundle id>: <pid>`."""
    match = re.search(r":\s*(\d+)\s*$", (output or "").strip())
    return int(match.group(1)) if match else None


def launch_pid(udid):
    """Re-run `simctl launch` and return the pid it reports, or None.

    This proves PROCESS CONTINUITY only: the same pid means the app did not
    exit and relaunch.  It does not prove the app is in front, and it cannot
    see a system alert or another app over it (launch also activates the app,
    which can itself change what is on screen).  Frame content is checked
    separately by screenshot_problem()."""
    result = subprocess.run(
        ["xcrun", "simctl", "launch", udid, bundle_id, "-HogHunterSample"], capture_output=True, text=True
    )
    return app_pid_from_launch(result.stdout) if result.returncode == 0 else None


def screenshot_problem(path):
    """Sanity-check the captured PNG itself.  Returns None when it looks like
    real UI, else why not.  Stdlib only: the PNG header must be valid and the
    device-sized, and the compressed image data must not be nearly empty (a
    blank, black or single-colour frame compresses to a tiny fraction of a
    rendered screen).  This catches a blank or black frame, not a dialog drawn
    over an otherwise normal screen; that still needs a person looking at the
    uploaded artifact."""
    import struct, zlib
    try:
        data = open(path, "rb").read()
    except OSError as e:
        return f"unreadable: {e}"
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return "not a PNG"
    pos, width, height, idat = 8, 0, 0, 0
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if kind == b"IHDR":
            width, height = struct.unpack(">II", data[pos + 8:pos + 16])
        elif kind == b"IDAT":
            idat += length
        pos += 12 + length
    if width < 300 or height < 300:
        return f"unexpected size {width}x{height}"
    if idat / (width * height * 4) < MIN_COMPRESSED_RATIO:
        return f"looks blank ({idat} compressed bytes for {width}x{height})"
    return None

# Format definitions: key -> (output_name, list_of_preferred_devices, fallback_devicetype_pattern)
FORMATS = {
    "iphone-6.9-6.7": ("iPhone_6.9_6.7_inch", ["iPhone 16 Pro Max", "iPhone 15 Pro Max", "iPhone 16 Plus", "iPhone 15 Plus", "iPhone 17 Pro Max", "iPhone 18 Pro Max"], "iPhone-16-Pro-Max"),
    "iphone-6.3-6.1": ("iPhone_6.3_6.1_inch", ["iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro", "iPhone 15", "iPhone 14", "iPhone 17 Pro", "iPhone 18 Pro"], "iPhone-16-Pro"),
    "iphone-5.5-4.7": ("iPhone_5.5_4.7_inch", ["iPhone SE (3rd generation)", "iPhone 8 Plus", "iPhone SE"], "iPhone-SE-3rd-generation"),
    "ipad-13":        ("iPad_13_inch",        ["iPad Pro 13-inch (M4)", "iPad Pro (12.9-inch) (6th generation)", "iPad Pro (12.9-inch)", "iPad Air 13-inch (M2)"], "iPad-Pro-13-inch-M4"),
    "ipad-11":        ("iPad_11_inch",        ["iPad Air 11-inch (M2)", "iPad Pro (11-inch) (4th generation)", "iPad (10th generation)", "iPad mini (6th generation)"], "iPad-Air-11-inch-M2")
}

failures = 0

try:
    proc = subprocess.run(["xcrun", "simctl", "list", "-j", "devices", "available"], capture_output=True, text=True, check=True)
    devices_data = json.loads(proc.stdout).get("devices", {})
except Exception as e:
    print(f"ERROR: could not list simulators: {e}")
    sys.exit(1)

# Build a lookup of available device name and deviceType -> udid
available_devices = {}
for runtime, dlist in devices_data.items():
    for d in dlist:
        if d.get("isAvailable", False):
            name = d.get("name")
            dtype = d.get("deviceTypeIdentifier", "")
            udid = d.get("udid")
            if name and name not in available_devices:
                available_devices[name] = udid
            if dtype and dtype not in available_devices:
                available_devices[dtype] = udid

def version_key(v):
    # "18.2" / "26.0.1" -> comparable tuple of ints
    try:
        return tuple(int(p) for p in str(v).split("."))
    except ValueError:
        return (-1,)

# Discover available iOS runtimes for fallback creation, then pick the HIGHEST
# version deterministically. The old code took the last runtime in an unsorted
# JSON list, which silently pinned captures to an arbitrary older iOS.
ios_runtimes = []
try:
    rproc = subprocess.run(["xcrun", "simctl", "list", "-j", "runtimes"], capture_output=True, text=True)
    rdata = json.loads(rproc.stdout).get("runtimes", [])
    for r in rdata:
        ident = r.get("identifier", "")
        name = r.get("name", "")
        is_ios = ident.startswith("com.apple.CoreSimulator.SimRuntime.iOS") or name.startswith("iOS")
        if is_ios and r.get("isAvailable", True):
            ios_runtimes.append((version_key(r.get("version", "")), ident, r.get("version", "")))
except Exception:
    pass
ios_runtimes.sort(key=lambda t: t[0])
latest_ios_runtime = ios_runtimes[-1][1] if ios_runtimes else None
print(f"Selected iOS runtime: {ios_runtimes[-1][2] if ios_runtimes else 'none'} ({latest_ios_runtime})")

print(f"Available simulators detected: {len(available_devices)}")

for fmt_key, (out_name, candidates, fallback_type) in FORMATS.items():
    udid = None
    chosen_device = None
    created_udid = None
    out_file = f"screenshots/ios/{out_name}.png"

    for cand in candidates:
        if cand in available_devices:
            udid = available_devices[cand]
            chosen_device = cand
            break

    # If no candidate by exact name, try partial match on deviceTypeIdentifier
    if not udid:
        for name_or_type, u in available_devices.items():
            if any(c.replace(" ", "-").lower() in name_or_type.lower() for c in candidates):
                udid = u
                chosen_device = name_or_type
                break

    # If still not found and runtime exists, create a temporary simulator
    if not udid and latest_ios_runtime and fallback_type:
        try:
            full_dev_type = f"com.apple.CoreSimulator.SimDeviceType.{fallback_type}"
            c_proc = subprocess.run(["xcrun", "simctl", "create", f"temp-{out_name}", full_dev_type, latest_ios_runtime], capture_output=True, text=True)
            if c_proc.returncode == 0:
                created_udid = c_proc.stdout.strip()
                udid = created_udid
                chosen_device = f"Created {fallback_type}"
            else:
                print(f"[{fmt_key}] ERROR: could not create simulator: {c_proc.stderr.strip()}")
        except Exception as e:
            print(f"[{fmt_key}] ERROR: could not create simulator: {e}")

    if not udid:
        print(f"[{fmt_key}] ERROR: no simulator available - {out_file} will be missing.")
        failures += 1
        continue

    print(f"[{fmt_key}] Using '{chosen_device}' ({udid})...")
    try:
        boot_problem = boot_simulator(udid)
        if boot_problem:
            print(f"[{fmt_key}] ERROR: simulator {boot_problem}")
            failures += 1
            continue
        inst = subprocess.run(["xcrun", "simctl", "install", udid, app_path], capture_output=True, text=True)
        if inst.returncode != 0:
            print(f"[{fmt_key}] ERROR: install failed: {inst.stderr.strip()}")
            failures += 1
            continue
        # Launch with the sample-state flag so CompanionModel.start() shows the
        # live dashboard, not the onboarding screen.
        launch = subprocess.run(["xcrun", "simctl", "launch", udid, bundle_id, "-HogHunterSample"], capture_output=True, text=True)
        if launch.returncode != 0:
            print(f"[{fmt_key}] ERROR: launch failed: {launch.stderr.strip()}")
            failures += 1
            continue
        launched_pid = app_pid_from_launch(launch.stdout)
        time.sleep(5)
        # The delay is only a settle time.  The pid check below proves the app
        # was not restarted (a crash on launch would relaunch it with a new
        # pid); it does NOT prove the app is in front.  That is what the
        # screenshot_problem() check on the captured file is for, within its
        # stated limits.
        if launched_pid is None or launch_pid(udid) != launched_pid:
            print(f"[{fmt_key}] ERROR: {bundle_id} exited or restarted after launch (pid changed).")
            failures += 1
            continue
        time.sleep(1)
        res = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", out_file], capture_output=True, text=True)
        if launch_pid(udid) != launched_pid:
            print(f"[{fmt_key}] ERROR: {bundle_id} exited or restarted during the capture (pid changed); discarding {out_file}.")
            if os.path.isfile(out_file):
                os.remove(out_file)
            failures += 1
            continue
        if res.returncode == 0 and os.path.isfile(out_file) and os.path.getsize(out_file) > 0:
            problem = screenshot_problem(out_file)
            if problem:
                print(f"[{fmt_key}] ERROR: captured frame rejected: {problem}; discarding {out_file}.")
                os.remove(out_file)
                failures += 1
                continue
            print(f"  ✓ Saved {out_file}")
        else:
            print(f"[{fmt_key}] ERROR: screenshot failed: {res.stderr.strip() or 'no file written'}")
            failures += 1
    except Exception as e:
        print(f"[{fmt_key}] ERROR: exception capturing: {e}")
        failures += 1
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        if created_udid:
            subprocess.run(["xcrun", "simctl", "delete", created_udid], capture_output=True)

if failures:
    print(f"iOS screenshot lane FAILED: {failures} of {len(FORMATS)} formats missing.")
sys.exit(1 if failures else 0)

PYIOS

else
  echo "ERROR: no iOS simulator app build found under build-ios/ or build/ - the iOS screenshot lane cannot produce artifacts."
  failures=$((failures + 1))
fi

# 2. macOS App Screenshots
mac_app="$(find build -name "HogHunter.app" ! -path "*simulator*" -type d 2>/dev/null | head -n 1 || true)"
if [[ -n "$mac_app" && -d "$mac_app" ]]; then
  echo "Found macOS app: $mac_app"
  mac_bin="$mac_app/Contents/MacOS/HogHunter"
  if [[ -x "$mac_bin" ]]; then
    if ! python3 -c "import Quartz" 2>/dev/null; then
      echo "Installing pyobjc-framework-Quartz for macOS window detection..."
      python3 -m pip install --quiet --break-system-packages pyobjc-framework-Quartz 2>/dev/null || python3 -m pip install --quiet pyobjc-framework-Quartz 2>/dev/null || true
    fi
    echo "Capturing macOS screenshot..."
    # -HogHunterScreenshot makes the accessory app activate, open its Settings
    # window, and order it front (see HogHunterAppDelegate; it retries for
    # ~15s because the Settings scene can take a beat on a headless runner).
    app_log="$(mktemp -t hoghunter-screenshot-app)"
    "$mac_bin" -HogHunterScreenshot >"$app_log" 2>&1 &
    app_pid=$!
    # Require a REAL on-screen HogHunter window before capturing. A
    # full-desktop screenshot of a runner with no app window was the original
    # defect - a desktop fallback would only mask regressions, so there is
    # none: no window within 60s fails the lane.
    win_id=""
    for _ in $(seq 1 30); do
      if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "ERROR: HogHunter exited before showing a window."
        break
      fi
      win_id="$(python3 - <<'PYWIN'
try:
    import Quartz
    windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    for w in windows:
        owner = w.get("kCGWindowOwnerName", "")
        # The window may be at normal level (layer 0) or elevated above the menu bar panel (layer 102).
        if owner in ("Hog Hunter", "HogHunter") and 0 <= w.get("kCGWindowLayer", -1) <= 200:
            b = w.get("kCGWindowBounds", {})
            # The Settings window is presented at 560x480 content (plus title bar).
            # A menu-bar-width strip (the 440x38 title-bar-only window from run
            # 36766658503) must NOT pass: require a window that can hold the UI.
            if b.get("Width", 0) >= 400 and b.get("Height", 0) >= 300:
                print(w.get("kCGWindowNumber", ""))
                break
except Exception:
    pass
PYWIN
      )"
      win_id="$(echo "$win_id" | tr -d '[:space:]')"
      [[ -n "$win_id" ]] && break
      sleep 2
    done

    if [[ -z "$win_id" ]]; then
      echo "ERROR: no on-screen HogHunter window appeared within 60s; refusing to capture the desktop."
      echo "--- HogHunter app output ($app_log):"
      cat "$app_log" 2>/dev/null || echo "(no app output captured)"
      echo "--- On-screen window snapshot (owner / layer / size / name):"
      python3 - <<'PYDUMP'
try:
    import Quartz
    windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    for w in windows:
        b = w.get("kCGWindowBounds", {})
        print("  owner=%s layer=%s %sx%s name=%s" % (
            w.get("kCGWindowOwnerName", "?"), w.get("kCGWindowLayer", "?"),
            b.get("Width", 0), b.get("Height", 0), w.get("kCGWindowName", "")))
except Exception as e:
    print("  (window dump unavailable: %s)" % e)
PYDUMP
      failures=$((failures + 1))
    else
      echo "  Capturing HogHunter window $win_id"
      osascript -e 'tell application "Hog Hunter" to activate' 2>/dev/null || osascript -e 'tell application "HogHunter" to activate' 2>/dev/null || true
      sleep 1
      screencapture -o -l"$win_id" screenshots/macos/HogHunter_macOS.png 2>/dev/null || true
      if [[ -s screenshots/macos/HogHunter_macOS.png ]]; then
        # Re-check the captured image itself: a window that shrank between
        # detection and capture must not ship as a screenshot (@2x pixels are
        # larger than points, so the point thresholds are a safe floor).
        shot_w="$(sips -g pixelWidth screenshots/macos/HogHunter_macOS.png 2>/dev/null | awk '/pixelWidth/ {print $2}')"
        shot_h="$(sips -g pixelHeight screenshots/macos/HogHunter_macOS.png 2>/dev/null | awk '/pixelHeight/ {print $2}')"
        if [[ "${shot_w:-0}" -lt 400 || "${shot_h:-0}" -lt 300 ]]; then
          echo "ERROR: macOS capture is only ${shot_w:-?}x${shot_h:-?} px; the Settings UI did not render at a usable size."
          rm -f screenshots/macos/HogHunter_macOS.png
          failures=$((failures + 1))
        else
          echo "  ✓ Saved screenshots/macos/HogHunter_macOS.png (${shot_w}x${shot_h})"
        fi
      else
        echo "ERROR: macOS capture produced no image."
        failures=$((failures + 1))
      fi
    fi
    kill "$app_pid" 2>/dev/null || true
  else
    echo "ERROR: macOS binary not executable at $mac_bin."
    failures=$((failures + 1))
  fi
else
  echo "ERROR: no macOS app build found under build/ - the macOS screenshot lane cannot produce artifacts."
  failures=$((failures + 1))
fi

echo "=== Captured Screenshots Summary ==="
find screenshots -type f -name "*.png" -exec ls -lh {} + 2>/dev/null || echo "No screenshots found."

if [[ "$failures" -gt 0 ]]; then
  echo "FAILED: $failures expected screenshot artifact(s) missing."
  exit 1
fi
exit 0
