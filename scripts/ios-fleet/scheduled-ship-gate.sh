#!/usr/bin/env bash
# scheduled-ship-gate.sh - Decide whether a SCHEDULED ios-ship run should ship.
#
# Why this exists
# ---------------
# .github/workflows/ios-ship.yml gained a `schedule:` trigger because a PR
# merged by github-actions[bot] lands on main under GitHub's recursion guard
# and dispatches no workflow run at all -- so `push:` alone could not be
# trusted to notice that iOS code had landed. Measured on this repo: sha
# c38b6787 (PR #1835, bot-merged, touches clients/ios) produced ZERO runs,
# while sha ceaca097 (PR #1836, human-merged) produced five.
#
# But a cron carries no `paths:` filter, and ship-testflight.sh's own gate only
# tests "is HEAD the sha I last shipped" plus a time interval. Without this
# script, a backend-only commit sitting past the rate-limit window would ship a
# TestFlight build for changes no tester can see. The owner does not want
# TestFlight spammed, so the scheduled path ships only when a path the
# workflow's own push filter would have shipped actually changed since the
# last successful ship. Owner rule 2026-10-29: unless a merge built recently
# it should automatically build, so the gate takes EVERY push path (native
# tree plus ship machinery) and a missed push still ships on the next tick.
#
# Usage:
#   scheduled-ship-gate.sh --path-prefix <pattern> [options] <app_key> [app_key...]
#
# Options:
#   --path-prefix P   Repo-relative path pattern that counts as shippable
#                     (required, repeatable; e.g. ios/** or ios/).  Pass the
#                     workflow's own on.push.paths list verbatim: globs follow
#                     GitHub filter semantics (** crosses /, * and ? stay
#                     within one path segment), a trailing-slash dir/ is a
#                     plain prefix, anything else without glob characters is
#                     one exact file (or a directory, which matches the tree
#                     under it), and a leading ! excludes (last match wins,
#                     exactly like push.paths).  Order matters, so keep the
#                     push order including the ! entries at the end.  A single
#                     --path-prefix dir/ keeps working as before.
#   --path-exclude P  Shorthand for --path-prefix '!P' (repeatable).
#   --event NAME      GitHub event name (default: $GITHUB_EVENT_NAME).
#                     Anything other than "schedule" votes ship=1 for every
#                     app: a push already passed the workflow's paths filter,
#                     and a manual dispatch is an explicit instruction.
#   --repo-root PATH  Repo to inspect (default: cwd)
#   --state-dir PATH  Where ship-testflight.sh records successful ships
#                     (default: $IOS_FLEET_STATE_DIR, else ~/.cache/ios-fleet)
#
# Output:
#   Human-readable reasoning on stdout, plus, when $GITHUB_OUTPUT is set:
#     should_ship=0|1        1 if ANY listed app should ship
#     ship_<app_key>=0|1     per app, with '-' in the key replaced by '_'
#
# Exit code is always 0 on a decision. Deciding "skip" is a normal outcome and
# must never turn a scheduled tick red.
#
# ASCII-only (Apple bash 3.2 safe), matches ship-testflight.sh conventions.

set -uo pipefail

PATH_PREFIXES=()
EVENT="${GITHUB_EVENT_NAME:-}"
REPO_ROOT=""
STATE_DIR="${IOS_FLEET_STATE_DIR:-${HOME}/.cache/ios-fleet}"
APPS=""

die() { echo "error: $*" >&2; exit 2; }
log() { echo "[ship-gate] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path-prefix) PATH_PREFIXES+=("${2:-}"); shift 2 ;;
    --path-exclude) PATH_PREFIXES+=("!${2:-}"); shift 2 ;;
    --event) EVENT="${2:-}"; shift 2 ;;
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,${/^[^#]/q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    -*) die "unknown option: $1" ;;
    *) APPS="${APPS} $1"; shift ;;
  esac
done

[[ -n "${PATH_PREFIXES[0]:-}" ]] || die "--path-prefix is required"
# Every prefix must be non-empty: an empty pathspec would match the whole repo.
for _p in "${PATH_PREFIXES[@]}"; do
  [[ -n "$_p" ]] || die "--path-prefix must not be empty"
  [[ "$_p" != "!" ]] || die "--path-prefix must not be a bare '!'"
done
# One printable list for the log lines (comma-separated).
PATHS_DESC=""
for _p in "${PATH_PREFIXES[@]}"; do
  PATHS_DESC="${PATHS_DESC:+${PATHS_DESC}, }${_p}"
done
[[ -n "${APPS// /}" ]] || die "at least one app key is required"

if [[ -z "$REPO_ROOT" ]]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)" || die "bad --repo-root"

