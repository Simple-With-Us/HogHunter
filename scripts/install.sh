#!/bin/bash
# Build Hog Hunter Release, sign it, and install it.
#
# Usage: scripts/install.sh [--adhoc] [--no-launch] [--dry-run] [--dest PATH]
#   --adhoc      Sign ad hoc, for a throwaway copy only.  Needs an explicit --dest
#                outside /Applications and ~/Applications, and never launches:
#                see "Code identity" below.
#   --no-launch  Install but do not open Hog Hunter afterward.
#   --dry-run    Build only.  Print what would happen next.  Never sign,
#                quit the running app, copy to the destination, or launch.
#   --dest PATH  Directory to install HogHunter.app into.  Default: if
#                /Applications/HogHunter.app already exists, install there;
#                otherwise install to ~/Applications.
#
# Code identity.  macOS keeps a privacy grant (Full Disk Access, removable
# volumes, and the rest) against the app's designated requirement.  A Developer
# ID build's requirement is the bundle id plus the Team ID, so it survives every
# update.  An ad hoc build's requirement is its own hash, so every build is a new
# app to macOS and every grant has to be made again.  This script therefore
# refuses to put anything but the production identity in a production location,
# and refuses to leave two copies there.
#
# Exit codes: 3 no usable identity, 4 a second copy would exist, 5 signing failed.
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

EXPECTED_TEAM_ID="CC8UTF7ATG"

# Compares resolved paths, so a trailing slash or a symlink cannot walk an ad hoc
# copy into a production location.
resolved_dir() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "${1%/}"
}

