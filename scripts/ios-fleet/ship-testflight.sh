#!/usr/bin/env bash
# ship-testflight.sh - Archive + upload an iOS app to TestFlight without Xcode UI.
#
# Usage:
#   bash /Users/jay/apps/ios-fleet/ship-testflight.sh <socratic|congress|usage|usage-local|dealdex|autorotate|autorotate-mac|contactlogo|contactlogo-mac|botfleet|botfleet-mac|clutch> [options]
#
# Options:
#   --repo-root PATH   Repo root (default: cwd)
#   --build N          Force CURRENT_PROJECT_VERSION (exact; default: the
#                      version itself, so the pair is one number)
#   --version X.Y.Z    Force MARKETING_VERSION (exact; default: the next
#                      number on the app's train)
#   --export-only      Build IPA only; do not upload
#   --upload-only IPA  Skip archive; upload an existing IPA via ASC API key
#   --dry-run          Print plan and exit
#   --skip-xcodegen    Do not regenerate .xcodeproj
#   --allow-dirty      Allow shipping from a dirty git worktree
#   --force-ship       Bypass min-interval + same-HEAD skip (emergency / owner)
#   --sync-project-version  Write the resolved version into project.pbxproj
#   --allow-unverified-seq  Ship even if App Store Connect cannot be consulted
#                           (dangerous: the marketing version and the build
#                           number are then planned from unverified state)
#
# Version numbering (owner directive 2026-10-26, HH-191; replaces the
# 2026-10-24 scheme and the 1.0.<commit_count> scheme of 2026-10-18):
#   ONE NUMBER, and it is a version string:
#       MARKETING_VERSION (CFBundleShortVersionString)
#         = CURRENT_PROJECT_VERSION (CFBundleVersion)
#         = <train>.<N>
#   The two fields carry the SAME string, so App Store Connect shows
#   "0.1.1 (0.1.1)" and the pair describes one number.  There is no second
#   number anywhere:  not the repository commit count (retired), not a
#   timestamp (retired), not a bare integer beside the version.
#   <train> is the major.minor the app's numbers live on:  "0.1" for Hog
#   Hunter and the other apps that are not on the App Store, "1.1" for
#   Congress.Trade, whose past numbers already used the 1.0 train.
#   N is one past what the train already holds, so a number is never reused.
#   The train holds:
#       - the committed record (project.yml MARKETING_VERSION):  the version
#         the last update shipped.  Both ship paths read it, so the Mac app
#         and the iPhone app of one update carry the same number.
#       - the App Store Connect state (this path only):  the highest patch
#         already used on that train, counting BOTH the App Store versions
#         (appStoreVersions.versionString) AND the TestFlight trains
#         (preReleaseVersions.version) for the app's platform.  A TestFlight
#         train that holds a build named after its own patch (the retired
#         "1.0.2358 (2358)" drift trains) is IGNORED, so those uploads do not
#         push the version forward.  App Store versions are never ignored.
#   The Mac path (scripts/install.sh) has no App Store Connect access and
#   sees only the committed record, so the two paths agree whenever the
#   record is current.  When App Store Connect already holds the next patch,
#   this path takes the higher number and the Mac path is one behind until
#   the record catches up.
#   --version X.Y.Z is an exact marketing override and --build N an exact
#   build override.  Without an override the build number IS the version.
#   The ship gate still runs BEFORE any version is resolved, and a checkout
#   with no readable git history fails loudly:  there is no timestamp
#   fallback and no guess.
#
#   See docs/rollouts/2026-10-26-version-scheme-one-number.md.
#
# ---------------------------------------------------------------------------
# WHAT IS HOLDING BACK AUTOMATIC SHIPPING: THE MIN-INTERVAL RATE LIMIT
# ---------------------------------------------------------------------------
# Applies to uploads only (--export-only and --dry-run are free):
#   DEFAULT MINIMUM INTERVAL BETWEEN SUCCESSFUL TESTFLIGHT SHIPS, PER APP:
#       DEFAULT_MIN_INTERVAL_SEC=3600  (3600 seconds = 1 hour)
#   That constant is defined a few dozen lines below and is the main reason a
#   merge to main does not become a TestFlight build. .github/workflows/
#   ios-ship.yml fires on every push to main touching clients/ios/**, and this
#   gate turns most of those runs into a no-op skip (exit 0).
#   Override for one run:  IOS_TF_MIN_INTERVAL_SEC=7200 (2h)  or  --force-ship
#   Change the default:    edit DEFAULT_MIN_INTERVAL_SEC below (owner's call).
#
#   Also skips when git HEAD matches the last successful ship (no new commits).
#   Skip exits 0 ("nothing to do") so agent loops stay quiet, and a skipped run
#   does NOT resolve or consume a version (see the ship-gate ordering note
#   at the call site).
#   State: ~/.cache/ios-fleet/last-ship-<app>.txt  (unix_ts + space + git_sha)
#
# ---------------------------------------------------------------------------
# POST-UPLOAD: ensure-tf-ready AND TESTFLIGHT RELEASE NOTES (2026-08-13)
# ---------------------------------------------------------------------------
# ensure_tf_ready now passes BUILD_NUM (CFBundleVersion) to asc-api.mjs, which
# polls App Store Connect until THAT EXACT BUILD appears and only then declares
# export compliance on it. Before this it took "the newest build", which for the
# first minutes after an upload is the PREVIOUS ship -- so compliance was
# declared on the wrong build and the "testers can install this" line described
# a build it had never looked at.
#   IOS_TF_READY_TIMEOUT_SEC   discovery + readiness budget (default 900s)
#   exit 4 from asc-api.mjs    uploaded build never surfaced; warn, do NOT fail
#                              (record_successful_ship must still run or the rate
#                              gate never advances)
#
# It also renders the mandatory AGENT-SYNC "What to Test" release note from the
# commit range since the last successful ship. THIS IS OPT-IN, because it writes
# copy every TestFlight tester reads:
#   IOS_TF_RELEASE_NOTES=1     publish to App Store Connect
#   IOS_TF_RELEASE_NOTES=0     off entirely
#   unset (DEFAULT)            dry render into the ship log; nothing is written
# Owner binding 2026-09-08 (Jay): production ships MUST publish What to Test
# (IOS_TF_RELEASE_NOTES=1). Body = 1-2 change/fix/upgrade types, or the other
# reason for the build if not a product change. Empty/placeholder/agent names ban.
# No --force-ship.
#   IOS_TF_RELEASE_TITLE=...   override the "<App> Update" title
# CI needs `fetch-depth: 0` on actions/checkout or the runner workspace holds a
# single commit and the range is uncomputable (verified 2026-08-13 on all three
# fleet runners).
#
# Secrets (never printed):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8  (env first, e.g. CI; else Infisical via
#   `fleet-secrets get` from Fleet-OPS /asc: ASC_KEY_ID, ASC_ISSUER_ID and the .p8 in ASC_KEY_P8,
#   written to a 0600 temp file and deleted on exit)
#   ASC_KEY_PATH is NOT a credential source (AFC-459):  the only file is a short-lived
#   owner-only materialization for altool and xcodebuild, written from the resolved
#   credential and never read back as one.
#   or Xcode-signed-in session for destination=upload export
#   SENTRY_AUTH_TOKEN  (dSYM + Size Analysis upload; env or Infisical via fleet-secrets)
#   SENTRY_DSN         (injected into xcodebuild so Cocoa plist $(SENTRY_DSN) is set)
#
# Sentry after a successful archive (2026-09-01):
#   debug-files upload of the xcarchive dSYMs, then `sentry-cli build upload`
#   for Size Analysis.  Failures WARN and do not fail the TestFlight ship.
#   Quota: 100 size-analysis builds/month on the sponsored plan.  No LaunchAgent.
#
# ASCII-only (Apple bash 3.2 safe). Team: CC8UTF7ATG.

set -euo pipefail

# LaunchAgents inherit a tiny PATH (no Homebrew). Node is required for
# ensure-tf-ready and for the App Store Connect queries. Prioritize /usr/bin and /bin so Apple distribution tools (rsync -E) use native macOS binaries.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
# The node that runs asc-api.mjs.  IOS_FLEET_NODE lets an offline test answer
# App Store Connect from a stub;  a real ship leaves it unset and uses node
# from PATH.
ASC_NODE="${IOS_FLEET_NODE:-node}"

FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
APPS_JSON="${FLEET_DIR}/apps.json"
TEAM_ID="CC8UTF7ATG"
# AFC-359: App Store Connect credentials come from the environment (CI sets them) or
# Infisical Fleet-OPS via fleet-secrets.  Nothing is read from the old secrets folder.
FLEET_SECRETS_BIN="${FLEET_SECRETS:-${HOME}/.local/bin/fleet-secrets}"
ASC_TMP_DIR=""
cleanup_asc_tmp() {
  if [[ -n "${ASC_TMP_DIR:-}" ]]; then
    rm -rf "$ASC_TMP_DIR" 2>/dev/null || true
  fi
  ASC_TMP_DIR=""
}
# Expand only a leading "~/" (not "~user/") so a typo is never merged with $HOME.
expand_tilde() {
  case "$1" in
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
trap cleanup_asc_tmp EXIT
# 1 hour — owner 2026-08-14: ship unbuilt iOS updates as often as once per hour.
# Not Apple compute; local/process hygiene. Cron ticks twice an hour so a
# trailing merge inside the window is picked up on the next eligible tick.
DEFAULT_MIN_INTERVAL_SEC=3600
# Overridable so the ship-gate state can be pointed at a scratch dir
# for testing without touching real ship history.
STATE_DIR="${IOS_FLEET_STATE_DIR:-${HOME}/.cache/ios-fleet}"

APP_KEY=""
REPO_ROOT=""
FORCE_BUILD=""
FORCE_VERSION=""
EXPORT_ONLY=0
UPLOAD_ONLY_IPA=""
DRY_RUN=0
SKIP_XCODEGEN=0
ALLOW_DIRTY=0
FORCE_SHIP=0
ALLOW_UNVERIFIED_SEQ=0
SYNC_PROJECT_VERSION=0

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[ios-ship] $*"; }
# Same prefix, but on stderr — for use inside $(...) helpers whose stdout is
# the return value and must stay clean.
logerr() { echo "[ios-ship] $*" >&2; }

usage() {
  # Print the header comment block: everything before the first non-comment line.
  sed -n '2,${/^[^#]/q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

json_get() {
  # json_get <app_key> <field>
  /usr/bin/python3 - "$APPS_JSON" "$1" "$2" <<'PY'
import json, sys
path, app, field = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
apps = data["apps"]
if app not in apps:
    print("", end="")
    sys.exit(0)
val = apps[app].get(field)
if val is None:
    print("", end="")
elif isinstance(val, list):
    print(",".join(val), end="")
else:
    print(val, end="")
PY
}

resolve_project() {
  local root="$1" rel="$2" alt="$3"
  if [[ -n "$rel" && -e "${root}/${rel}" ]]; then
    echo "${root}/${rel}"
    return 0
  fi
  if [[ -n "$alt" && -e "${root}/${alt}" ]]; then
    echo "${root}/${alt}"
    return 0
  fi
  return 1
}

# fs_get NAME FOLDER -> value on stdout (never logged); non-zero when absent.
fs_get() {
  local v bin="$FLEET_SECRETS_BIN"
  [[ -x "$bin" ]] || bin="$(command -v fleet-secrets 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  v="$("$bin" get "$1" --path "$2" 2>/dev/null </dev/null)" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# The App Store Connect client.  ASC_NODE is the node that runs it:  a real
# ship uses node from PATH, and an offline test can point it at a stub that
# answers the version queries without a network.
asc_client() {
  "$ASC_NODE" "${FLEET_DIR}/asc-api.mjs" "$@"
}

# True when the App Store Connect client can find a credential at all:  either
# the environment carries one (either spelling), or the Infisical helper the
# client reads directly is reachable.
#
# The client resolves the credential itself and never reads a key FILE (AFC-459),
# so a read-only query does not need the shell layer to stage one.  The shell
# stages a key only for the Apple tools that cannot read one from the
# environment (altool, xcodebuild -authenticationKeyPath), and a key left on
# disk by a query would outlive the run.
asc_credential_source_present() {
  if [[ -n "${ASC_KEY_ID:-}" || -n "${APPLE_API_KEY_ID:-}" ]]; then
    return 0
  fi
  local bin
  for bin in "${FLEET_SECRETS_BIN:-}" "${FLEET_SECRETS:-}" "${HOME}/.local/bin/fleet-secrets"; do
    if [[ -n "$bin" && -x "$bin" ]]; then
      return 0
    fi
  done
  if command -v fleet-secrets >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Load ASC credentials into the CURRENT shell (must not run inside $(...) or the
# exported ASC_* vars are discarded with the subshell). Sets AUTH_MODE to
# "api_key" or "none". Never prints secret values.  Order: an ambient
# ASC_KEY_P8 (with its key id and issuer), else Infisical.
#
# A named ASC_KEY_PATH is NOT a credential source (AFC-459):  a path on disk
# is not an approved secret source, so a named path is ignored wherever it
# appears.  The only file this function writes is a short-lived, owner-only
# materialization for the Apple tools that can only read a key from disk
# (altool, xcodebuild -authenticationKeyPath);  it is written FROM the
# resolved credential and is never read back as one.
#  A rejected key is reported with a MASKED PREVIEW, never with the key
#  itself:  the first eight and the last four characters, nothing else
#  (Kody rule 28).  A value too short to mask safely is withheld whole, so
#  the preview can never become the secret.
key_preview() {
  local v="${1:-}" n
  n=${#v}
  if [[ "$n" -eq 0 ]]; then
    printf '%s' "(empty)"
    return 0
  fi
  if [[ "$n" -le 24 ]]; then
    #  Withheld unless the value is comfortably longer than the twelve
    #  characters a preview discloses:  a 13-character rejected credential
    #  would otherwise be logged as 12 of its 13 characters, which is the
    #  mask becoming the secret.
    printf '[%d chars, withheld]' "$n"
    return 0
  fi
  #  The offset is computed arithmetically:  ${v: -4} needs bash 4.2 and this
  #  script targets Apple bash 3.2, where it is a bad substitution.
  printf '%s...%s' "${v:0:8}" "${v:$((${#v}-4))}"
}

load_secrets() {
  AUTH_MODE="none"
  local kid="${ASC_KEY_ID:-}" iss="${ASC_ISSUER_ID:-}" p8="" fkid="" lower
  local key_pem="" key_path="" rc=0
  #  A named ASC_KEY_PATH is not a credential source.  It is remembered only
  #  so the run can say that it ignored it.
  local named_path="${ASC_KEY_PATH:-}"

  # 1. The hosted APPLE_API_* trio:  the key id, the issuer and the key belong
  #    together, so all three names have to be there.  The p8 body is base64.
  if [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" && -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
    case "$APPLE_API_KEY_P8_BASE64" in
      *BEGIN*) p8="$APPLE_API_KEY_P8_BASE64" ;;
      #  The encoded value reaches the decoder through a here-string, so the
      #  shell never prints it:  a credential belongs in no output stream.
      *) p8="$(base64 --decode <<<"$APPLE_API_KEY_P8_BASE64" 2>/dev/null)" || p8="" ;;
    esac
    if [[ -n "$p8" ]]; then
      key_pem="$p8"
      kid="${APPLE_API_KEY_ID}"
      iss="${APPLE_API_ISSUER_ID}"
    fi
    p8=""
  fi

  # 2. An ambient ASC_KEY_P8.  It is only usable when it really is a PEM
  #    private key and comes with the key id and issuer it belongs to.  It is
  #    resolved before the vault, so nothing can override it.
  if [[ -z "$key_pem" && -n "${ASC_KEY_P8:-}" ]]; then
    if [[ -z "$kid" || -z "$iss" ]]; then
      log "ASC_KEY_P8 is set without ASC_KEY_ID and ASC_ISSUER_ID; ignoring it; preview: $(key_preview "$ASC_KEY_P8")"
      unset ASC_KEY_P8
    else
      rc=0
      node "${FLEET_DIR}/asc-key.mjs" validate >/dev/null 2>&1 <<< "$ASC_KEY_P8" || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        log "ASC_KEY_P8 is set but does not hold a PEM private key; ignoring it; preview: $(key_preview "$ASC_KEY_P8")"
        unset ASC_KEY_P8
      else
        key_pem="$ASC_KEY_P8"
      fi
    fi
  fi

  # 3. The key id, issuer and private key must belong together:  with nothing named in the
  # environment all three come from /asc;  an env key id that is not the /asc one gets its
  # own .p8 from /authkey-<id>-p8, never the /asc key.
  if [[ -z "$key_pem" ]]; then
    [[ -n "$kid" ]] || kid="${APPLE_API_KEY_ID:-}"
    [[ -n "$iss" ]] || iss="${APPLE_API_ISSUER_ID:-}"
    fkid="$(fs_get ASC_KEY_ID /asc)" || fkid=""
    if [[ -z "$kid" ]]; then
      kid="$fkid"
      iss="$(fs_get ASC_ISSUER_ID /asc)" || iss=""
    elif [[ -z "$iss" && "$kid" == "$fkid" ]]; then
      # env named the /asc key itself:  its issuer is the /asc one
      iss="$(fs_get ASC_ISSUER_ID /asc)" || iss=""
    fi
    if [[ -z "$kid" || -z "$iss" ]]; then
      log "ASC credentials missing: set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (or APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and APPLE_API_KEY_P8_BASE64) in the environment, or add ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 to Infisical /asc"
      return 0
    fi
    if [[ "$kid" == "$fkid" ]]; then
      p8="$(fs_get ASC_KEY_P8 /asc)" || p8=""
    else
      lower="$(printf '%s' "$kid" | tr 'A-Z' 'a-z')"
      p8="$(fs_get "AUTHKEY_${kid}" "/authkey-${lower}-p8")" || p8=""
    fi
    if [[ -z "$p8" ]]; then
      log "missing the .p8 for key ${kid}: Infisical /asc ASC_KEY_P8 (the /asc key) or /authkey-<id>-p8 AUTHKEY_<id>"
      return 0
    fi
    key_pem="$p8"
    p8=""
  fi

  # The key has to be in a mode-600 file for altool and Xcode, and in the
  # environment for the node client, which never reads a file.  The file is
  # written from the credential that was just resolved, so it is never read
  # back as a credential.
  #  The key id names a file below, so it may not carry a path.  The guard
  #  stands after every source - the hosted trio, the environment and the
  #  vault - because an id from any of them reaches the same file name.
  if [[ ! "$kid" =~ ^[A-Za-z0-9]+$ ]]; then
    log "ASC_KEY_ID has an unexpected shape; not staging the key"
    return 0
  fi
  if [[ -z "$ASC_TMP_DIR" ]]; then
    ASC_TMP_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/asc-key.XXXXXX")"
  fi
  key_path="${ASC_TMP_DIR}/AuthKey_${kid}.p8"
  if ! node "${FLEET_DIR}/asc-key.mjs" write "$key_path" <<< "$key_pem"; then
    log "could not write the ASC key file; the credential is not usable"
    return 0
  fi
  # altool searches API_PRIVATE_KEYS_DIR first, so no symlink into ~/.appstoreconnect is needed.
  export API_PRIVATE_KEYS_DIR="$ASC_TMP_DIR"
  export ASC_KEY_ID="$kid" ASC_ISSUER_ID="$iss" ASC_KEY_PATH="$key_path"
  # The client takes the key from the environment:  a path is not an approved
  # secret source, so it never reads one.
  export ASC_KEY_P8="$key_pem"
  key_pem=""
  if [[ -n "$named_path" && "$named_path" != "$key_path" ]]; then
    log "ASC_KEY_PATH is not a credential source; the credential came from the environment or from Infisical"
  fi
  AUTH_MODE="api_key"
  return 0
}

# Map ship APP_KEY to Sentry project slug in org simple-with-us.
sentry_project_for_app() {
  case "${APP_KEY}" in
    socratic) echo "socratic-trade" ;;
    congress) echo "congress-trade" ;;
    usage|usage-local) echo "usage-monitor" ;;
    dealdex) echo "dealdex" ;;
    autorotate|autorotate-mac) echo "autorotate" ;;
    contactlogo|contactlogo-mac) echo "contactlogo" ;;
    botfleet|botfleet-mac) echo "botfleet" ;;
    fleetlink) echo "fleetlink" ;;
    codecaps|codecaps-mac) echo "codecaps" ;;
    hoghunter) echo "hoghunter" ;;
    *) echo "" ;;
  esac
}

