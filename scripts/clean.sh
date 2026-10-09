#!/bin/bash
# Hog Hunter Disk Cleaner CLI Companion
#
# Hard disk clutter cleaner for macOS.
#
# Usage:
#   scripts/clean.sh [--scan] [--dry-run] [--clean] [--tier standard|extreme] [--confirm-extreme] [--category CAT] [--yes] [--json]
#
# Options:
#   --scan              Scan system clutter and display summary report (default).
#   --dry-run           List each file/directory that would be deleted without deleting.
#   --clean             Perform safe deletion of reclaimable clutter.
#   --tier TIER         Cleaning tier:
#                         standard  (default) Safe clutter: caches, logs, trash, developer caches.
#                         extreme   Deep cleaning: includes uninstalled app leftovers & inactive AI artifacts.
#   --confirm-extreme   Explicitly acknowledge disclaimer when running --clean with --tier extreme.
#   --category CAT      Target specific category:
#                         caches     User caches (~/Library/Caches)
#                         logs       Logs & diagnostics (~/Library/Logs)
#                         trash      Items in Trash (~/.Trash)
#                         developer  Xcode DerivedData, Archives, DeviceSupport, pkg caches
#                         orphans    Residual support data from uninstalled apps (Extreme)
#                         ai         Inactive AI agent transcripts > 7 days old (Extreme)
#                         all        All categories matching the selected tier
#   -y, --yes           Bypass interactive confirmation prompt during --clean.
#   --json              Output scan report in JSON format.
#   -h, --help          Show this help message.

set -euo pipefail

ACTION="scan"
TIER="standard"
CATEGORY="all"
CONFIRM_EXTREME=0
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
    --tier)
      if [[ $# -lt 2 ]]; then
        echo "Error: --tier requires an argument (standard or extreme)." >&2
        exit 1
      fi
      TIER="$2"
      shift 2
      ;;
    --confirm-extreme)
      CONFIRM_EXTREME=1
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

if [[ "$TIER" != "standard" && "$TIER" != "extreme" ]]; then
  echo "Error: Invalid tier '$TIER'. Must be 'standard' or 'extreme'." >&2
  exit 1
fi

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
tier = "$TIER"
target_category = "$CATEGORY"
confirm_extreme = ($CONFIRM_EXTREME == 1)
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
    dev_names = {"Homebrew", "CocoaPods", "Yarn", "pnpm", "go-build", "pip", "com.apple.dt.Xcode",
                 "dev.kdrag0n.MacVirt", "com.docker.docker"}
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
        ("OrbStack Cache", "Library/Caches/dev.kdrag0n.MacVirt"),
        ("OrbStack Engine Cache", "Library/Group Containers/HUAQ24HBR6.dev.orbstack/Library/Caches"),
        ("Docker Buildx Cache", ".docker/buildx/cache"),
        ("Docker Desktop Cache", "Library/Caches/com.docker.docker"),
    ]
    for name, rel in targets:
        p = os.path.join(home, rel)
        if os.path.exists(p):
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": name, "path": p, "bytes": size, "count": count})
    return items

# Shared vendor folders hold several live products; they are not one uninstalled app.
# Mirrors DiskCleaner.isSharedVendorContainer.
SHARED_VENDOR_CONTAINERS = {"google", "mozilla", "microsoft", "mobilesync", "crashreporter"}

def _normalize_name(value):
    return "".join(ch for ch in value.lower() if ch.isalnum())

def holds_installed_product(child_names, installed_ids, installed_names):
    """Mirror of DiskCleaner.holdsInstalledProduct: True when a folder still
    contains a product that is installed.  Normalized compare so a
    version-suffixed child ("IntelliJIdea2024.2") matches "IntelliJ IDEA",
    and a product folder ("Brave-Browser") matches "Brave Browser"."""
    wanted = {_normalize_name(v) for v in installed_ids | installed_names}
    wanted = {w for w in wanted if len(w) > 2}
    for child in child_names:
        c = _normalize_name(child)
        if not c:
            continue
        if any(w == c or c.startswith(w) or (len(w) >= 6 and c.endswith(w)) for w in wanted):
            return True
    return False

