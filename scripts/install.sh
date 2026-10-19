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
  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "unknown")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || echo "")"
  if [[ -n "$build" && "$build" != "$short" ]]; then
    echo "$short ($build)"
  else
    echo "$short"
  fi
}

echo "Generating the Xcode project."
xcodegen generate

BUILD_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
MARKETING_VERSION="1.0.${BUILD_COUNT}"
echo "Building Release version $MARKETING_VERSION (build $BUILD_COUNT)."
# SENTRY_DSN_MACOS wins when both are set (fleet split).  The value is passed
# as an xcodebuild setting and never printed.  Empty keeps Sentry inert.
{ set +x; } 2>/dev/null
SENTRY_DSN_FLAGS=()
MAC_SENTRY_DSN="${SENTRY_DSN_MACOS:-${SENTRY_DSN:-}}"
if [[ -n "$MAC_SENTRY_DSN" ]]; then
  SENTRY_DSN_FLAGS+=(SENTRY_DSN="$MAC_SENTRY_DSN")
  echo "SENTRY_DSN present for the Mac archive (length ${#MAC_SENTRY_DSN})."
else
  echo "SENTRY_DSN unset; this install ships with Sentry Cocoa inert."
fi
unset MAC_SENTRY_DSN
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_COUNT" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGNING_ALLOWED=NO \
  ${SENTRY_DSN_FLAGS[@]+"${SENTRY_DSN_FLAGS[@]}"}

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH." >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_COUNT" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_COUNT" "$INFO_PLIST"

# Sparkle auto-update feed and public key for the installed Release bundle.
#
# Only for a build cut from main and signed with the real Developer ID.  A
# developer build sits at a commit no release has published, so a working feed
# points it at a newer production release and Sparkle silently replaces the
# working copy under the developer - losing the very build they were testing.
# Gate the feed on the same conditions that make it legitimate.
SPARKLE_FEED_URL="https://github.com/Simple-With-Us/HogHunter/releases/latest/download/appcast.xml"
# Same shape as scripts/mac-release-build.sh: an overridable default so the
# release path and the local path cannot drift apart.  This is Sparkle's PUBLIC
# EdDSA key - it verifies a downloaded archive, it cannot sign one.
SPARKLE_PUBLIC_ED_KEY="${HOGHUNTER_SPARKLE_PUBLIC_KEY:-8nQ6+N6opPFZYkZUgMtyvfbqZH92Kpw3haG/6trehuE=}"  # gitleaks:allow

# Resolved before the Sparkle gate below, which needs the answer.  Kept in one
# place so the signing block further down cannot disagree with it.
DEVELOPER_ID_AVAILABLE=0
if [[ "$ADHOC" -eq 1 ]]; then
  : # --adhoc requested; skip the Developer ID check entirely.
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  DEVELOPER_ID_AVAILABLE=1
fi

_on_main=0
[[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)" == "main" ]] && _on_main=1

if [[ "$_on_main" -eq 1 && "$DEVELOPER_ID_AVAILABLE" -eq 1 && "$ADHOC" -ne 1 ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
  for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates SUVerifyUpdateBeforeExtraction; do
    /usr/libexec/PlistBuddy -c "Set :$key true" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :$key bool true" "$INFO_PLIST"
  done
  /usr/libexec/PlistBuddy -c "Set :SUScheduledCheckInterval 3600" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 3600" "$INFO_PLIST"
else
  # Explicitly off, not merely absent: a stale key inherited from project.yml
  # would otherwise still point the developer build at the production feed.
  for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates; do
    /usr/libexec/PlistBuddy -c "Set :$key false" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :$key bool false" "$INFO_PLIST"
  done
  echo "Sparkle auto-update off (not a signed main build); this copy will not self-update."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: built $APP_PATH."
  echo "Would sign it, quit the running Hog Hunter, install to $INSTALLED_PATH, and launch it.  Doing none of that."
  echo "Hog Hunter $(version_of "$APP_PATH") (dry run, not installed)."
  exit 0
fi

# The bundle is built with CODE_SIGNING_ALLOWED=NO, so it carries no
# entitlement in its signature yet.  Every re-sign below must therefore name
# the entitlements file explicitly: omit it and the App Group is dropped in
# silence, and the installed app loses the shared container that DiskCleaner,
# CleanRegimen and InfisicalSettings read (and that the iPhone companion
# writes).  scripts/mac-release-build.sh passes the same flag.
ENTITLEMENTS_FILE="$REPO_ROOT/HogHunter.entitlements"
if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "error: entitlements file missing at $ENTITLEMENTS_FILE" >&2
  exit 1
fi

sign_adhoc() {
  local reason="$1"
  echo "Signing adhoc ($reason)."
  codesign --force --deep --entitlements "$ENTITLEMENTS_FILE" --sign - "$APP_PATH"
}

# DEVELOPER_ID_AVAILABLE is resolved above, before the Sparkle gate needs it.
if [[ "$DEVELOPER_ID_AVAILABLE" -eq 1 ]]; then
  echo "Signing with Developer ID Application.  20 second timeout."
  # macOS has no `timeout` binary, so bound codesign with perl's alarm instead.
  if perl -e 'alarm 20; exec @ARGV or exit 1' codesign --force --deep --options runtime --timestamp=none \
      --entitlements "$ENTITLEMENTS_FILE" \
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
  sleep 1
  if pgrep -x HogHunter >/dev/null 2>&1; then
    pkill -9 -x HogHunter || true
  fi
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