# Pull SENTRY_AUTH_TOKEN from the environment, else from `fleet-secrets get`
# when that helper is installed.  Extract into a var, never echo.
load_sentry_auth() {
  if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
    return 0
  fi
  # OPS-818: read from Infisical Fleet-OPS via fleet-secrets, not the retired
  # flat file.  Resolve through PATH: a hardcoded /Users/jay path silently
  # leaves the token unset on every other machine and on CI, which is exactly
  # where a dSYM upload would then fail quietly.
  if command -v fleet-secrets &>/dev/null; then
    local token
    token="$(fleet-secrets get SENTRY_AUTH_TOKEN 2>/dev/null | tr -d '\r')" || token=""
    if [[ -n "$token" ]]; then
      SENTRY_AUTH_TOKEN="$token"
      export SENTRY_AUTH_TOKEN
    fi
  fi
}

# After a successful archive: upload dSYMs and Size Analysis.  Never fail the
# TestFlight ship if Sentry is missing or the upload errors.
upload_sentry_artifacts() {
  local project archive
  project="$(sentry_project_for_app)"
  archive="${ARCHIVE_PATH:-}"
  if [[ -z "$project" ]]; then
    log "sentry: no project mapping for app=${APP_KEY}; skipping artifact upload"
    return 0
  fi
  if [[ -z "$archive" || ! -d "$archive" ]]; then
    log "sentry: archive missing; skipping artifact upload"
    return 0
  fi
  load_sentry_auth
  if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    log "sentry: SENTRY_AUTH_TOKEN unset; skipping dSYM / Size Analysis upload"
    return 0
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    log "sentry: sentry-cli not on PATH; trying official installer"
    if ! curl -sL https://sentry.io/get-cli/ | SENTRY_CLI_VERSION="" bash >/dev/null 2>&1; then
      log "warning: sentry-cli install failed; TestFlight ship continues"
      return 0
    fi
    export PATH="${HOME}/.sentry-cli:${PATH}:/opt/homebrew/bin"
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    log "warning: sentry-cli still missing; skipping artifact upload"
    return 0
  fi
  log "sentry: uploading debug files for project=${project} (token length ${#SENTRY_AUTH_TOKEN})"
  set +e
  SENTRY_ORG=simple-with-us SENTRY_PROJECT="$project" \
    sentry-cli debug-files upload --include-sources "$archive" \
    >"${LOG_DIR}/sentry-debug-files.log" 2>&1
  local dif_rc=$?
  set -e
  if [[ $dif_rc -eq 0 ]]; then
    log "sentry: debug-files upload ok"
  else
    log "warning: sentry debug-files upload rc=${dif_rc}; see ${LOG_DIR}/sentry-debug-files.log"
  fi
  log "sentry: Size Analysis build upload for project=${project}"
  set +e
  SENTRY_ORG=simple-with-us SENTRY_PROJECT="$project" \
    sentry-cli build upload "$archive" \
    >"${LOG_DIR}/sentry-build-upload.log" 2>&1
  local build_rc=$?
  set -e
  if [[ $build_rc -eq 0 ]]; then
    log "sentry: build upload ok"
  else
    log "warning: sentry build upload rc=${build_rc}; see ${LOG_DIR}/sentry-build-upload.log"
  fi
  return 0
}

