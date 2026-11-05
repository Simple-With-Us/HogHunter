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
#   --dest PATH  Directory to install Hog Hunter.app into.  Default: if
#                /Applications holds a copy, in any folder or left aside by an
#                interrupted install, install there; otherwise ~/Applications.
#
# Code identity.  macOS keeps a privacy grant (Full Disk Access, removable
# volumes, and the rest) against the app's designated requirement.  A Developer
# ID build's requirement is the bundle id plus the Team ID, so it survives every
# update.  An ad hoc build's requirement is its own hash, so every build is a new
# app to macOS and every grant has to be made again.  This script therefore
# refuses to put anything but the production identity in a production location,
# and refuses to leave two copies there.
#
# Exit codes: 1 bad arguments or a failed build, 3 no usable identity, 4 a second
# copy would exist, 5 signing failed, 6 the new copy could not be put in place or
# failed its check.
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
      # An empty value is refused too: an unset variable in a caller must not turn a
      # scoped install into a production one.
      if [[ $# -lt 2 || -z "$2" ]]; then
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

# A relative --dest means the folder the caller is in, so it is settled before the
# script moves to the repository.
if [[ -n "$DEST_ARG" && "$DEST_ARG" != /* ]]; then
  DEST_ARG="$PWD/$DEST_ARG"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_PATH="build/Build/Products/Release/HogHunter.app"

SYSTEM_APPLICATIONS="/Applications"
USER_APPLICATIONS="$HOME/Applications"

# Every copy of this app under a production folder, one path per line: at the top,
# in a subfolder, or set aside in a .hoghunter-* folder by an interrupted install.
# Bundles are pruned, so the walk stays small and never reads inside one.
copies_under() {
  /usr/bin/find -H "$1" \( -type d -o -type l \) -iname '*.app' -prune \
    \( -iname 'hog hunter.app' -o -iname 'hoghunter.app' \) -print 2>/dev/null || true
}

if [[ -n "$DEST_ARG" ]]; then
  DEST_DIR="$DEST_ARG"
  echo "Destination: $DEST_DIR (explicit --dest)."
elif [[ -d "$SYSTEM_APPLICATIONS/Hog Hunter.app" || -d "$SYSTEM_APPLICATIONS/HogHunter.app" ]]; then
  DEST_DIR="$SYSTEM_APPLICATIONS"
  echo "Destination: $DEST_DIR (found an existing install there)."
elif [[ -n "$(copies_under "$SYSTEM_APPLICATIONS")" ]]; then
  # The app's only copy may be the hidden one, so the install stays where it was.
  DEST_DIR="$SYSTEM_APPLICATIONS"
  echo "Destination: $DEST_DIR (found a copy of this app there that is not at the top of the folder)."
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

# Folders are compared by device and inode, never by text.  `pwd -P` keeps the case
# as typed, so on a case-insensitive volume /applications reads as a different
# folder from /Applications while being the same one.
dir_identity() {
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Splits a path into the deepest ancestor that exists, as a physical path, and the
# part still to be created: SPLIT_BASE and SPLIT_REST.  Fails when the path cannot
# be judged.  A dangling symlink could point anywhere, and `..` below a folder that
# does not exist yet climbs back out of it once `mkdir -p` has created it.
split_existing() {
  local path="$1" rest="" name parent
  while [[ ! -e "$path" ]]; do
    [[ ! -L "$path" ]] || return 1
    name="$(basename "$path")"
    [[ "$name" != ".." ]] || return 1
    [[ "$name" == "." ]] || rest="$name${rest:+/$rest}"
    parent="$(dirname "$path")"
    [[ "$parent" != "$path" ]] || return 1
    path="$parent"
  done
  SPLIT_BASE="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
  SPLIT_REST="$rest"
}

# Both spellings name one folder, whether or not it exists yet.
same_dir() {
  local base rest id
  split_existing "$1" || return 1
  base="$SPLIT_BASE"
  rest="$SPLIT_REST"
  split_existing "$2" || return 1
  [[ "$(lowercase "$rest")" == "$(lowercase "$SPLIT_REST")" ]] || return 1
  id="$(dir_identity "$base")" || return 1
  [[ -n "$id" && "$id" == "$(dir_identity "$SPLIT_BASE")" ]]
}

# Containment, not equality: a folder inside /Applications is still production, so
# every parent of the destination counts.  A path that cannot be judged counts too.
is_production_dir() {
  local base rest production id walk parent missing
  split_existing "$1" || return 0
  base="$SPLIT_BASE"
  rest="$(lowercase "$SPLIT_REST")"
  for production in "$SYSTEM_APPLICATIONS" "$USER_APPLICATIONS"; do
    if [[ -e "$production" ]]; then
      id="$(dir_identity "$production")" || return 0
      [[ -n "$id" ]] || return 0
      walk="$base"
      while true; do
        [[ "$(dir_identity "$walk")" != "$id" ]] || return 0
        parent="$(dirname "$walk")"
        [[ "$parent" != "$walk" ]] || break
        walk="$parent"
      done
    else
      # Not there yet, so there is no inode to compare.  The destination would
      # become it if it grows from the same existing folder under the same name.
      split_existing "$production" || return 0
      missing="$(lowercase "$SPLIT_REST")"
      id="$(dir_identity "$SPLIT_BASE")" || return 0
      if [[ "$id" == "$(dir_identity "$base")" && ( "$rest" == "$missing" || "$rest" == "$missing/"* ) ]]; then
        return 0
      fi
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
WOULD_REFUSE=0
if [[ "$ADHOC" -ne 1 ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^.*\"\(Developer ID Application:[^\"]*($EXPECTED_TEAM_ID)\)\".*$/\1/p" | head -n 1 || true)"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "Warning: a real install would refuse, because there is no Developer ID Application identity for team $EXPECTED_TEAM_ID in the keychain."
      WOULD_REFUSE=1
    else
      echo "error: no Developer ID Application identity for team $EXPECTED_TEAM_ID in the keychain." >&2
      echo "Refusing to install: without it the app would lose every permission the owner has granted." >&2
      exit 3
    fi
  fi
fi

# One installed copy.  Two copies with one bundle id fight over the menu bar, and
# LaunchServices may open the stale one.
if [[ "$ADHOC" -ne 1 ]]; then
  for candidate_dir in "$SYSTEM_APPLICATIONS" "$USER_APPLICATIONS"; do
    while IFS= read -r other; do
      # What an interrupted install set aside belongs to the folder it sits in, and
      # a later step of this run retires it when that folder is the destination.
      copy_folder="$(dirname "$other")"
      case "$(basename "$copy_folder")" in
        .hoghunter-previous.*|.hoghunter-install.*) copy_folder="$(dirname "$copy_folder")" ;;
      esac
      # By identity, so `--dest ~/Applications/` or `~/applications` is an update in
      # place, not a second copy.
      if same_dir "$copy_folder" "$DEST_DIR"; then
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Warning: a real install would refuse, because a copy already exists at $other."
        WOULD_REFUSE=1
      else
        echo "error: refusing to create a second copy; one already exists at $other." >&2
        echo "Remove it, or pass --dest with its folder to update it in place." >&2
        exit 4
      fi
    done < <(copies_under "$candidate_dir")
  done
fi

# An interrupted install can leave a folder of ours beside the destination, each
# holding a validly signed copy of this app that Spotlight can still find.  A later
# run names them now and retires them only once its own copy is in place and has
# passed its check, so the one copy left on disk is never the one removed.
report_leftovers() {
  local folder
  for folder in "$DEST_DIR"/.hoghunter-previous.* "$DEST_DIR"/.hoghunter-install.*; do
    [[ -d "$folder" && ! -L "$folder" ]] || continue
    if [[ ! -e "$folder/Hog Hunter.app" ]]; then
      echo "Warning: an interrupted install left $folder, with no app inside.  A finished install removes it."
    elif [[ -e "$INSTALLED_PATH" ]]; then
      echo "Warning: an interrupted install left a copy of this app at $folder/Hog Hunter.app.  A finished install removes it."
    else
      echo "Warning: an interrupted install left a copy of this app at $folder/Hog Hunter.app, and nothing is installed at $INSTALLED_PATH.  It may be the only copy.  It stays until a new copy has passed its check."
    fi
  done
}
report_leftovers

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
  if [[ "$WOULD_REFUSE" -eq 1 ]]; then
    echo "A real install would stop at the refusal above and change nothing.  Doing none of it."
  elif [[ "$ADHOC" -eq 1 ]]; then
    echo "Would sign it ad hoc, leave the running Hog Hunter alone, stop only a copy running from $DEST_DIR, install to $INSTALLED_PATH, and not launch it.  Doing none of that."
  elif [[ "$NO_LAUNCH" -eq 1 ]]; then
    echo "Would sign it with Developer ID, quit the running Hog Hunter, install to $INSTALLED_PATH, and leave it closed.  Doing none of that."
  else
    echo "Would sign it with Developer ID, quit the running Hog Hunter, install to $INSTALLED_PATH, and launch it.  Doing none of that."
  fi
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
elif ! sign_adhoc "--adhoc requested"; then
  echo "error: ad hoc signing failed.  Nothing was installed." >&2
  exit 5
fi

echo "Verifying the signature."
if ! codesign --verify --deep --strict "$APP_PATH"; then
  echo "error: the signature did not verify.  Nothing was installed." >&2
  exit 5
fi
echo "Entitlements (get-task-allow should be absent):"
codesign -d --entitlements - "$APP_PATH"
if [[ "$ADHOC" -ne 1 ]] && ! "$REPO_ROOT/scripts/check-mac-identity.sh" --identity-only "$APP_PATH"; then
  echo "error: the build failed its identity check.  Nothing was installed." >&2
  exit 6
fi

STAGE_DIR=""
STAGED_PATH=""
BACKUP_DIR=""
SWAP_COMMITTED=0
SWAP_ABORTED=0
QUIT_FOR_INSTALL=0
MOVING_NEW_COPY=0
LAUNCH_ATTEMPTED=0
FINAL_STATUS=0

# Puts the previous copy back.  It sits outside STAGE_DIR, so nothing but this moves
# it, and whatever is at the installed path while it is aside is the new copy.
restore_previous() {
  if [[ -e "$INSTALLED_PATH" || -L "$INSTALLED_PATH" ]]; then
    mv "$INSTALLED_PATH" "$STAGE_DIR/rejected.app" || return 1
  fi
  mv "$BACKUP_DIR/Hog Hunter.app" "$INSTALLED_PATH" || return 1
}

# What is left when there is no previous copy to put back.
nothing_to_restore_text() {
  if [[ -d "$LEGACY_PATH" ]]; then
    echo "Nothing is installed at $INSTALLED_PATH.  The older copy at $LEGACY_PATH is still there."
  else
    echo "There was no previous copy to restore, so nothing is installed at $INSTALLED_PATH."
  fi
}

# Puts things back first and reports after, so a reader that has gone away cannot
# stop the restore: a write to a dead pipe or a closed stderr fails here and nothing
# more.  The report says what is actually on disk, naming the backup if it is there.
abort_swap() {
  local previous="$BACKUP_DIR/Hog Hunter.app"
  local outcome
  trap '' INT TERM HUP PIPE
  set +e
  SWAP_ABORTED=1
  if [[ -n "$BACKUP_DIR" && ( -e "$previous" || -L "$previous" ) ]]; then
    if restore_previous; then
      rmdir "$BACKUP_DIR" 2>/dev/null
      outcome="The previous copy was restored to $INSTALLED_PATH."
    else
      outcome="error: could not restore the previous copy.  It is at $previous.  Move it back to $INSTALLED_PATH by hand."
    fi
  elif [[ "$MOVING_NEW_COPY" -eq 1 && -e "$INSTALLED_PATH" && ! -e "$STAGED_PATH" ]]; then
    # The new copy did move, and it never passed.  There is no previous copy to go back to.
    if mv "$INSTALLED_PATH" "$STAGE_DIR/rejected.app"; then
      outcome="$(nothing_to_restore_text)"
    else
      outcome="error: the copy that failed is still at $INSTALLED_PATH, and there was no previous copy to restore."
    fi
  elif [[ -e "$INSTALLED_PATH" || -L "$INSTALLED_PATH" ]]; then
    outcome="The copy at $INSTALLED_PATH was not changed."
  else
    outcome="$(nothing_to_restore_text)"
  fi
  echo "error: $1" >&2
  echo "$outcome" >&2
  if [[ "$QUIT_FOR_INSTALL" -eq 1 ]]; then
    echo "This install quit the running Hog Hunter and has not reopened it." >&2
  fi
}

# Every way out from here on ends in this trap, a signal included.  Signals are
# ignored for the length of it, so one cannot land between putting the app back and
# clearing up, and it reports nothing until the files are settled.
finish_install() {
  local status=$?
  local previous="$BACKUP_DIR/Hog Hunter.app"
  trap '' INT TERM HUP PIPE
  set +e
  if [[ "$SWAP_COMMITTED" -eq 1 ]]; then
    [[ -z "$BACKUP_DIR" ]] || rm -rf "$BACKUP_DIR"
    if [[ "$status" -ne 0 && "$QUIT_FOR_INSTALL" -eq 1 && "$LAUNCH_ATTEMPTED" -ne 1 ]]; then
      echo "The new copy is installed at $INSTALLED_PATH.  This install quit the running Hog Hunter and has not reopened it." >&2
    fi
  elif [[ "$SWAP_ABORTED" -ne 1 ]]; then
    if [[ "$QUIT_FOR_INSTALL" -eq 1 || "$MOVING_NEW_COPY" -eq 1 ]] \
      || [[ -n "$BACKUP_DIR" && ( -e "$previous" || -L "$previous" ) ]]; then
      abort_swap "the install stopped before the new copy passed its check."
    fi
  fi
  # Only ever an empty folder: rmdir refuses one that still holds the backup.
  [[ -z "$BACKUP_DIR" ]] || rmdir "$BACKUP_DIR" 2>/dev/null
  [[ -z "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"
  exit "$status"
}

installed_copy_verifies() {
  codesign --verify --deep --strict "$INSTALLED_PATH" || return 1
  [[ "$ADHOC" -eq 1 ]] || "$REPO_ROOT/scripts/check-mac-identity.sh" "$INSTALLED_PATH"
}

# True when this process's executable is the copy in the folder being replaced.
# Asks lsof for the mapped executable, which never reads the command line.
running_from_destination() {
  local line
  while IFS= read -r line; do
    [[ "$line" == n* ]] || continue
    if [[ "${line#n}" -ef "$INSTALLED_PATH/Contents/MacOS/HogHunter" || "${line#n}" -ef "$LEGACY_PATH/Contents/MacOS/HogHunter" ]]; then
      return 0
    fi
  done < <(lsof -a -p "$1" -d txt -Fn 2>/dev/null || true)
  return 1
}

# Stops only a copy running from the folder being replaced, by pid.  The names the
# production path quits by would take the owner's real app down too.
stop_copy_running_from_destination() {
  local pid
  for pid in $(pgrep -x HogHunter 2>/dev/null || true); do
    running_from_destination "$pid" || continue
    echo "Stopping the copy running from $DEST_DIR (pid $pid)."
    kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}

# Staged beside the destination and checked before the running app is touched.
# ditto merges into an existing bundle, so installing straight over one can leave
# files the signature does not cover, and a broken seal is a broken identity.
if ! mkdir -p "$DEST_DIR"; then
  echo "error: could not create $DEST_DIR." >&2
  exit 6
fi
# Asked again now the folder exists and minutes have passed: this answer is exact.
if [[ "$ADHOC" -eq 1 ]] && is_production_dir "$DEST_DIR"; then
  echo "error: refusing an ad hoc install to $DEST_DIR, which is now a production location." >&2
  exit 3
fi
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# A reader that goes away must not decide how this ends, and errexit stops here: from
# now on a failed line could strand the app closed or aside, so each step that
# matters is checked by hand and takes its own way out.
trap '' PIPE
set +e

stage_failed() {
  echo "error: $1  The running Hog Hunter was not touched." >&2
  exit 6
}

STAGE_DIR="$(mktemp -d "$DEST_DIR/.hoghunter-install.XXXXXX")" || stage_failed "could not create a staging folder in $DEST_DIR."
STAGED_PATH="$STAGE_DIR/Hog Hunter.app"
ditto "$APP_PATH" "$STAGED_PATH" || stage_failed "could not copy the new Hog Hunter beside the destination."
xattr -cr "$STAGED_PATH"
if [[ "$ADHOC" -ne 1 ]]; then
  "$REPO_ROOT/scripts/check-mac-identity.sh" "$STAGED_PATH" || stage_failed "the staged copy failed its check."
fi

if [[ "$ADHOC" -eq 1 ]]; then
  # A throwaway copy is not the running app, and force-quitting by name here would
  # stop the production app with nothing to reopen it.
  echo "Leaving the running Hog Hunter alone: this is a throwaway copy."
  stop_copy_running_from_destination
else
  echo "Quitting the running Hog Hunter, if any."
  # Status 1 is pgrep's plain "none".  Anything else cannot rule one out.
  pgrep -x HogHunter >/dev/null 2>&1
  if [[ $? -ne 1 ]]; then
    QUIT_FOR_INSTALL=1
  fi
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
fi

echo "Installing to $INSTALLED_PATH."
# The previous bundle waits beside the destination, outside STAGE_DIR, so the EXIT
# trap cannot delete it.  It is removed only once the new bundle is in place and
# verified; a failed swap or an interruption puts it back.
if [[ -e "$INSTALLED_PATH" || -L "$INSTALLED_PATH" ]]; then
  if ! BACKUP_DIR="$(mktemp -d "$DEST_DIR/.hoghunter-previous.XXXXXX")"; then
    BACKUP_DIR=""
    abort_swap "could not make a folder to hold the previous copy."
    exit 6
  fi
  if ! mv "$INSTALLED_PATH" "$BACKUP_DIR/Hog Hunter.app"; then
    abort_swap "could not move the previous copy aside."
    exit 6
  fi
fi
MOVING_NEW_COPY=1
if ! mv "$STAGED_PATH" "$INSTALLED_PATH"; then
  abort_swap "could not move the new Hog Hunter into place."
  exit 6
fi
if ! installed_copy_verifies; then
  abort_swap "the installed copy failed verification."
  exit 6
fi
SWAP_COMMITTED=1

# The new copy has passed.  What remains is tidying and reopening the app, so a
# failure here is a warning and never keeps a good install closed.
if [[ -n "$BACKUP_DIR" ]]; then
  if ! rm -rf "$BACKUP_DIR"; then
    echo "Warning: could not remove the previous copy at $BACKUP_DIR.  The next finished install tries again." >&2
  fi
  BACKUP_DIR=""
fi

# The new copy is in place and has passed, so what an earlier run left is now spare.
for leftover in "$DEST_DIR"/.hoghunter-previous.* "$DEST_DIR"/.hoghunter-install.*; do
  [[ -d "$leftover" && ! -L "$leftover" && "$leftover" != "$STAGE_DIR" ]] || continue
  echo "Removing what an interrupted install left at $leftover."
  if ! rm -rf "$leftover"; then
    echo "Warning: could not remove $leftover.  It may still hold a signed copy of this app.  The next finished install tries again." >&2
  fi
done

# Retire the pre-rename copy, but only after confirming it is this app and not
# something else that happens to share the old filename.
if [[ -d "$LEGACY_PATH" && "$LEGACY_PATH" != "$INSTALLED_PATH" ]]; then
  legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  new_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ -n "$legacy_id" && "$legacy_id" == "$new_id" ]]; then
    echo "Removing the pre-rename copy at $LEGACY_PATH (same bundle id)."
    if ! rm -rf "$LEGACY_PATH"; then
      echo "Warning: could not remove the pre-rename copy at $LEGACY_PATH." >&2
    fi
  else
    echo "Warning: $LEGACY_PATH exists but its bundle id is not $new_id -- leaving it alone."
  fi
fi

if [[ "$NO_LAUNCH" -eq 0 ]]; then
  echo "Launching Hog Hunter."
  LAUNCH_ATTEMPTED=1
  if ! open "$INSTALLED_PATH"; then
    echo "error: the new copy is installed, but it could not be opened.  Hog Hunter is not running." >&2
    FINAL_STATUS=1
  fi
else
  echo "Skipping launch (--no-launch)."
fi

# Spotlight still lists a renamed backup as this app, and it can be launched by
# accident.  Named, not touched: it may be someone's rollback.
for backup in "$DEST_DIR"/"Hog Hunter.app".* "$DEST_DIR"/HogHunter.app.*; do
  [[ -e "$backup" ]] && echo "Warning: a backup copy of this app is at $backup -- consider removing it."
done

echo "Installed Hog Hunter $(version_of "$INSTALLED_PATH") to $INSTALLED_PATH."
exit "$FINAL_STATUS"