# 5. Orphans (Extreme tier)
def scan_orphans():
    import plistlib
    items = []
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
                                    bid = bid.strip().lower()
                                    installed_ids.add(bid)
                                    # Mirror DiskCleaner: the bundle-id suffix is
                                    # also a known name ("com.brave.Browser" -> "browser").
                                    suffix = bid.rsplit(".", 1)[-1]
                                    if suffix:
                                        installed_names.add(suffix)
                        except Exception:
                            pass
        except Exception:
            pass

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
                items.append({"title": f"Container: {entry}", "path": p, "bytes": size, "count": count})

    app_supp = os.path.join(home, "Library/Application Support")
    if os.path.exists(app_supp):
        system_skips = {"addressbook", "callhistorydb", "cloudkit", "coreparsec", "dock", "dvd player", "knowledge", "syncservices"}
        for entry in os.listdir(app_supp):
            if entry.startswith(".") or entry.startswith("com.apple.") or entry.lower() in system_skips:
                continue
            if "hoghunter" in entry.lower():
                continue
            # strip() so shell matches Swift isSharedVendorContainer trim.
            if entry.strip().lower() in SHARED_VENDOR_CONTAINERS:
                continue
            if entry.lower() in installed_ids or entry.lower() in installed_names:
                continue
            p = os.path.join(app_supp, entry)
            try:
                child_names = os.listdir(p)
            except Exception:
                child_names = []
            if holds_installed_product(child_names, installed_ids, installed_names):
                continue
            size, count = get_dir_size(p)
            if size > 0:
                items.append({"title": f"AppSupport: {entry}", "path": p, "bytes": size, "count": count})
    return items

# 6. AI Agent Artifacts & Transcripts (> 7 days inactive) (Extreme tier)
def scan_ai_artifacts():
    items = []
    seven_days_ago = datetime.now() - timedelta(days=7)
    
    # Antigravity Brain transcripts
    brain_dir = os.path.join(home, ".gemini/antigravity/brain")
    if os.path.exists(brain_dir):
        for entry in os.listdir(brain_dir):
            p = os.path.join(brain_dir, entry)
            if os.path.isdir(p) and not entry.startswith("."):
                try:
                    mtime = datetime.fromtimestamp(os.path.getmtime(p))
                    if mtime < seven_days_ago:
                        size, count = get_dir_size(p)
                        if size > 0:
                            items.append({"title": f"Gemini/AG Brain: {entry[:8]}…", "path": p, "bytes": size, "count": count})
                except Exception:
                    pass

    # Grok sessions
    grok_dir = os.path.join(home, ".grok/sessions")
    if os.path.exists(grok_dir):
        for entry in os.listdir(grok_dir):
            p = os.path.join(grok_dir, entry)
            try:
                mtime = datetime.fromtimestamp(os.path.getmtime(p))
                if mtime < seven_days_ago:
                    size, count = get_dir_size(p)
                    if size > 0:
                        items.append({"title": f"Grok Session: {entry[:12]}…", "path": p, "bytes": size, "count": count})
            except Exception:
                pass

    # Codex archived sessions
    codex_dir = os.path.join(home, ".codex/archived_sessions")
    if os.path.exists(codex_dir):
        for entry in os.listdir(codex_dir):
            p = os.path.join(codex_dir, entry)
            try:
                mtime = datetime.fromtimestamp(os.path.getmtime(p))
                if mtime < seven_days_ago:
                    size, count = get_dir_size(p)
                    if size > 0:
                        items.append({"title": f"Codex Archive: {entry[:12]}…", "path": p, "bytes": size, "count": count})
            except Exception:
                pass

    # BotFleet update temp files
    for root_dir in [home, "/tmp"]:
        try:
            for entry in os.listdir(root_dir):
                if entry.startswith(".BotFleet.update-") or entry.startswith("BotFleet.update-"):
                    p = os.path.join(root_dir, entry)
                    try:
                        mtime = datetime.fromtimestamp(os.path.getmtime(p))
                        if mtime < seven_days_ago:
                            size, count = get_dir_size(p)
                            if size > 0:
                                items.append({"title": f"BotFleet Temp: {entry}", "path": p, "bytes": size, "count": count})
                    except Exception:
                        pass
        except Exception:
            pass

    return items

def is_safe_to_delete(p):
    if ".secrets" in p:
        return False
    if ".git" in p:
        return False
    if "hoghunter" in p.lower() and not "caches/com.simplewithus.hoghunter" in p.lower():
        return False
    if p in (home, os.path.join(home, "Library"), os.path.join(home, ".Trash")):
        return False
    if not p.startswith(home + "/") and not p.startswith("/tmp/"):
        return False
    return True

