#!/bin/bash
# Hog Hunter Disk Cleaner CLI Companion
#
# CleanMyMac-grade hard disk clutter cleaner for macOS.
#
# Usage:
#   scripts/clean.sh [--scan] [--dry-run] [--clean] [--category CAT] [--yes] [--json]
#
# Options:
#   --scan          Scan system clutter and display summary report (default).
#   --dry-run       List each file/directory that would be deleted without deleting.
#   --clean         Perform safe deletion of reclaimable clutter.
#   --category CAT  Target specific category:
#                     caches     User caches (~/Library/Caches)
#                     logs       Logs & diagnostics (~/Library/Logs)
#                     trash      Items in Trash (~/.Trash)
#                     developer  Xcode DerivedData, Archives, DeviceSupport, pkg caches
#                     orphans    Residual support data from uninstalled apps
#                     all        All safe categories (caches, logs, trash, developer, orphans)
#   -y, --yes       Bypass interactive confirmation prompt during --clean.
#   --json          Output scan report in JSON format.
#   -h, --help      Show this help message.

set -euo pipefail

ACTION="scan"
CATEGORY="all"
CONFIRM=1
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan)
      ACTION="scan"
      shift
      ;;
    --dry-run)
      ACTION="dry-run"
      shift
      ;;
    --clean)
      ACTION="clean"
      shift
      ;;
    --category)
      if [[ $# -lt 2 ]]; then
        echo "Error: --category requires an argument." >&2
        exit 1
      fi
      CATEGORY="$2"
      shift 2
      ;;
    -y|--yes)
      CONFIRM=0
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    -h|--help)
      sed -ne '/^#/!q;s/^# //;2,$p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use $0 --help for usage." >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Use python3 to invoke the scanner logic safely and format human-readable sizes
python3 - <<EOF
import os
import sys
import json
import shutil
import subprocess
from datetime import datetime, timedelta

action = "$ACTION"
target_category = "$CATEGORY"
auto_confirm = ($CONFIRM == 0)
json_output = ($JSON_OUTPUT == 1)

home = os.path.expanduser("~")

def format_bytes(b):
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024 * 1024 * 1024):.1f} GB"
    elif b >= 1024 * 1024:
        return f"{b / (1024 * 1024):.0f} MB"
    elif b >= 1024:
        return f"{b / 1024:.0f} KB"
    return f"{b} B"

def get_dir_size(path, file_cap=25000):
    total = 0
    count = 0
    try:
        if os.path.islink(path):
            return 0, 0
        if os.path.isfile(path):
            return os.path.getsize(path), 1
        for root, dirs, files in os.walk(path):
            if ".git" in dirs:
                dirs.remove(".git")
            for f in files:
                if count >= file_cap:
                    return total, count
                fp = os.path.join(root, f)
                try:
                    if not os.path.islink(fp):
                        total += os.path.getsize(fp)
                        count += 1
                except Exception:
                    pass
    except Exception:
        pass
    return total, count

# 1. User Caches
def scan_user_caches():
    caches_dir = os.path.join(home, "Library/Caches")
    items = []
    dev_names = {"Homebrew", "CocoaPods", "Yarn", "pnpm", "go-build", "pip", "com.apple.dt.Xcode"}
    if os.path.exists(caches_dir):
        for entry in os.listdir(caches_dir):
            if entry.startswith(".") or entry in dev_names:
                continue
            if "hoghunter" in entry.lower():
                continue
            p = os.path.join(caches_dir, entry)
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": entry, "path": p, "bytes": size, "count": count})
    return items

# 2. Logs & Diagnostics
def scan_logs():
    items = []
    logs_dir = os.path.join(home, "Library/Logs")
    if os.path.exists(logs_dir):
        for entry in os.listdir(logs_dir):
            if entry.startswith(".") or "hoghunter" in entry.lower():
                continue
            p = os.path.join(logs_dir, entry)
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": entry, "path": p, "bytes": size, "count": count})
    
    crash_dir = os.path.join(home, "Library/Application Support/CrashReporter")
    if os.path.exists(crash_dir):
        size, count = get_dir_size(crash_dir)
        if size > 0:
            items.append({"title": "CrashReporter Logs", "path": crash_dir, "bytes": size, "count": count})
    return items