link_private_key() {
  # altool / iTMSTransporter look for AuthKey_<id>.p8 in standard dirs.  When
  # load_secrets wrote a temp key it also set API_PRIVATE_KEYS_DIR, so there is
  # nothing to link (and a symlink to a deleted temp file would dangle).
  local key_path="$1" key_id="$2"
  if [[ -n "${ASC_TMP_DIR:-}" && "$key_path" == "${ASC_TMP_DIR}/"* ]]; then
    return 0
  fi
  local dest_dir="${HOME}/.appstoreconnect/private_keys"
  mkdir -p "$dest_dir"
  chmod 700 "$dest_dir"
  local dest="${dest_dir}/AuthKey_${key_id}.p8"
  if [[ -L "$dest" && ! -e "$dest" ]]; then
    rm -f "$dest"
  fi
  if [[ ! -e "$dest" ]]; then
    ln -sf "$key_path" "$dest"
  fi
  chmod 600 "$key_path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# THE VERSION NUMBERS (owner directive 2026-10-26, HH-191)
# ---------------------------------------------------------------------------
# The rule itself is in the header comment above; this is where it is applied.
# The readable, unit-tested copy of it is scripts/ios-fleet/version-plan.mjs
# (pure), and the I/O around it -- reading and writing the committed record in
# project.yml -- is scripts/ios-fleet/version-number.mjs behind the thin
# scripts/ios-fleet/version-number.sh entry point.
#
# ONE NUMBER, a version string:
#   MARKETING_VERSION (CFBundleShortVersionString)
#     = CURRENT_PROJECT_VERSION (CFBundleVersion)
#     = <train>.<N>
#
# <train> is the major.minor the app's numbers live on.  It comes from the
# committed record (project.yml), which is the version the last update
# shipped.  The Mac path reads the same record, which is how one update
# carries one number on both platforms.
#
# N is one past what the train already holds:
#   - the committed record (the patch of MARKETING_VERSION), and
#   - what App Store Connect already holds on that train (this path only):
#     the App Store versions AND the TestFlight trains, drift trains ignored.
# The number is never the repository commit count and never a timestamp.
#
# The build number IS the version string, so the pair describes one number:
# "0.1.1 (0.1.1)".  The only way to get two numbers again is an explicit
# --build, and that is logged loudly.
#
# App Store Connect is the only record that shipping advances on Apple's
# side, so it is the only record that can answer "which patches does this
# train hold?".  The local build-seq counter
# (~.cache/ios-fleet/build-seq-<app>.txt) is NOT a source:  the counter is
# never written.  project.pbxproj is the generated copy of project.yml, so
# the committed record is what both ship paths read.

# The highest patch already used on the <prefix> train in App Store Connect
# (App Store versions AND TestFlight trains, drift trains ignored).
# Prints the integer on stdout.  Returns 1 (and prints nothing) when ASC
# cannot be consulted -- the caller must distinguish "no patch yet" (0) from
# "unknown" (failure).
asc_latest_marketing_patch() {
  local prefix="$1" plat="${2:-}" out rc
  if ! command -v "$ASC_NODE" >/dev/null 2>&1; then
    logerr "asc-patch: node not on PATH; cannot verify against App Store Connect"
    return 1
  fi
  if ! asc_credential_source_present; then
    logerr "asc-patch: no ASC_* in env and no fleet-secrets; cannot verify against App Store Connect"
    return 1
  fi
  set +e
  out=$(asc_client latest-marketing-patch "$BUNDLE_ID" "$prefix" "$plat" 2>/dev/null)
  rc=$?
  if [[ $rc -eq 4 ]]; then
    set -e
    logerr "asc-patch: App Store Connect rejected the credential (HTTP 401/403)"
    return 4
  fi
  set -e
  if [[ $rc -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
    logerr "asc-patch: query failed (rc=${rc}); cannot verify against App Store Connect"
    return 1
  fi
  printf '%s' "$out"
}

# The build floor for one marketing train:  every build already in that train
# (Apple requires build numbers to grow inside one train, so the retired UTC
# stamps still hold the floor up) plus the app's plain-integer builds below
# 1000000000 (EVERY build on macOS, where build numbers grow across trains).
#
# Prints "<floor> <train> <app> <train_builds>" on stdout -- the numbers the
# version plan log line names, plus how many builds the target train holds.
# The count is what the in-train guard uses:  the build number IS the version,
# so the target train has to be empty for the build to be the highest one in
# it.  Returns 1 (and prints nothing) when ASC cannot be consulted.
asc_build_floor() {
  local version="$1" plat="${2:-}" out rc err train app builds errfile
  if ! command -v "$ASC_NODE" >/dev/null 2>&1; then
    logerr "asc-floor: node not on PATH; cannot verify against App Store Connect"
    return 1
  fi
  if ! asc_credential_source_present; then
    logerr "asc-floor: no ASC_* in env and no fleet-secrets; cannot verify against App Store Connect"
    return 1
  fi
  errfile="$(mktemp "${TMPDIR:-/tmp}/ios-fleet-floor.XXXXXX" 2>/dev/null || printf '')"
  if [[ -z "$errfile" ]]; then
    # mktemp failed:  /dev/null keeps the redirect valid, and the floor
    # simply falls back to the combined number.
    errfile="/dev/null"
  fi
  set +e
  out=$(asc_client build-floor "$BUNDLE_ID" "$version" "$plat" 2>"$errfile")
  rc=$?
  # Keep the client's build-floor lines:  they carry Apple's HTTP status,
  # which the fatal message below tells the operator to look for.
  if [[ -s "$errfile" ]]; then
    while IFS= read -r _fl; do
      case "$_fl" in build-floor:*|latest-build-seq:*) logerr "asc-floor: ${_fl}" ;; esac
    done <"$errfile"
  fi
  if [[ $rc -eq 4 ]]; then
    set -e
    logerr "asc-floor: App Store Connect rejected the credential (HTTP 401/403)"
    rm -f "$errfile" >/dev/null 2>&1 || true
    return 4
  fi
  set -e
  err="$(cat "$errfile" 2>/dev/null || true)"
  if [[ "$errfile" != "/dev/null" ]]; then
    rm -f "$errfile" 2>/dev/null || true
  fi
  if [[ $rc -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
    logerr "asc-floor: query failed (rc=${rc}); cannot verify against App Store Connect"
    return 1
  fi
  # The client prints the two parts of the floor on stderr, so the log line
  # can name them; fall back to the combined floor when they are missing.
  train="$(printf '%s' "$err" | sed -n 's/.*[^a-z]train=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  app="$(printf '%s' "$err" | sed -n 's/.*[^a-z]app=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  builds="$(printf '%s' "$err" | sed -n 's/.*[^a-z]train_builds=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  printf '%s %s %s %s' "$out" "${train:-$out}" "${app:-$out}" "${builds:-0}"
}

# THE ONE NUMBER (owner directive 2026-10-26, HH-191).
#
# The committed version record in project.yml is the single source of truth
# both ship paths read:  scripts/install.sh (the Mac path) and this script
# (the iOS path) both go through it, so one update carries one number on both
# platforms.  The rules that pick the number are pure and live in
# version-plan.mjs; version-number.mjs reads and writes the record.
#
#   version_number record        -> "<version> <build>"
#   version_number next [--known N] [--write]
#                                -> "<version> <build>"
#   version_number write <version>
#                                -> "<version> <build>"
version_number() {
  bash "${FLEET_DIR}/version-number.sh" --root "$REPO_ROOT" "$@"
}

# The major.minor train a marketing version belongs to: "2.0.123" -> "2.0",
# "3" -> "3.0".  The floor is per-train, so the train has to come from the
# version actually being shipped rather than always from the default.
version_prefix() {
  printf '%s' "${1:-1.0}" | awk -F. '{ if (NF >= 2) print $1"."$2; else print $1".0" }'
}

marketing_prefix() {
  # "1.0" from marketingVersionDefault (1.0 or 1.0.x both yield 1.0).
  version_prefix "${DEFAULT_MARKETING:-1.0}"
}

ship_state_path() {
  echo "${STATE_DIR}/last-ship-${APP_KEY}.txt"
}

repo_head_sha() {
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Decide whether this run may upload: rate limit + "no new commits since the
# last successful ship". Does not apply to --export-only (local IPA only) or
# --force-ship.
#
# This function DECIDES and LOGS; it does not exit. That separation is the fix
# for the ordering bug observed live on 2026-08-12: the gate used to be
# evaluated after the build counter had already committed floor+1 to it, so a
# rate-limited attempt still burned a build number. The sequence advanced
# 5 -> 6 while the run skipped, leaving 1.0.6 existing nowhere and the local
# counter drifting further from App Store Connect. The caller now evaluates the
# gate BEFORE any version is resolved, so a skipped run consumes nothing.
#
# Sets SHIP_GATE_DECISION to "proceed" or "skip".
SHIP_GATE_DECISION="proceed"
evaluate_ship_gate() {
  SHIP_GATE_DECISION="proceed"
  if [[ "$FORCE_SHIP" -eq 1 ]]; then
    log "force-ship: bypassing min-interval / same-HEAD gate"
    return 0
  fi
  if [[ "$EXPORT_ONLY" -eq 1 ]]; then
    return 0
  fi

  local min_sec min_src path last_ts last_sha now elapsed head_sha
  # Report which source the number came from, so the log answers "why did this
  # not ship" without anyone reading the script. Non-numeric / empty -> default,
  # and say so rather than crediting the env var for a value it did not supply.
  if [[ -n "${IOS_TF_MIN_INTERVAL_SEC:-}" && "${IOS_TF_MIN_INTERVAL_SEC}" =~ ^[0-9]+$ ]]; then
    min_sec="$IOS_TF_MIN_INTERVAL_SEC"
    min_src="IOS_TF_MIN_INTERVAL_SEC"
  else
    min_sec="$DEFAULT_MIN_INTERVAL_SEC"
    min_src="DEFAULT_MIN_INTERVAL_SEC in $(basename "$0")"
    if [[ -n "${IOS_TF_MIN_INTERVAL_SEC:-}" ]]; then
      log "ship-gate: IOS_TF_MIN_INTERVAL_SEC is not a number; using the default"
    fi
  fi
  path="$(ship_state_path)"
  head_sha="$(repo_head_sha)"
  now="$(date +%s)"

  if [[ ! -f "$path" ]]; then
    log "ship-gate: no prior ship for ${APP_KEY}; proceeding"
    return 0
  fi

  # Format: "<unix_ts> <git_sha>"
  read -r last_ts last_sha <"$path" || true
  if ! [[ "${last_ts:-}" =~ ^[0-9]+$ ]]; then
    log "ship-gate: bad state file; proceeding"
    return 0
  fi

  if [[ -n "${last_sha:-}" && "$last_sha" != "unknown" && "$head_sha" == "$last_sha" ]]; then
    log "ship-gate: skip — HEAD ${head_sha:0:10} already shipped for ${APP_KEY} (no new commits)"
    log "ship-gate: use --force-ship to upload the same HEAD again"
    SHIP_GATE_DECISION="skip"
    return 0
  fi

  elapsed=$((now - last_ts))
  if [[ "$elapsed" -lt "$min_sec" ]]; then
    local remain=$((min_sec - elapsed))
    local remain_m=$(( (remain + 59) / 60 ))
    local min_m=$(( min_sec / 60 ))
    log "ship-gate: skip — last ${APP_KEY} ship ${elapsed}s ago; min interval ${min_sec}s (~${remain_m}m left)"
    log "ship-gate: that ${min_sec}s (${min_m}m) limit comes from ${min_src}."
    log "ship-gate: it is THE throttle on automatic shipping — .github/workflows/ios-ship.yml"
    log "ship-gate: runs on every push to main touching clients/ios/**, and most runs skip here."
    log "ship-gate: override this run with IOS_TF_MIN_INTERVAL_SEC=<seconds> or --force-ship;"
    log "ship-gate: change the standing limit by editing DEFAULT_MIN_INTERVAL_SEC (owner's call)."
    SHIP_GATE_DECISION="skip"
    return 0
  fi

  log "ship-gate: ok — ${elapsed}s since last ship (min ${min_sec}s from ${min_src}); HEAD ${head_sha:0:10}"
}

record_successful_ship() {
  local path head_sha now
  path="$(ship_state_path)"
  head_sha="$(repo_head_sha)"
  now="$(date +%s)"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  printf '%s %s\n' "$now" "$head_sha" >"$path"
  chmod 600 "$path" 2>/dev/null || true
  log "ship-gate: recorded success ts=${now} sha=${head_sha:0:10} -> ${path}"
  # Public version manifest for the in-app update prompt.  Best-effort —
  # a publish miss must never fail a ship that already uploaded.
  if [[ -n "${BUNDLE_ID:-}" && -n "${MARKETING:-}" ]]; then
    local apple_id display
    local -a pub_args
    apple_id="$(json_get "$APP_KEY" appleId || true)"
    display="$(json_get "$APP_KEY" displayName || true)"
    pub_args=(--bundle-id "$BUNDLE_ID" --version "$MARKETING")
    [[ -n "${BUILD_NUM:-}" ]] && pub_args+=(--build "$BUILD_NUM")
    [[ -n "${apple_id:-}" ]] && pub_args+=(--apple-id "$apple_id")
    [[ -n "${display:-}" ]] && pub_args+=(--display-name "$display")
    if bash "${FLEET_DIR}/publish-ios-versions.sh" "${pub_args[@]}" >/dev/null 2>&1; then
      log "version-manifest: published ${BUNDLE_ID} ${MARKETING}"
    else
      log "warning: version-manifest publish failed (non-fatal)"
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --build) FORCE_BUILD="$2"; shift 2 ;;
    --version) FORCE_VERSION="$2"; shift 2 ;;
    --export-only) EXPORT_ONLY=1; shift ;;
    --upload-only) UPLOAD_ONLY_IPA="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-xcodegen) SKIP_XCODEGEN=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --force-ship) FORCE_SHIP=1; shift ;;
    --allow-unverified-seq) ALLOW_UNVERIFIED_SEQ=1; shift ;;
    --sync-project-version) SYNC_PROJECT_VERSION=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$APP_KEY" ]]; then
        APP_KEY="$1"; shift
      else
        die "unexpected arg: $1"
      fi
      ;;
  esac
done

[[ -n "$APP_KEY" ]] || die "app key required (e.g. socratic, congress, usage, usage-local, dealdex, autorotate, autorotate-mac, contactlogo, contactlogo-mac, botfleet, botfleet-mac, clutch)"
[[ -f "$APPS_JSON" ]] || die "missing apps registry: $APPS_JSON"

# Validate APP_KEY against apps.json before requiring Xcode tools so --help-adjacent
# and CI unit tests can reject unknown keys on Linux runners without xcodebuild.
_EARLY_BUNDLE="$(json_get "$APP_KEY" bundleId)"
_EARLY_SCHEME="$(json_get "$APP_KEY" scheme)"
_EARLY_PROJECT="$(json_get "$APP_KEY" projectRel)"
[[ -n "$_EARLY_BUNDLE" && -n "$_EARLY_SCHEME" && -n "$_EARLY_PROJECT" ]] || die "unknown app key or incomplete registry: $APP_KEY"

# Prefer stable Xcode.app over Xcode-beta for TestFlight / ASC compatibility.
# Beta toolchains + beta macOS stamp BuildMachineOSBuild that App Store review
# rejects as INVALID_BINARY even when TestFlight accepts the same IPA.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    echo "[ios-ship] warning: only Xcode-beta present; ASC Invalid Binary risk" >&2
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  fi
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "[ios-ship] DEVELOPER_DIR=${DEVELOPER_DIR}"
fi

need_cmd xcodebuild
need_cmd /usr/bin/python3

# Owner 2026-08-11: always use stable Xcode.app for archive/export/upload.
# Xcode-beta breaks TestFlight / App Store Connect tooling compatibility.
# Override only if DEVELOPER_DIR is already set to a non-beta path.
if [[ -z "${DEVELOPER_DIR:-}" || "$DEVELOPER_DIR" == *Xcode-beta* ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  log "using DEVELOPER_DIR=${DEVELOPER_DIR}"
  xcodebuild -version || die "xcodebuild broken under DEVELOPER_DIR=${DEVELOPER_DIR}"
fi


if [[ -z "$REPO_ROOT" ]]; then
  hint="$(json_get "$APP_KEY" worktreeHint || true)"
  hint="${hint/#\~/$HOME}"
  if [[ -n "$hint" && -d "$hint" ]]; then
    REPO_ROOT="$hint"
  else
    REPO_ROOT="$(pwd)"
  fi
fi
if [[ ! -d "$REPO_ROOT" ]]; then
  die "repo root does not exist: $REPO_ROOT"
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

DISPLAY_NAME="$(json_get "$APP_KEY" displayName)"
BUNDLE_ID="$(json_get "$APP_KEY" bundleId)"
PLATFORM="$(json_get "$APP_KEY" platform)"
SCHEME="$(json_get "$APP_KEY" scheme)"
PROJECT_REL="$(json_get "$APP_KEY" projectRel)"
PROJECT_REL_ALT="$(json_get "$APP_KEY" projectRelAlt)"
XCODEGEN_DIR="$(json_get "$APP_KEY" xcodegenDir)"
DEFAULT_MARKETING="$(json_get "$APP_KEY" marketingVersionDefault)"

if [[ -z "$PLATFORM" ]]; then
  if [[ "$APP_KEY" == *-mac || "$SCHEME" == *[Mm]ac* ]]; then
    PLATFORM="macOS"
  else
    PLATFORM="iOS"
  fi
fi

[[ -n "$BUNDLE_ID" && -n "$SCHEME" && -n "$PROJECT_REL" ]] || die "unknown app key or incomplete registry: $APP_KEY"
if [[ "$BUNDLE_ID" == "me.grok.dealdex" ]]; then
  die "refusing to upload me.grok.dealdex"
fi
if [[ "$APP_KEY" == "dealdex" && "$BUNDLE_ID" != "net.dealdex" ]]; then
  die "DealDex live bundle is net.dealdex, not ${BUNDLE_ID}"
fi

if [[ -z "$UPLOAD_ONLY_IPA" && "$DRY_RUN" -eq 0 ]]; then
  if [[ "$ALLOW_DIRTY" -eq 0 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      die "not a git repo: $REPO_ROOT (pass --allow-dirty to override)"
    fi
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
      die "dirty worktree at $REPO_ROOT (commit first, or pass --allow-dirty)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SHIP GATE FIRST, THEN THE BUILD NUMBER.
# ---------------------------------------------------------------------------
# Ordering matters and used to be wrong. The gate was evaluated ~60 lines below
# the point where the build counter committed floor+1, so every
# rate-limited attempt burned a version that never shipped (observed live
# 2026-08-12: skipped at 4392s of a 9000s interval, sequence still went 5 -> 6).
#
# Everything the gate needs is already resolved above: APP_KEY, REPO_ROOT (for
# HEAD), EXPORT_ONLY, FORCE_SHIP, STATE_DIR. Nothing between here and the old
# call site set up anything it reads, so moving it earlier drops no step. What
# it now runs BEFORE is: PBXPROJ resolution, the App Store Connect queries
# (the marketing patch and the build floor), the project-version agreement
# check, --sync-project-version, load_secrets, and the output dirs.  No
# number is consumed from a local cache any more:  App Store Connect is the
# only record that shipping advances.
# The dirty-worktree check stays ahead of the gate so a dirty tree still fails
# loudly rather than being masked by a quiet rate-limit skip.
#
# --force-ship and --export-only still bypass the gate exactly as before, and
# --dry-run still reports the gate outcome alongside the version plan (it peeks
# at the version without shipping it, so evaluating early changes nothing for
# it beyond ordering the log lines).
evaluate_ship_gate

# Capture the previously-shipped sha for the TestFlight release notes BEFORE
# anything can rewrite the state file. record_successful_ship() overwrites it
# after ensure_tf_ready, so reading it later happens to work today -- capturing
# it here makes the notes immune to a future reordering, which is exactly the
# class of bug the ship-gate comment above documents.
PREV_SHIP_SHA=""
if [[ -f "$(ship_state_path)" ]]; then
  read -r _prev_ts PREV_SHIP_SHA <"$(ship_state_path)" || true
  [[ "${PREV_SHIP_SHA:-}" != "unknown" ]] || PREV_SHIP_SHA=""
fi
# Which subtree is "this app's iOS code" -- used only as the tie-break when the
# commit range exceeds the release-notes bullet cap.
IOS_PATH_PREFIX="$(dirname "$PROJECT_REL")"

if [[ "$SHIP_GATE_DECISION" == "skip" && "$DRY_RUN" -eq 0 ]]; then
  log "ship-gate: exiting 0 before any version is resolved (nothing consumed)"
  exit 0
fi

# Where the version the project itself declares lives. Best-effort: for
# XcodeGen apps the .xcodeproj may not exist until it is generated below, in
# which case the project contributes 0 to the floor and says so.
PBXPROJ=""
if _proj_dir="$(resolve_project "$REPO_ROOT" "$PROJECT_REL" "$PROJECT_REL_ALT" 2>/dev/null)"; then
  PBXPROJ="${_proj_dir}/project.pbxproj"
fi

# The train the app's numbers live on, per apps.json.  The committed record
# is the source of truth; the two have to agree, and the resolution below
# says so when they do not.
DEFAULT_TRAIN="$(marketing_prefix)"

# The App Store Connect platform key.  "macOS" in apps.json is MAC_OS there.
ASC_PLATFORM="IOS"
if [[ "$PLATFORM" == "macOS" ]]; then
  ASC_PLATFORM="MAC_OS"
fi

# What the version plan is built from.  Printed in the "version plan:" log
# line so the log answers "where did that build number come from?" without
# anyone reading the script.
PLAN_ASC_PATCH="n/a"
PLAN_FLOOR="n/a"
PLAN_TRAIN_FLOOR="n/a"
PLAN_APP_FLOOR="n/a"
PLAN_TRAIN_BUILDS="n/a"
PLAN_RECORD="n/a"
PLAN_READY=0

if [[ -n "$UPLOAD_ONLY_IPA" ]]; then
  # The IPA already carries the versions it was built with. Resolving -- let
  # alone consuming -- a version here would burn a marketing version on a run
  # that cannot possibly use it, which is the same defect as the gate-ordering
  # bug above. It would also drag in the App Store Connect queries' hard
  # failure when ASC is unreachable, blocking a legitimate retry of an
  # already-built IPA.
  MARKETING="(from IPA)"
  BUILD_NUM="(from IPA)"
  log "version: taken from the existing IPA (--upload-only); version neither consulted nor resolved"
else
  PLAN_READY=1

  # ---- the committed record -----------------------------------------------
  # The record in project.yml is the version the last update shipped, and it
  # is what BOTH ship paths read, so one update carries one number on the Mac
  # app and the iPhone app.  It comes through version-number.sh, which also
  # refuses a checkout with no readable git history:  there is no timestamp
  # fallback and no guess.
  RECORD_LINE="$(version_number record)" \
    || die "could not read the committed version record from ${REPO_ROOT}/project.yml.
  The record is the version the last update shipped:  MARKETING_VERSION and
  CURRENT_PROJECT_VERSION, the same string.  Fix the record and re-run."
  read -r RECORD_VERSION RECORD_BUILD <<< "$RECORD_LINE"
  PLAN_RECORD="$RECORD_VERSION"
  RECORD_TRAIN="$(version_prefix "$RECORD_VERSION")"
  [[ -n "$RECORD_TRAIN" ]] || die "the committed version record is not a version string: ${RECORD_VERSION}"
  if [[ -n "$DEFAULT_TRAIN" && "$DEFAULT_TRAIN" != "$RECORD_TRAIN" ]]; then
    logerr "WARNING: the committed record is on the ${RECORD_TRAIN} train, but apps.json says ${DEFAULT_TRAIN}."
    logerr "WARNING: the record wins (it is the committed source of truth).  Update marketingVersionDefault"
    logerr "WARNING: for '${APP_KEY}' in ${APPS_JSON} so the two agree."
  fi

  # ---- the number ---------------------------------------------------------
  # --version is an exact override.  Otherwise the number is one past what
  # the train already holds:  the committed record, and what App Store
  # Connect holds on that train.
  if [[ -n "$FORCE_VERSION" ]]; then
    MARKETING="$FORCE_VERSION"
    PLAN_ASC_PATCH="pinned"
  else
    set +e
    _patch="$(asc_latest_marketing_patch "$RECORD_TRAIN" "$ASC_PLATFORM")"
    _rc=$?
    if [[ $_rc -eq 4 ]]; then
      die "App Store Connect rejected the API key (HTTP 401/403) while reading the next marketing version.
  Fix the key (ASC_* in env or Infisical /asc; fleet-secrets doctor) and re-run.
  --allow-unverified-seq does not cover a rejected credential:  the upload would fail with it too."
    fi
    set -e
    if [[ $_rc -ne 0 || ! "$_patch" =~ ^[0-9]+$ ]]; then
      if [[ "$ALLOW_UNVERIFIED_SEQ" -eq 0 ]]; then
        die "cannot determine the next marketing version.
  App Store Connect could not be consulted.  The number is one past what the
  ${RECORD_TRAIN} train already holds, and App Store Connect is the only record
  of the patches that train holds:  guessing would ship a version that already
  exists (or skip one that does not).
  Fix one of these, then re-run:
    1) restore ASC access: check ASC_* in env or Infisical /asc (fleet-secrets doctor) and that 'node' is on PATH, then
       run: node ${FLEET_DIR}/asc-api.mjs latest-marketing-patch ${BUNDLE_ID} ${RECORD_TRAIN} ${ASC_PLATFORM}
     2) or pin the version explicitly:  --version <X.Y.Z>
        --version is honoured exactly, so the marketing version no longer needs
        App Store Connect.  The build number is still the version.
    3) or, only if you are certain, re-run with --allow-unverified-seq"
      fi
      logerr "WARNING: --allow-unverified-seq set; the marketing version is planned from an UNVERIFIED patch (P=0)"
      _patch=0
    fi
    PLAN_ASC_PATCH="$_patch"

    # The recorded version is usable when it is ahead of everything the train
    # holds:  that is how this path picks up the number the Mac path already
    # chose, so one update carries one number on both platforms.
    _recorded_patch="${RECORD_VERSION##*.}"
    if [[ "$_recorded_patch" =~ ^[0-9]+$ && "$_recorded_patch" -gt "$_patch" ]]; then
      MARKETING="$RECORD_VERSION"
      log "version: the committed record (${RECORD_VERSION}) is ahead of the ${RECORD_TRAIN} train (patch ${_patch}); shipping it"
    else
      MARKETING="$(version_number next --known "$_patch" | awk '{print $1}')"
      [[ -n "$MARKETING" ]] || die "could not resolve the next number from the committed record ${RECORD_VERSION}"
    fi

    # ---- the in-train guard ------------------------------------------------
    # The build number IS the version, so it has to be the highest build in its
    # own marketing train:  the target train must hold no build.  When it does,
    # the number moves on, because a build number has to strictly increase
    # inside a version train.
    _guard=0
    while :; do
      set +e
      _floor_line="$(asc_build_floor "$MARKETING" "$ASC_PLATFORM")"
      _rc=$?
      set -e
      if [[ $_rc -ne 0 || -z "$_floor_line" ]]; then
        if [[ "$ALLOW_UNVERIFIED_SEQ" -eq 0 ]]; then
          die "cannot read the build state of the ${MARKETING} train.
  App Store Connect could not be consulted.  The build number is the version, so
  it must be the highest build in its own train, and App Store Connect is the
  only record of the builds that train holds.
  Fix one of these, then re-run:
    1) restore ASC access: check ASC_* in env or Infisical /asc (fleet-secrets doctor) and that 'node' is on PATH, then
       run: node ${FLEET_DIR}/asc-api.mjs build-floor ${BUNDLE_ID} ${MARKETING} ${ASC_PLATFORM}
     2) or, only if you are certain this train is empty, re-run with --allow-unverified-seq"
        fi
        logerr "WARNING: --allow-unverified-seq set; the build state of the ${MARKETING} train is UNVERIFIED"
        break
      fi
      # "<floor> <train> <app> <train_builds>"
      PLAN_FLOOR="$(printf '%s' "$_floor_line" | awk '{print $1}')"
      PLAN_TRAIN_FLOOR="$(printf '%s' "$_floor_line" | awk '{print $2}')"
      PLAN_APP_FLOOR="$(printf '%s' "$_floor_line" | awk '{print $3}')"
      PLAN_TRAIN_BUILDS="$(printf '%s' "$_floor_line" | awk '{print $4}')"
      [[ "$PLAN_FLOOR" =~ ^[0-9]+$ ]] || PLAN_FLOOR=0
      [[ "$PLAN_TRAIN_FLOOR" =~ ^[0-9]+$ ]] || PLAN_TRAIN_FLOOR=0
      [[ "$PLAN_APP_FLOOR" =~ ^[0-9]+$ ]] || PLAN_APP_FLOOR=0
      [[ "$PLAN_TRAIN_BUILDS" =~ ^[0-9]+$ ]] || PLAN_TRAIN_BUILDS=0
      [[ "$PLAN_TRAIN_BUILDS" -eq 0 ]] && break
      _guard=$((_guard + 1))
      [[ "$_guard" -le 20 ]] || die "the ${RECORD_TRAIN} train still holds builds after 20 attempts; give up and look at App Store Connect by hand."
      _next="$(version_number next --known "${MARKETING##*.}" | awk '{print $1}')"
      log "version: the ${MARKETING} train already holds ${PLAN_TRAIN_BUILDS} build(s); taking ${_next} instead"
      MARKETING="$_next"
    done
  fi

  # ---- the build number ---------------------------------------------------
  # The one-number rule:  the build number IS the version string, so the pair
  # describes one number ("0.1.1 (0.1.1)").  An explicit --build is honoured
  # exactly, and it is the only way to get two different numbers again, so it
  # is logged loudly.
  if [[ -n "$FORCE_BUILD" ]]; then
    BUILD_NUM="$FORCE_BUILD"
    if [[ "$BUILD_NUM" != "$MARKETING" ]]; then
      log "WARNING: --build ${BUILD_NUM} differs from the version ${MARKETING}:  that is two numbers again."
      log "WARNING: the owner ruling (HH-191) is one number:  the build number equals the version."
    fi
    log "version: operator override (--build/--version); the local build-seq counter is not consulted"
  else
    BUILD_NUM="$MARKETING"
  fi
fi

# The two ship paths must agree, and this says whether they do.
#
# The Mac path (scripts/install.sh) reads the same committed record and cannot
# see App Store Connect, so it takes the number one past the record.  This
# path took the number one past what the train holds.  When the shipped
# number is the record, or the one right after it, both platforms carry the
# same number for this update.  When it is further ahead, the record is
# behind and the NOTICE says what to do about it.
if [[ -n "$UPLOAD_ONLY_IPA" ]]; then
  : # no version was resolved for --upload-only; nothing to compare against
elif [[ -n "$PLAN_RECORD" && "$PLAN_RECORD" != "n/a" ]]; then
  _rec_patch="${PLAN_RECORD##*.}"
  _ship_patch="${MARKETING##*.}"
  if [[ "$_rec_patch" =~ ^[0-9]+$ && "$_ship_patch" =~ ^[0-9]+$ ]]; then
    if [[ "$_ship_patch" == "$_rec_patch" ]]; then
      log "agreement: the committed record is ${PLAN_RECORD}; this ship carries that number, so the Mac app and the iPhone app are on one number"
    elif [[ "$_ship_patch" == "$((_rec_patch + 1))" ]]; then
      log "agreement: the Mac app takes the next number from the committed record (${PLAN_RECORD}), which is this one"
    else
      log "NOTICE: the committed record is ${PLAN_RECORD} and this ship carries ${MARKETING}."
      log "NOTICE: App Store Connect already holds a higher patch on the ${RECORD_TRAIN} train, so the Mac app"
      log "NOTICE: (which reads the record only) would take a lower number.  To carry one number on both"
      log "NOTICE: platforms, update the committed record in project.yml to ${MARKETING} and commit it."
    fi
  fi
fi

# Write the resolved version into project.pbxproj so the repo records what
# shipped. Opt-in: it dirties the worktree, and the ship path itself requires a
# clean one.
if [[ "$SYNC_PROJECT_VERSION" -eq 1 ]]; then
  # A dry-run only peeks; nothing is consumed, so the next real ship
  # would exceed whatever we wrote here and the file would be stale again.
  [[ "$DRY_RUN" -eq 0 ]] || die "--sync-project-version cannot be combined with --dry-run.
  A dry-run does not ship anything, so writing ${MARKETING} now would be
  superseded by the next real ship. Pass --sync-project-version on the real ship instead."
  [[ -z "$UPLOAD_ONLY_IPA" ]] || die "--sync-project-version cannot be combined with --upload-only.
  An upload-only run resolves no version of its own — the IPA already carries one — so
  there is nothing to write back. Pass it on the run that builds the archive."
  [[ -n "$PBXPROJ" && -f "$PBXPROJ" ]] || die "--sync-project-version: project.pbxproj not found under $REPO_ROOT"
  /usr/bin/sed -i '' \
    -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${MARKETING};/g" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${BUILD_NUM};/g" \
    "$PBXPROJ"
  log "synced project.pbxproj -> MARKETING_VERSION=${MARKETING} CURRENT_PROJECT_VERSION=${BUILD_NUM}"
  log "commit that change; it is the repo's record of this version"
fi
AUTH_MODE="none"
load_secrets

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_ROOT="${TMPDIR:-/tmp}/ios-ship-${APP_KEY}-${STAMP}"
ARCHIVE_PATH="${OUT_ROOT}/${SCHEME}.xcarchive"
EXPORT_DIR="${OUT_ROOT}/export"
LOG_DIR="${OUT_ROOT}/logs"
mkdir -p "$LOG_DIR"

log "app=${DISPLAY_NAME} key=${APP_KEY}"
log "bundleId=${BUNDLE_ID}"
log "scheme=${SCHEME}"
log "repo=${REPO_ROOT}"
if [[ "$PLAN_READY" -eq 1 ]]; then
  log "version plan: record=${PLAN_RECORD} asc_patch=${PLAN_ASC_PATCH} -> version=${MARKETING}; train builds=${PLAN_TRAIN_BUILDS} -> build=${BUILD_NUM} (one number)"
fi
log "marketing=${MARKETING} build=${BUILD_NUM}"
log "App Store Connect will show this as: ${MARKETING} (${BUILD_NUM})"
log "auth=${AUTH_MODE} export_only=${EXPORT_ONLY} force_ship=${FORCE_SHIP}"
log "out=${OUT_ROOT}"

# The gate already ran, before any build number was consumed. A real run that
# was told to skip exited there; only --dry-run reaches this point still
# holding a "skip" decision, and it reports it as part of the plan.
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$SHIP_GATE_DECISION" == "skip" ]]; then
    log "dry-run: ship-gate would SKIP this run; no build number would be consumed"
  else
    log "dry-run: would archive + ship; exiting"
  fi
  exit 0
fi

if [[ -n "$UPLOAD_ONLY_IPA" ]]; then
  [[ -f "$UPLOAD_ONLY_IPA" ]] || die "package not found: $UPLOAD_ONLY_IPA"
  [[ "$AUTH_MODE" == "api_key" ]] || die "upload-only requires ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 (env) or Infisical /asc (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8)"
  link_private_key "$ASC_KEY_PATH" "$ASC_KEY_ID"
  log "uploading existing package via altool (api key)"
  set +e
  xcrun altool --upload-package "$UPLOAD_ONLY_IPA" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    2>&1 | tee "${LOG_DIR}/upload.log"
  UPLOAD_RC=${PIPESTATUS[0]}
  set -e
  [[ $UPLOAD_RC -eq 0 ]] || die "altool upload failed (rc=$UPLOAD_RC); see ${LOG_DIR}/upload.log"
  record_successful_ship
  log "upload submitted; watch TestFlight processing in App Store Connect"
  exit 0
fi

# Optional XcodeGen regenerate
if [[ -n "$XCODEGEN_DIR" && "$XCODEGEN_DIR" != "null" && "$SKIP_XCODEGEN" -eq 0 ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    log "xcodegen generate in ${REPO_ROOT}/${XCODEGEN_DIR}"
    (cd "${REPO_ROOT}/${XCODEGEN_DIR}" && xcodegen generate) 2>&1 | tee "${LOG_DIR}/xcodegen.log"
  else
    log "xcodegen not installed; using checked-in .xcodeproj"
  fi
fi

PROJECT_PATH="$(resolve_project "$REPO_ROOT" "$PROJECT_REL" "$PROJECT_REL_ALT")" \
  || die "project not found under $REPO_ROOT ($PROJECT_REL / $PROJECT_REL_ALT)"

log "project=${PROJECT_PATH}"

# Archive (device, not simulator). -allowProvisioningUpdates lets Xcode
# download/create App Store distribution profiles for team CC8UTF7ATG.
# Xcode's saved account session can be rejected (observed 2026-08-09:
# "Unable to log in with account ... login details were rejected"), which fails
# automatic signing even when an ASC API key is available. Passing the key
# straight to xcodebuild removes the dependency on the Xcode UI session.
ASC_AUTH_FLAGS=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  _asc_key_expanded="$(expand_tilde "$ASC_KEY_PATH")"
  if [[ -f "$_asc_key_expanded" ]]; then
    ASC_AUTH_FLAGS=(-authenticationKeyPath "$_asc_key_expanded" \
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    log "signing auth: ASC API key"
  fi
fi

# One Mac hosts three Actions runners. Serialize archive/export so two
# xcodebuild archives cannot thrash DerivedData / codesign at once.
ARCHIVE_LOCK_DIR="${STATE_DIR}/archive.lockdir"
acquire_archive_lock() {
  mkdir -p "$STATE_DIR"
  local tries=0
  until mkdir "$ARCHIVE_LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [[ "$tries" -gt 180 ]]; then
      die "archive lock timeout (${ARCHIVE_LOCK_DIR})"
    fi
    log "archive lock busy; waiting (${tries})"
    sleep 10
  done
  # shellcheck disable=SC2064
  trap "rmdir '$ARCHIVE_LOCK_DIR' 2>/dev/null || true; cleanup_asc_tmp" EXIT
}
release_archive_lock() {
  rmdir "$ARCHIVE_LOCK_DIR" 2>/dev/null || true
}

# After a successful upload, declare export compliance if the IPA omitted
# ITSAppUsesNonExemptEncryption. Otherwise TestFlight stays
# MISSING_EXPORT_COMPLIANCE and the phone never sees the build (ST 1.0.1/2
# on 2026-08-12).
ensure_tf_ready() {
  log "verifying TestFlight ready-to-install for ${BUNDLE_ID} build ${BUILD_NUM}"
  set +e
  # BUILD_NUM (CFBundleVersion) is REQUIRED. Without it asc-api.mjs would have to
  # guess "the newest build", which for the first minutes after an upload is the
  # PREVIOUS ship -- so compliance got declared on the wrong build and readiness
  # was reported for a build never inspected (2026-08-13). MARKETING is a second
  # predicate, not a substitute: it identifies a train, not a build.
  IOS_TF_NOTES_REPO="$REPO_ROOT" \
  IOS_TF_NOTES_PREV_SHA="$PREV_SHIP_SHA" \
  IOS_TF_NOTES_APP="$DISPLAY_NAME" \
  IOS_TF_NOTES_IOS_PREFIX="$IOS_PATH_PREFIX" \
  asc_client ensure-tf-ready "$BUNDLE_ID" "$BUILD_NUM" "$MARKETING" \
    >"${LOG_DIR}/ensure-tf-ready.json" 2>"${LOG_DIR}/ensure-tf-ready.err"
  local rc=$?
  set -e
  if [[ -s "${LOG_DIR}/ensure-tf-ready.err" ]]; then
    while IFS= read -r line; do log "tf-ready: $line"; done <"${LOG_DIR}/ensure-tf-ready.err"
  fi
  if [[ $rc -eq 0 ]]; then
    log "TestFlight internal testers can install this build"
    return 0
  fi
  if [[ $rc -eq 3 ]]; then
    log "warning: upload succeeded but ASC has not reached IN_BETA_TESTING yet; watch TestFlight"
    return 0
  fi
  if [[ $rc -eq 4 ]]; then
    # The upload itself succeeded; ASC simply never surfaced the build in time.
    # Warn loudly but do NOT fail: the caller must still record_successful_ship,
    # or the rate gate never advances and the next scheduled run re-ships the
    # same HEAD. A red job after a successful upload also mislabels the outcome.
    log "warning: ASC never surfaced build ${BUILD_NUM}; export compliance NOT declared on it"
    log "warning: if the phone never gets this build, declare compliance by hand in App Store Connect"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "::warning::ensure-tf-ready could not find uploaded build ${BUILD_NUM} for ${BUNDLE_ID}; export compliance not declared"
    fi
    return 0
  fi
  # rc=2 is a usage error or an ASC API error. Compliance was NOT declared, so
  # this deserves the same CI annotation rc=4 gets -- otherwise the only trace
  # is one log line inside a green job, which is how ST 1.0.1/2 stayed
  # VALID-but-uninstallable without anyone noticing.
  log "warning: ensure-tf-ready failed (rc=$rc); build may be stuck on export compliance"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::ensure-tf-ready failed (rc=${rc}) for ${BUNDLE_ID} build ${BUILD_NUM}; export compliance not declared"
  fi
  return 0
}

acquire_archive_lock
log "archiving..."
set +e
if [[ "$PLATFORM" == "macOS" ]]; then
  ARCHIVE_PLATFORM_FLAGS=(-destination "generic/platform=macOS")
else
  ARCHIVE_PLATFORM_FLAGS=(-destination "generic/platform=iOS")
fi

SENTRY_DSN_FLAGS=()
if [[ -n "${SENTRY_DSN:-}" ]]; then
  SENTRY_DSN_FLAGS+=(SENTRY_DSN="$SENTRY_DSN")
  log "SENTRY_DSN present for archive (length ${#SENTRY_DSN})"
else
  log "SENTRY_DSN unset; Cocoa no-ops when the plist value is empty"
fi

xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  "${ARCHIVE_PLATFORM_FLAGS[@]}" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$MARKETING" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  ${SENTRY_DSN_FLAGS[@]:+"${SENTRY_DSN_FLAGS[@]}"} \
  2>&1 | tee "${LOG_DIR}/archive.log"
ARCHIVE_RC="${PIPESTATUS[0]:-$?}"
set -e
[[ $ARCHIVE_RC -eq 0 ]] || die "archive failed (rc=$ARCHIVE_RC); see ${LOG_DIR}/archive.log"
upload_sentry_artifacts

EXPORT_PLIST_UPLOAD="${FLEET_DIR}/ExportOptions-appstore.plist"
EXPORT_PLIST_IPA="${FLEET_DIR}/ExportOptions-export-ipa.plist"

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  log "exporting package only..."
  mkdir -p "$EXPORT_DIR"
  set +e
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST_IPA" \
    -allowProvisioningUpdates \
    ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
    2>&1 | tee "${LOG_DIR}/export.log"
  EXPORT_RC=${PIPESTATUS[0]}
  set -e
  [[ $EXPORT_RC -eq 0 ]] || die "export failed (rc=$EXPORT_RC); see ${LOG_DIR}/export.log"
  PACKAGE="$(ls -1 "$EXPORT_DIR"/*.ipa "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1 || true)"
  [[ -n "$PACKAGE" ]] || die "no IPA or PKG produced in $EXPORT_DIR"
  log "Package ready: $PACKAGE"
  log "Upload later: bash $0 $APP_KEY --upload-only \"$PACKAGE\""
  exit 0
fi

# Prefer: export with destination=upload (uses Xcode session OR ASC if configured in Xcode)
log "exporting + uploading to App Store Connect..."
mkdir -p "$EXPORT_DIR"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST_UPLOAD" \
  -allowProvisioningUpdates \
  ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
  2>&1 | tee "${LOG_DIR}/export-upload.log"
EXPORT_RC=${PIPESTATUS[0]}
set -e

if [[ $EXPORT_RC -eq 0 ]]; then
  log "upload path succeeded via xcodebuild export (destination=upload)"
  log "build ${MARKETING} (${BUILD_NUM}) submitted for ${BUNDLE_ID}"
  release_archive_lock
  ensure_tf_ready
  record_successful_ship
  log "logs: ${LOG_DIR}"
  exit 0
fi

log "xcodebuild upload export failed (rc=$EXPORT_RC); trying local export + altool"

mkdir -p "$EXPORT_DIR"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST_IPA" \
  -allowProvisioningUpdates \
  ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
  2>&1 | tee "${LOG_DIR}/export-ipa.log"
EXPORT_RC=${PIPESTATUS[0]}
set -e
[[ $EXPORT_RC -eq 0 ]] || die "export failed (rc=$EXPORT_RC); see ${LOG_DIR}/export-ipa.log and ${LOG_DIR}/export-upload.log"

PACKAGE="$(ls -1 "$EXPORT_DIR"/*.ipa "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1 || true)"
[[ -n "$PACKAGE" ]] || die "no IPA or PKG produced in $EXPORT_DIR"

# Re-load secrets before altool: long xcodebuild sessions can leave ASC_*
# unset under `set -u` even when AUTH_MODE was api_key at plan time.
load_secrets
if [[ "$AUTH_MODE" != "api_key" ]]; then
  log "Package ready at: $PACKAGE"
  log "Upload blocked: no App Store Connect API key."
  log "Owner handoff:"
  log "  1) Create ASC API key (App Manager+) in App Store Connect"
  log "  2) Store ASC_KEY_ID and ASC_ISSUER_ID in Infisical Fleet-OPS /asc"
  log "  3) Store the .p8 contents as ASC_KEY_P8 in the same Infisical folder"
  log "  4) Or export ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 for this run"
  log "  5) Re-run: bash $0 $APP_KEY --upload-only \"$PACKAGE\""
  log "Also ensure App Store Connect has an app record for ${BUNDLE_ID}."
  exit 3
fi

link_private_key "${ASC_KEY_PATH}" "${ASC_KEY_ID}"
log "uploading package via altool (api key)"
set +e
xcrun altool --upload-package "$PACKAGE" \
  --apiKey "${ASC_KEY_ID}" \
  --apiIssuer "${ASC_ISSUER_ID}" \
  2>&1 | tee "${LOG_DIR}/upload.log"
UPLOAD_RC=${PIPESTATUS[0]}
set -e
if [[ $UPLOAD_RC -ne 0 ]]; then
  log "altool failed (rc=$UPLOAD_RC). Common cause: no App Store Connect app for ${BUNDLE_ID}."
  log "Create the app in ASC (My Apps → +) with this exact bundle id, then:"
  log "  bash $0 $APP_KEY --upload-only \"$PACKAGE\""
  die "altool upload failed (rc=$UPLOAD_RC); see ${LOG_DIR}/upload.log"
fi

release_archive_lock
ensure_tf_ready
record_successful_ship
log "upload submitted; watch TestFlight processing for ${BUNDLE_ID} build ${BUILD_NUM}"
log "logs: ${LOG_DIR}"
exit 0