def create_apfs_snapshot():
    try:
        res = subprocess.run(["/usr/bin/tmutil", "localsnapshot"], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "Created local snapshot with date" in line:
                    return line.strip()
            return "APFS local snapshot created successfully."
    except Exception:
        return None
    return None

categories = {}
if target_category in ("all", "caches"):
    categories["User Caches"] = scan_user_caches()
if target_category in ("all", "logs"):
    categories["Logs & Diagnostics"] = scan_logs()
if target_category in ("all", "trash"):
    categories["Trash Bin"] = scan_trash()
if target_category in ("all", "developer"):
    categories["Developer Junk"] = scan_developer()

if tier == "extreme" or target_category == "orphans":
    if target_category in ("all", "orphans"):
        categories["Orphaned Leftovers"] = scan_orphans()
if tier == "extreme" or target_category == "ai":
    if target_category in ("all", "ai"):
        categories["AI Agent Artifacts (>7d)"] = scan_ai_artifacts()

total_bytes = sum(sum(i["bytes"] for i in items) for items in categories.values())
total_items = sum(len(items) for items in categories.values())

if json_output:
    out = {
        "tier": tier,
        "categories": {k: {"items": v, "bytes": sum(i["bytes"] for i in v), "count": len(v)} for k, v in categories.items()},
        "total_bytes": total_bytes,
        "formatted_total": format_bytes(total_bytes),
        "total_items": total_items
    }
    print(json.dumps(out, indent=2))
    sys.exit(0)

# Print human summary
print("=" * 64)
tier_label = "STANDARD CLEAN" if tier == "standard" else "EXTREME CLEAN (DEEP)"
print(f"  Hog Hunter — Hard Disk Clutter Scan [{tier_label}]")
print("=" * 64)

if tier == "extreme":
    print("\n⚠️  EXTREME CLEAN NOTICE:")
    print("   Extreme Clean scans uninstalled app leftovers and inactive AI agent")
    print("   transcripts (>7 days old). Active sessions and git repos are preserved,")
    print("   but older historical conversation logs will be reclaimed.")

for cat_name, items in categories.items():
    cat_bytes = sum(i["bytes"] for i in items)
    print(f"\n📂 {cat_name}: {format_bytes(cat_bytes)} ({len(items)} items)")
    items_sorted = sorted(items, key=lambda x: x["bytes"], reverse=True)
    for it in items_sorted[:6]:
        rel_path = it["path"].replace(home, "~")
        print(f"   • {it['title']} — {format_bytes(it['bytes'])} ({rel_path})")
    if len(items_sorted) > 6:
        print(f"   ... and {len(items_sorted) - 6} more items")

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

    if tier == "extreme" and not confirm_extreme:
        if auto_confirm:
            print("\nError: --tier extreme requires --confirm-extreme to bypass interactive confirmation.", file=sys.stderr)
            sys.exit(1)
        print("\n⚠️  EXTREME CLEAN CONFIRMATION:")
        print("   This operation will delete orphaned application support folders and")
        print("   inactive AI agent chat transcripts older than 7 days.")
        ack = input("   Type 'I UNDERSTAND' to proceed with Extreme Clean: ").strip()
        if ack != "I UNDERSTAND":
            print("Aborted. Extreme Clean disclaimer not acknowledged.")
            sys.exit(1)
    elif not auto_confirm:
        resp = input(f"\nProceed with cleaning {format_bytes(total_bytes)}? (y/N): ").strip().lower()
        if resp != "y":
            print("Aborted by user.")
            sys.exit(0)

    print("\n📸 Creating APFS local snapshot safety rollback...")
    snap_info = create_apfs_snapshot()
    if not snap_info:
        print("error: APFS snapshot failed.  Nothing was deleted.", file=sys.stderr)
        sys.exit(1)
    print(f"   {snap_info}")

    print("\nReclaiming disk space...")
    cleaned_bytes = 0
    cleaned_count = 0
    errors = []

    for cat_name, items in categories.items():
        for it in items:
            p = it["path"]
            if not is_safe_to_delete(p):
                errors.append(f"Skipped unsafe path: {p}")
                continue

            try:
                if "/.Trash/" in p or p.endswith("/.Trash"):
                    if os.path.isfile(p) or os.path.islink(p):
                        os.unlink(p)
                    else:
                        shutil.rmtree(p)
                else:
                    # Path is an argv element, never interpolated into the script.
                    # Finder failure skips the item.  A direct rmtree here is permanent.
                    script = (
                        'on run argv\n'
                        'tell application "Finder" to delete POSIX file (item 1 of argv)\n'
                        'end run'
                    )
                    res = subprocess.run(
                        ["osascript", "-e", script, p],
                        capture_output=True, text=True, check=False
                    )
                    if res.returncode != 0:
                        errors.append(f"Finder did not move {p} to the Trash.  It was left in place.")
                        continue

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