# GitHub push-paths matching, as closely as bash 3.2 allows. A changed file is
# selected when the LAST matching pattern is an include: includes set it, a !
# exclusion clears it. Patterns are evaluated in the order given, so the gate
# call keeps the on.push.paths order verbatim.
_GP=()
_GF=()
_GPLEN=0
_GFLEN=0

_match_at() {
  # _match_at <pattern_index> <file_index>; uses _GP/_GF Globals.
  local pi="$1" fi="$2" seg fseg k
  if [[ "$pi" -ge "$_GPLEN" ]]; then
    [[ "$fi" -ge "$_GFLEN" ]] && return 0 || return 1
  fi
  seg="${_GP[$pi]}"
  if [[ "$seg" == "**" ]]; then
    if [[ "$((pi + 1))" -ge "$_GPLEN" ]]; then
      return 0
    fi
    k="$fi"
    while [[ "$k" -le "$_GFLEN" ]]; do
      if _match_at "$((pi + 1))" "$k"; then
        return 0
      fi
      k="$((k + 1))"
    done
    return 1
  fi
  [[ "$fi" -ge "$_GFLEN" ]] && return 1
  fseg="${_GF[$fi]}"
  case "$seg" in
    *\*\**) seg="${seg//\*\*/\*}" ;;
  esac
  # Unquoted $seg is the shell pattern (* ? [...] stay in-segment because a
  # segment never holds a slash); quoted would compare literally.
  # shellcheck disable=SC2053
  if [[ "$fseg" == $seg ]]; then
    _match_at "$((pi + 1))" "$((fi + 1))"
  else
    return 1
  fi
}

_glob_match() {
  # _glob_match <pattern> <file>: ** crosses /, * and ? do not.
  local pattern="$1" file="$2" oldifs="$IFS"
  IFS='/'
  set -f
  _GP=($pattern)
  _GF=($file)
  set +f
  IFS="$oldifs"
  _GPLEN="${#_GP[@]}"
  _GFLEN="${#_GF[@]}"
  _match_at 0 0
}

_pattern_matches() {
  # _pattern_matches <pattern> <file> (pattern without any leading !).
  local pattern="$1" file="$2"
  case "$pattern" in
    *\**|*\?*|*\[*)
      _glob_match "$pattern" "$file"
      return "$?"
      ;;
  esac
  case "$pattern" in
    */)
      # Plain dir/ prefix, the pre-glob calling convention.
      case "$file" in
        "${pattern}"*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  # Exact file, or a directory naming the tree under it.
  [[ "$file" == "$pattern" ]] && return 0
  case "$file" in
    "${pattern}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

_selected() {
  # _selected <file>: true when push.paths would have shipped a push of it.
  local file="$1" pat rest selected=1
  for pat in "${PATH_PREFIXES[@]}"; do
    case "$pat" in
      !*)
        rest="${pat#!}"
        if _pattern_matches "$rest" "$file"; then
          selected=1
        fi
        ;;
      *)
        if _pattern_matches "$pat" "$file"; then
          selected=0
        fi
        ;;
    esac
  done
  return "$selected"
}

_filter_selected() {
  # _filter_selected: stdin is newline-separated changed paths, stdout is the
  # selected ones (at most 20, for the log). Prints nothing when none match.
  local f count=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if _selected "$f"; then
      printf '%s\n' "$f"
      count="$((count + 1))"
      [[ "$count" -ge 20 ]] && break
    fi
  done
  return 0
}