# 3. Trash
def scan_trash():
    items = []
    trash_dir = os.path.join(home, ".Trash")
    if os.path.exists(trash_dir):
        for entry in os.listdir(trash_dir):
            if entry.startswith(".DS_Store"):
                continue
            p = os.path.join(trash_dir, entry)
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": entry, "path": p, "bytes": size, "count": count})
    return items

# 4. Developer
def scan_developer():
    items = []
    targets = [
        ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
        ("Xcode Archives", "Library/Developer/Xcode/Archives"),
        ("Xcode iOS DeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport"),
        ("Xcode CoreSimulator Caches", "Library/Developer/CoreSimulator/Caches"),
        ("Homebrew Cache", "Library/Caches/Homebrew"),
        ("npm Cache", ".npm/_cacache"),
        ("Yarn Cache", "Library/Caches/Yarn"),
        ("pnpm Cache", "Library/Caches/pnpm"),
        ("CocoaPods Cache", "Library/Caches/CocoaPods"),
        ("Gradle Caches", ".gradle/caches"),
        ("Cargo Registry Cache", ".cargo/registry/cache"),
        ("Go Build Cache", "Library/Caches/go-build"),
    ]
    for name, rel in targets:
        p = os.path.join(home, rel)
        if os.path.exists(p):
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": name, "path": p, "bytes": size, "count": count})
    return items

# 5. Orphans
def scan_orphans():
    import plistlib
    items = []
    # Collect installed app bundle IDs and names
    installed_ids = set()
    installed_names = set()
    app_roots = ["/Applications", "/System/Applications", os.path.join(home, "Applications")]
    for root in app_roots:
        if not os.path.exists(root):
            continue
        try:
            for entry in os.listdir(root):
                if entry.endswith(".app"):
                    name = entry[:-4].lower()
                    installed_names.add(name)
                    plist_path = os.path.join(root, entry, "Contents/Info.plist")
                    if os.path.exists(plist_path):
                        try:
                            with open(plist_path, "rb") as fp:
                                plist = plistlib.load(fp)
                                bid = plist.get("CFBundleIdentifier")
                                if bid and isinstance(bid, str):
                                    installed_ids.add(bid.strip().lower())
                        except Exception:
                            pass
        except Exception:
            pass

    # Scan Containers
    containers_dir = os.path.join(home, "Library/Containers")
    if os.path.exists(containers_dir):
        for entry in os.listdir(containers_dir):
            if entry.startswith(".") or entry.startswith("com.apple.") or "hoghunter" in entry.lower():
                continue
            if entry.lower() in installed_ids:
                continue
            p = os.path.join(containers_dir, entry)
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": entry, "path": p, "bytes": size, "count": count})

    # Scan Application Support
    app_supp = os.path.join(home, "Library/Application Support")
    if os.path.exists(app_supp):
        system_skips = {"addressbook", "callhistorydb", "cloudkit", "coreparsec", "dock", "dvd player", "knowledge", "syncservices"}
        for entry in os.listdir(app_supp):
            if entry.startswith(".") or entry.startswith("com.apple.") or entry.lower() in system_skips:
                continue
            if "hoghunter" in entry.lower():
                continue
            if entry.lower() in installed_ids or entry.lower() in installed_names:
                continue
            p = os.path.join(app_supp, entry)
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": f"AppSupport: {entry}", "path": p, "bytes": size, "count": count})
    return items

categories = {}
if target_category in ("all", "caches"):
    categories["User Caches"] = scan_user_caches()
if target_category in ("all", "logs"):
    categories["Logs & Diagnostics"] = scan_logs()
