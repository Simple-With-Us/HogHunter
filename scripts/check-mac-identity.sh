#!/bin/bash
# Refuse a Hog Hunter bundle whose code identity is not the production one.
#
# Usage: scripts/check-mac-identity.sh [--identity-only] PATH/TO/App.app
#   --identity-only  Skip the seal check, for a caller that has just done it.
#
# macOS records a privacy grant (Full Disk Access, removable volumes, and the
# rest) against the app's designated requirement.  An update keeps its grants
# only when that requirement is unchanged, so this is the one thing a release
# or an install must never change.  The expected requirement is spelled out in
# full on purpose: a change to it is a change to every grant the owner has made,
# and it should have to be made here, deliberately.
#
# Exit 0 when the identity matches, 2 when it does not, 64 on bad usage.
set -euo pipefail

EXPECTED_BUNDLE_ID="com.simplewithus.hoghunter.macos"
EXPECTED_TEAM_ID="CC8UTF7ATG"
EXPECTED_REQUIREMENT="identifier \"$EXPECTED_BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = $EXPECTED_TEAM_ID"

CHECK_SEAL=1
if [[ "${1:-}" == "--identity-only" ]]; then
  CHECK_SEAL=0
  shift
fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--identity-only] PATH/TO/App.app" >&2
  exit 64
fi
APP="$1"

refuse() {
  echo "error: $APP is not the production Hog Hunter identity: $1" >&2
  echo "Installing or publishing it would orphan every privacy grant the owner has made." >&2
  exit 2
}

[[ -f "$APP/Contents/Info.plist" ]] || refuse "no Contents/Info.plist"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || refuse "bundle id is '$bundle_id', expected '$EXPECTED_BUNDLE_ID'"

details="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if grep -q 'Signature=adhoc' <<<"$details" || grep -Eq '^CodeDirectory .*flags=[^ ]*adhoc' <<<"$details"; then
  refuse "it is signed ad hoc, so its identity changes with every build"
fi
team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -n 1)"
[[ "$team" == "$EXPECTED_TEAM_ID" ]] || refuse "Team ID is '${team:-none}', expected '$EXPECTED_TEAM_ID'"
authority="$(sed -n 's/^Authority=//p' <<<"$details" | head -n 1)"
[[ "$authority" == "Developer ID Application: "* ]] || refuse "first signing authority is '${authority:-none}', expected a Developer ID Application certificate"

requirement="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p' | head -n 1 || true)"
# codesign prints the leaf OU bare for a Team ID that starts with a letter and
# quoted otherwise; both spell the same requirement, so both are accepted.
QUOTED_REQUIREMENT="${EXPECTED_REQUIREMENT%= $EXPECTED_TEAM_ID}= \"$EXPECTED_TEAM_ID\""
[[ "$requirement" == "$EXPECTED_REQUIREMENT" || "$requirement" == "$QUOTED_REQUIREMENT" ]] || refuse "designated requirement is '${requirement:-none}', expected '$EXPECTED_REQUIREMENT'"

if [[ "$CHECK_SEAL" -eq 1 ]]; then
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || refuse "codesign --verify --deep --strict failed, so macOS would not honor its identity"
fi

echo "Identity ok: $EXPECTED_BUNDLE_ID, Team ID $EXPECTED_TEAM_ID, Developer ID."
