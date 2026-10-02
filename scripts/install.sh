#!/bin/bash
# Build Hog Hunter Release, sign it, and install it.
#
# Usage: scripts/install.sh [--adhoc] [--no-launch] [--dry-run] [--dest PATH]
#   --adhoc      Skip Developer ID signing even if the identity is available.
#   --no-launch  Install but do not open Hog Hunter afterward.
#   --dry-run    Build only.  Print what would happen next.  Never sign,
#                quit the running app, copy to the destination, or launch.
#   --dest PATH  Directory to install HogHunter.app into.  Default: if
#                /Applications/HogHunter.app already exists, install there;
#                otherwise install to ~/Applications.
set -euo pipefail

ADHOC=0
NO_LAUNCH=0
DRY_RUN=0
DEST_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc) ADHOC=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --dest)
      if [[ $# -lt 2 ]]; then
        echo "--dest requires a PATH argument" >&2
        exit 1
      fi
      DEST_ARG="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--adhoc] [--no-launch] [--dry-run] [--dest PATH]" >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_PATH="build/Build/Products/Release/HogHunter.app"

SYSTEM_APPLICATIONS="/Applications"
USER_APPLICATIONS="$HOME/Applications"

if [[ -n "$DEST_ARG" ]]; then
  DEST_DIR="$DEST_ARG"
  echo "Destination: $DEST_DIR (explicit --dest)."
elif [[ -d "$SYSTEM_APPLICATIONS/Hog Hunter.app" || -d "$SYSTEM_APPLICATIONS/HogHunter.app" ]]; then
  DEST_DIR="$SYSTEM_APPLICATIONS"
  echo "Destination: $DEST_DIR (found an existing install there)."
else
  DEST_DIR="$USER_APPLICATIONS"
  echo "Destination: $DEST_DIR (default; no existing install found in $SYSTEM_APPLICATIONS)."
fi

# The bundle is installed under its display name, "Hog Hunter.app", so Finder,
# Get Info and LaunchServices all agree on what the app is called.  The
# executable inside is still named HogHunter, which is what `pgrep -x` matches.
INSTALLED_PATH="$DEST_DIR/Hog Hunter.app"
# Releases before 2026-10-01 installed as HogHunter.app.  Those copies are
# retired below so there is never a stale second copy holding the menu bar.
LEGACY_PATH="$DEST_DIR/HogHunter.app"

version_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "unknown"
}

echo "Generating the Xcode project."
xcodegen generate

echo "Building Release."
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: built $APP_PATH."
  echo "Would sign it, quit the running Hog Hunter, install to $INSTALLED_PATH, and launch it.  Doing none of that."
  echo "Hog Hunter $(version_of "$APP_PATH") (dry run, not installed)."
  exit 0
fi

sign_adhoc() {
  local reason="$1"
  echo "Signing adhoc ($reason)."
  codesign --force --deep --sign - "$APP_PATH"
}

DEVELOPER_ID_AVAILABLE=0
if [[ "$ADHOC" -eq 1 ]]; then
  : # --adhoc requested; skip the Developer ID check entirely.
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  DEVELOPER_ID_AVAILABLE=1
fi

if [[ "$DEVELOPER_ID_AVAILABLE" -eq 1 ]]; then
  echo "Signing with Developer ID Application.  20 second timeout."
  # macOS has no `timeout` binary, so bound codesign with perl's alarm instead.
  if perl -e 'alarm 20; exec @ARGV or exit 1' codesign --force --deep --options runtime --timestamp=none \
      --sign "Developer ID Application" "$APP_PATH"; then
    echo "Signed with Developer ID Application."
  else
    sign_adhoc "Developer ID signing failed or timed out"
  fi
elif [[ "$ADHOC" -eq 1 ]]; then
  sign_adhoc "--adhoc requested"
else
  sign_adhoc "no Developer ID Application identity in keychain"
fi

echo "Verifying the signature."
codesign --verify --deep --strict "$APP_PATH"
echo "Entitlements (get-task-allow should be absent):"
codesign -d --entitlements - "$APP_PATH"

echo "Quitting the running Hog Hunter, if any."
# Both names: an old copy is still called HogHunter on disk, and AppleScript
# resolves the app by its installed display name.
osascript -e 'tell application "Hog Hunter" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "HogHunter" to quit' >/dev/null 2>&1 || true
sleep 5
if pgrep -x HogHunter >/dev/null 2>&1; then
  echo "Hog Hunter is still running.  Forcing it to quit."
  pkill -x HogHunter || true
fi

echo "Installing to $INSTALLED_PATH."
mkdir -p "$DEST_DIR"
ditto "$APP_PATH" "$INSTALLED_PATH"
xattr -cr "$INSTALLED_PATH" || true

# Retire the pre-rename copy, but only after confirming it is this app and not
# something else that happens to share the old filename.
if [[ -d "$LEGACY_PATH" && "$LEGACY_PATH" != "$INSTALLED_PATH" ]]; then
  legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  new_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ -n "$legacy_id" && "$legacy_id" == "$new_id" ]]; then
    echo "Removing the pre-rename copy at $LEGACY_PATH (same bundle id)."
    rm -rf "$LEGACY_PATH"
  else
    echo "Warning: $LEGACY_PATH exists but its bundle id is not $new_id -- leaving it alone."
  fi
fi

if [[ "$NO_LAUNCH" -eq 0 ]]; then
  echo "Launching Hog Hunter."
  open "$INSTALLED_PATH"
else
  echo "Skipping launch (--no-launch)."
fi

# Warn if the other well-known location also holds a copy, so it doesn't
# quietly run stale or fight over the menu bar item.  Doesn't touch it.
OTHER_DIR=""
if [[ "$DEST_DIR" == "$SYSTEM_APPLICATIONS" ]]; then
  OTHER_DIR="$USER_APPLICATIONS"
elif [[ "$DEST_DIR" == "$USER_APPLICATIONS" ]]; then
  OTHER_DIR="$SYSTEM_APPLICATIONS"
fi
if [[ -n "$OTHER_DIR" ]]; then
  for other in "$OTHER_DIR/Hog Hunter.app" "$OTHER_DIR/HogHunter.app"; do
    if [[ -d "$other" ]]; then
      echo "Warning: a duplicate copy also exists at $other -- consider removing it."
    fi
  done
fi

echo "Installed Hog Hunter $(version_of "$INSTALLED_PATH") to $INSTALLED_PATH."