emit() {
  # emit <key> <value>
  echo "$1=$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

out_key() {
  # App keys carry '-' (usage-local); GitHub step outputs read better with '_'.
  printf 'ship_%s' "$(printf '%s' "$1" | tr '-' '_')"
}

if [[ "$EVENT" != "schedule" ]]; then
  log "event='${EVENT}': not the scheduled backstop, so intent is already explicit."
  for app in $APPS; do emit "$(out_key "$app")" 1; done
  emit should_ship 1
  exit 0
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$HEAD_SHA" ]]; then
  # No git, no ability to reason about what changed. Do NOT ship on a guess.
  log "cannot resolve HEAD in ${REPO_ROOT}; scheduled tick skips."
  for app in $APPS; do emit "$(out_key "$app")" 0; done
  emit should_ship 0
  exit 0
fi

SHOULD_ANY=0
for app in $APPS; do
  state="${STATE_DIR}/last-ship-${app}.txt"
  decision=0

  if [[ ! -f "$state" ]]; then
    # Hosted runners start with an empty home.  Treating that as "never
    # shipped" re-archives every cron tick.  A first ship is a push that
    # already passed paths: or an explicit workflow_dispatch.
    log "[${app}] no prior ship recorded (${state}); scheduled tick skips."
    decision=0
  else
    # Format written by record_successful_ship(): "<unix_ts> <git_sha>"
    last_sha="$(awk 'NR==1{print $2}' "$state" 2>/dev/null || true)"
    if [[ -z "${last_sha:-}" || "$last_sha" == "unknown" ]]; then
      log "[${app}] ship state carries no sha; letting ship-testflight.sh decide."
      decision=1
    elif [[ "$last_sha" == "$HEAD_SHA" ]]; then
      log "[${app}] HEAD ${HEAD_SHA} already shipped; skip."
    elif ! git -C "$REPO_ROOT" merge-base --is-ancestor "$last_sha" HEAD 2>/dev/null; then
      git -C "$REPO_ROOT" fetch --deepen=200 --quiet 2>/dev/null || true
      if git -C "$REPO_ROOT" merge-base --is-ancestor "$last_sha" HEAD 2>/dev/null; then
        log "[${app}] deepened the clone to reach ${last_sha}."
        decision=-1
      else
        # Real and observed, not hypothetical: on 2026-08-13 Usage-Monitor's
        # recorded ship sha was 27b89434, the tip of a grok/* ship worktree --
        # not an ancestor of main at all. Skipping forever on that would be a
        # backstop that never backstops; shipping blind would be TestFlight
        # spam. So fall back to the TIMESTAMP the same state file records and
        # ask a question that needs no sha: has any commit touching this app
        # landed since the last successful ship?
        log "[${app}] last shipped sha ${last_sha} is unreachable from HEAD (shipped from another worktree/branch, or history was rewritten)."
        last_ts="$(awk 'NR==1{print $1}' "$state" 2>/dev/null || true)"
        if [[ "${last_ts:-}" =~ ^[0-9]+$ ]]; then
          _since_all="$(git -C "$REPO_ROOT" log --since="@${last_ts}" --format= --name-only 2>/dev/null | sed '/^$/d' | sort -u || true)"
          since_changed="$(printf '%s\n' "$_since_all" | _filter_selected || true)"
          if [[ -n "$since_changed" ]]; then
            log "[${app}] falling back to time: ${PATHS_DESC} changed after the last ship:"
            # Line-by-line, NOT `printf ... $var`: Socratic.Trade's iOS path is
            # "ios/Socratic Trade.xcodeproj/...", and unquoted word-splitting
            # printed that one file as two bogus lines. Decision logic is
            # unaffected; the log was just lying about what changed.
            printf '%s\n' "$since_changed" | while IFS= read -r f; do echo "  $f"; done
            decision=1
          else
            log "[${app}] falling back to time: no ${PATHS_DESC} commits since the last ship; skip."
          fi
        else
          log "[${app}] state has no usable timestamp either; letting ship-testflight.sh decide."
          decision=1
        fi
      fi
    else
      decision=-1
    fi

    if [[ "$decision" -eq -1 ]]; then
      # Reachable range: the only case where a real diff is meaningful.
      # The full name list is filtered in-script (never by git pathspecs or
      # by piping into an early-exiting grep, which SIGPIPEs git under
      # pipefail): only the in-script filter knows the ! exclusions and the
      # GitHub **-vs-* distinction.
      _changed_all="$(git -C "$REPO_ROOT" diff --name-only "$last_sha" HEAD 2>/dev/null || true)"
      changed="$(printf '%s\n' "$_changed_all" | _filter_selected || true)"
      if [[ -n "$changed" ]]; then
        log "[${app}] ${PATHS_DESC} changed since ${last_sha}:"
        printf '%s\n' "$changed" | while IFS= read -r f; do echo "  $f"; done
        decision=1
      else
        log "[${app}] no ${PATHS_DESC} changes since ${last_sha}; skip (TestFlight is not a commit log)."
        decision=0
      fi
    fi
  fi

  emit "$(out_key "$app")" "$decision"
  if [[ "$decision" -eq 1 ]]; then SHOULD_ANY=1; fi
done

emit should_ship "$SHOULD_ANY"
if [[ "$SHOULD_ANY" -eq 0 ]]; then
  log "scheduled tick: nothing to ship."
fi
exit 0