is_production_dir() {
  # Containment, not equality: a folder inside /Applications is still production.
  local resolved production
  resolved="$(resolved_dir "$1")"
  for production in "$(resolved_dir "$SYSTEM_APPLICATIONS")" "$(resolved_dir "$USER_APPLICATIONS")"; do
    if [[ "$resolved" == "$production" || "$resolved" == "$production/"* ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "$ADHOC" -eq 1 ]]; then
  if [[ -z "$DEST_ARG" ]] || is_production_dir "$DEST_DIR"; then
    echo "error: refusing an ad hoc install to $DEST_DIR." >&2
    echo "An ad hoc build is a new app to macOS each time, so the owner would be asked for every permission again." >&2
    echo "Pass --dest with a throwaway folder outside /Applications and ~/Applications, or drop --adhoc." >&2
    exit 3
  fi
  if [[ "$NO_LAUNCH" -eq 0 ]]; then
    echo "Not launching: an ad hoc build carries the production bundle id, and a grant made to it would displace the real app's."
    NO_LAUNCH=1
  fi
fi

# Names the certificate in full, Team ID included, so a second team's identity in
# the keychain can never be picked up by a partial match.
SIGNING_IDENTITY=""
if [[ "$ADHOC" -ne 1 ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^.*\"\(Developer ID Application:[^\"]*($EXPECTED_TEAM_ID)\)\".*$/\1/p" | head -n 1 || true)"
  if [[ -z "$SIGNING_IDENTITY" && "$DRY_RUN" -ne 1 ]]; then
    echo "error: no Developer ID Application identity for team $EXPECTED_TEAM_ID in the keychain." >&2
    echo "Refusing to install: without it the app would lose every permission the owner has granted." >&2
    exit 3
  fi
fi

# One installed copy.  Two copies with one bundle id fight over the menu bar, and
# LaunchServices may open the stale one.
if [[ "$ADHOC" -ne 1 ]]; then
  for candidate_dir in "$SYSTEM_APPLICATIONS" "$USER_APPLICATIONS"; do
    # Resolved, so `--dest ~/Applications/` is an update in place, not a second copy.
    [[ "$(resolved_dir "$candidate_dir")" == "$(resolved_dir "$DEST_DIR")" ]] && continue
    for other in "$candidate_dir/Hog Hunter.app" "$candidate_dir/HogHunter.app"; do
      if [[ -d "$other" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          echo "Warning: a real install would refuse, because a copy already exists at $other."
        else
          echo "error: refusing to create a second copy; one already exists at $other." >&2
          echo "Remove it, or pass --dest with its folder to update it in place." >&2
          exit 4
        fi
      fi
    done
  done
fi

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

BUILD_COUNT="${HOGHUNTER_BUILD_NUMBER:-1000}"
[[ "$BUILD_COUNT" =~ ^[1-9][0-9]{3,11}$ ]] || { echo "Invalid build number; expected an integer of at least1000." >&2; exit 1; }
MARKETING_VERSION="0.1.0"
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
[[ -n "$SIGNING_IDENTITY" ]] && DEVELOPER_ID_AVAILABLE=1

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
sign_developer_id_nested() {
  # Inside-out like scripts/mac-release-build.sh: each nested bundle seals
  # its own code, then the framework, then the app.  A single --deep seals
  # whatever it finds instead of signing it, and --timestamp=none leaves
  # the signature without a secure timestamp.  macOS has no `timeout`
  # binary, so each step keeps the 20 second bound via perl's alarm.
  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    perl -e 'alarm 20; exec @ARGV or exit 1' codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$target" || return 1
  done < <(
    /usr/bin/find "$APP_PATH/Contents/Frameworks" -mindepth 1 \( -name '*.xpc' -o -name '*.app' \) -type d 2>/dev/null
    /usr/bin/find "$APP_PATH/Contents/Frameworks" -mindepth 1 -type f -perm -u+x 2>/dev/null
  )
  local fw
  for fw in "$APP_PATH"/Contents/Frameworks/*.framework; do
    [[ -e "$fw" ]] || continue
    perl -e 'alarm 20; exec @ARGV or exit 1' codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$fw" || return 1
  done
  perl -e 'alarm 20; exec @ARGV or exit 1' codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign "$SIGNING_IDENTITY" "$APP_PATH" || return 1
}
if [[ "$DEVELOPER_ID_AVAILABLE" -eq 1 ]]; then
  echo "Signing with Developer ID Application, nested code first.  20 second timeout per step."
  # Never falls back to ad hoc: that used to replace the installed app with one
  # macOS treats as new, and the owner lost every grant to a signing timeout.
  if sign_developer_id_nested; then
    echo "Signed with Developer ID Application."
  else
    echo "error: Developer ID signing failed or timed out.  Nothing was installed." >&2
    exit 5
  fi
else
  sign_adhoc "--adhoc requested"
fi

echo "Verifying the signature."
codesign --verify --deep --strict "$APP_PATH"
echo "Entitlements (get-task-allow should be absent):"
codesign -d --entitlements - "$APP_PATH"
if [[ "$ADHOC" -ne 1 ]]; then
  "$REPO_ROOT/scripts/check-mac-identity.sh" --identity-only "$APP_PATH"
fi

# Staged beside the destination and checked before the running app is touched.
# ditto merges into an existing bundle, so installing straight over one can leave
# files the signature does not cover, and a broken seal is a broken identity.
mkdir -p "$DEST_DIR"
STAGE_DIR="$(mktemp -d "$DEST_DIR/.hoghunter-install.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGED_PATH="$STAGE_DIR/Hog Hunter.app"
ditto "$APP_PATH" "$STAGED_PATH"
xattr -cr "$STAGED_PATH" || true
if [[ "$ADHOC" -ne 1 ]]; then
  "$REPO_ROOT/scripts/check-mac-identity.sh" "$STAGED_PATH"
fi

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
# The previous bundle waits beside the destination, outside STAGE_DIR, so the EXIT
# trap cannot delete it.  It is removed only once the new bundle is in place and
# verified; a failed swap puts it back.
BACKUP_DIR=""
if [[ -e "$INSTALLED_PATH" ]]; then
  BACKUP_DIR="$(mktemp -d "$DEST_DIR/.hoghunter-previous.XXXXXX")"
  mv "$INSTALLED_PATH" "$BACKUP_DIR/Hog Hunter.app"
fi
if ! mv "$STAGED_PATH" "$INSTALLED_PATH"; then
  if [[ -n "$BACKUP_DIR" ]]; then
    mv "$BACKUP_DIR/Hog Hunter.app" "$INSTALLED_PATH" || true
    rmdir "$BACKUP_DIR" 2>/dev/null || true
  fi
  echo "error: could not move the new Hog Hunter into place.  The previous copy was restored." >&2
  exit 6
fi
if [[ -n "$BACKUP_DIR" ]]; then
  if codesign --verify --deep --strict "$INSTALLED_PATH" \
    && { [[ "$ADHOC" -eq 1 ]] || "$REPO_ROOT/scripts/check-mac-identity.sh" "$INSTALLED_PATH"; }; then
    rm -rf "$BACKUP_DIR"
  else
    echo "error: the installed copy failed verification.  The previous copy is kept at $BACKUP_DIR/Hog Hunter.app." >&2
    exit 6
  fi
fi

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

# Spotlight still lists a renamed backup as this app, and it can be launched by
# accident.  Named, not touched: it may be someone's rollback.
for backup in "$DEST_DIR"/"Hog Hunter.app".* "$DEST_DIR"/HogHunter.app.*; do
  [[ -e "$backup" ]] && echo "Warning: a backup copy of this app is at $backup -- consider removing it."
done

echo "Installed Hog Hunter $(version_of "$INSTALLED_PATH") to $INSTALLED_PATH."
