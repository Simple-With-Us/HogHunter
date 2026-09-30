#!/usr/bin/env bash
# Capture app screenshots across standard device formats.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mkdir -p screenshots/ios screenshots/macos

# 1. iOS Companion Screenshots
ios_app="$(find build-ios -name "HogHunter.app" -type d 2>/dev/null | head -n 1 || true)"
if [[ -z "$ios_app" ]]; then
  ios_app="$(find build -name "HogHunter.app" -path "*simulator*" -type d 2>/dev/null | head -n 1 || true)"
fi

if [[ -n "$ios_app" && -d "$ios_app" ]]; then
  echo "Found iOS app: $ios_app"
  bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$ios_app/Info.plist" 2>/dev/null || echo "com.simplewithus.hoghunter.ios")"
  echo "Bundle ID: $bundle_id"

  python3 - "$ios_app" "$bundle_id" <<'PYIOS'
import json, subprocess, sys, time

app_path, bundle_id = sys.argv[1], sys.argv[2]

# Format definitions: key -> (output_name, list_of_preferred_devices, fallback_devicetype_pattern)
FORMATS = {
    "iphone-6.9-6.7": ("iPhone_6.9_6.7_inch", ["iPhone 16 Pro Max", "iPhone 15 Pro Max", "iPhone 16 Plus", "iPhone 15 Plus", "iPhone 17 Pro Max", "iPhone 18 Pro Max"], "iPhone-16-Pro-Max"),
    "iphone-6.3-6.1": ("iPhone_6.3_6.1_inch", ["iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro", "iPhone 15", "iPhone 14", "iPhone 17 Pro", "iPhone 18 Pro"], "iPhone-16-Pro"),
    "iphone-5.5-4.7": ("iPhone_5.5_4.7_inch", ["iPhone SE (3rd generation)", "iPhone 8 Plus", "iPhone SE"], "iPhone-SE-3rd-generation"),
    "ipad-13":        ("iPad_13_inch",        ["iPad Pro 13-inch (M4)", "iPad Pro (12.9-inch) (6th generation)", "iPad Pro (12.9-inch)", "iPad Air 13-inch (M2)"], "iPad-Pro-13-inch-M4"),
    "ipad-11":        ("iPad_11_inch",        ["iPad Air 11-inch (M2)", "iPad Pro (11-inch) (4th generation)", "iPad (10th generation)", "iPad mini (6th generation)"], "iPad-Air-11-inch-M2")
}

try:
    proc = subprocess.run(["xcrun", "simctl", "list", "-j", "devices", "available"], capture_output=True, text=True, check=True)
    devices_data = json.loads(proc.stdout).get("devices", {})
except Exception as e:
    print(f"Warning: could not list simulators: {e}")
    devices_data = {}

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

# Discover available iOS runtimes for fallback creation
latest_ios_runtime = None
try:
    rproc = subprocess.run(["xcrun", "simctl", "list", "-j", "runtimes"], capture_output=True, text=True)
    rdata = json.loads(rproc.stdout).get("runtimes", [])
    for r in rdata:
        if r.get("platform") == "iOS" and r.get("isAvailable", True):
            latest_ios_runtime = r.get("identifier")
except Exception:
    pass

print(f"Available simulators detected: {len(available_devices)}")

for fmt_key, (out_name, candidates, fallback_type) in FORMATS.items():
    udid = None
    chosen_device = None
    created_udid = None

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
        except Exception:
            pass

    if not udid:
        print(f"[{fmt_key}] No simulator available, skipping.")
        continue

    print(f"[{fmt_key}] Using '{chosen_device}' ({udid})...")
    out_file = f"screenshots/ios/{out_name}.png"
    try:
        subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
        time.sleep(8)
        subprocess.run(["xcrun", "simctl", "install", udid, app_path], capture_output=True)
        subprocess.run(["xcrun", "simctl", "launch", udid, bundle_id], capture_output=True)
        time.sleep(5)
        res = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", out_file], capture_output=True, text=True)
        if res.returncode == 0:
            print(f"  ✓ Saved {out_file}")
        else:
            print(f"  ✗ Screenshot error: {res.stderr.strip()}")
    except Exception as e:
        print(f"  ✗ Exception capturing {fmt_key}: {e}")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        if created_udid:
            subprocess.run(["xcrun", "simctl", "delete", created_udid], capture_output=True)

PYIOS

else
  echo "No iOS simulator app found; skipping iOS screenshots."
fi

# 2. macOS App Screenshots
mac_app="$(find build -name "HogHunter.app" ! -path "*simulator*" -type d 2>/dev/null | head -n 1 || true)"
if [[ -n "$mac_app" && -d "$mac_app" ]]; then
  echo "Found macOS app: $mac_app"
  mac_bin="$mac_app/Contents/MacOS/HogHunter"
  if [[ -x "$mac_bin" ]]; then
    echo "Capturing macOS screenshot..."
    "$mac_bin" &
    app_pid=$!
    sleep 3
    osascript -e 'tell application "HogHunter" to activate' 2>/dev/null || true
    sleep 2
    if screencapture -x screenshots/macos/HogHunter_macOS.png 2>/dev/null; then
      echo "  ✓ Saved screenshots/macos/HogHunter_macOS.png"
    else
      echo "  Note: screencapture unavailable or denied in this environment."
    fi
    kill "$app_pid" 2>/dev/null || true
  fi
else
  echo "No macOS app build found; skipping macOS screenshots."
fi

echo "=== Captured Screenshots Summary ==="
find screenshots -type f -name "*.png" -exec ls -lh {} + 2>/dev/null || echo "No screenshots found."
exit 0