if target_category in ("all", "trash"):
    categories["Trash Bin"] = scan_trash()
if target_category in ("all", "developer"):
    categories["Developer Junk"] = scan_developer()
if target_category in ("all", "orphans"):
    categories["Orphaned Leftovers"] = scan_orphans()

total_bytes = sum(sum(i["bytes"] for i in items) for items in categories.values())
total_items = sum(len(items) for items in categories.values())

if json_output:
    out = {
        "categories": {k: {"items": v, "bytes": sum(i["bytes"] for i in v), "count": len(v)} for k, v in categories.items()},
        "total_bytes": total_bytes,
        "formatted_total": format_bytes(total_bytes),
        "total_items": total_items
    }
    print(json.dumps(out, indent=2))
    sys.exit(0)

# Print human summary
print("=" * 64)
print("  Hog Hunter — Hard Disk Clutter Scan Report")
print("=" * 64)
for cat_name, items in categories.items():
    cat_bytes = sum(i["bytes"] for i in items)
    print(f"\n📂 {cat_name}: {format_bytes(cat_bytes)} ({len(items)} items)")
    items_sorted = sorted(items, key=lambda x: x["bytes"], reverse=True)
    for it in items_sorted[:8]:
        rel_path = it["path"].replace(home, "~")
        print(f"   • {it['title']} — {format_bytes(it['bytes'])} ({rel_path})")
    if len(items_sorted) > 8:
        print(f"   ... and {len(items_sorted) - 8} more items")

print("\n" + "-" * 64)
print(f"Total Reclaimable: {format_bytes(total_bytes)} across {total_items} items")
print("-" * 64)

if action == "dry-run":
    print("\n[DRY RUN] The following items would be removed/moved to Trash:")
    for cat_name, items in categories.items():
        for it in items:
            print(f"   [WOULD REMOVE] {it['path']} ({format_bytes(it['bytes'])})")
    sys.exit(0)

if action == "clean":
    if total_bytes == 0:
        print("\nNothing to clean. Disk is already tidy!")
        sys.exit(0)

    if not auto_confirm:
        resp = input(f"\nProceed with cleaning {format_bytes(total_bytes)}? (y/N): ").strip().lower()
        if resp != "y":
            print("Aborted by user.")
            sys.exit(0)

    print("\nReclaiming disk space...")
    cleaned_bytes = 0
    cleaned_count = 0
    errors = []

    for cat_name, items in categories.items():
        for it in items:
            p = it["path"]
            # Safety checks
            if not p.startswith(home + "/"):
                errors.append(f"Skipped unsafe path: {p}")
                continue
            if p in (home, os.path.join(home, "Library"), os.path.join(home, ".Trash")):
                errors.append(f"Skipped root path: {p}")
                continue

            try:
                if "/.Trash/" in p or p.endswith("/.Trash"):
                    if os.path.isfile(p) or os.path.islink(p):
                        os.unlink(p)
                    else:
                        shutil.rmtree(p)
                else:
                    # Move to Trash via osascript Finder delete or send2trash
                    res = subprocess.run([
                        "osascript", "-e",
                        f'tell application "Finder" to delete POSIX file "{p}"'
                    ], capture_output=True, text=True, check=False)
                    if res.returncode != 0:
                        # Fallback to direct safe remove if Finder fails
                        if os.path.isfile(p) or os.path.islink(p):
                            os.unlink(p)
                        else:
                            shutil.rmtree(p)

                cleaned_bytes += it["bytes"]
                cleaned_count += 1
            except Exception as e:
                errors.append(f"Failed {p}: {e}")

    print(f"\n✅ Clean complete! Successfully reclaimed {format_bytes(cleaned_bytes)} ({cleaned_count} items).")
    if errors:
        print(f"⚠️  {len(errors)} items could not be removed:")
        for err in errors[:5]:
            print(f"   • {err}")
EOF
