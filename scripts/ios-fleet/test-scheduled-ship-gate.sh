#!/usr/bin/env bash
# test-scheduled-ship-gate.sh - Offline tests for scheduled-ship-gate.sh.
#
# The gate is the only thing standing between a half-hourly cron and a
# TestFlight build for every backend commit. Without these tests a defect in it
# is invisible until either testers get spammed or an iOS change silently never
# ships. Section 9 covers the repeatable --path-prefix that CodeCaps needs for
# the shared Sources/QuotaCore files its iOS targets compile. Sections 10-12
# cover the owner rule of 2026-10-29 (a merge the push trigger would have
# shipped must still ship when the push event was missed): the gate takes the
# workflow's push paths verbatim, machinery and ! exclusions included, with
# GitHub glob semantics. Everything here is a throwaway git repo in a scratch
# dir: no network, no credentials, no xcodebuild, no App Store Connect.
#
# Usage: bash scripts/ios-fleet/test-scheduled-ship-gate.sh
#
# ASCII-only (Apple bash 3.2 safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="${SCRIPT_DIR}/scheduled-ship-gate.sh"
[[ -f "$GATE" ]] || { echo "missing $GATE"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ship-gate-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

REPO="${TMP}/repo"
STATE="${TMP}/state"
mkdir -p "$REPO" "$STATE"

git -C "$REPO" init --quiet -b main
git -C "$REPO" config user.email "test@example.invalid"
git -C "$REPO" config user.name "gate test"

commit() {
  # commit <path> <content> <message>
  mkdir -p "$(dirname "${REPO}/$1")"
  printf '%s\n' "$2" >"${REPO}/$1"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "$3"
  git -C "$REPO" rev-parse HEAD
}

PASS=0
FAIL=0
check() {
  # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  ok  : $1 (=$3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAIL=$((FAIL + 1))
  fi
}

PREFIX_ARGS=(--path-prefix "ios/")

run_gate() {
  # run_gate <event> [extra args...] -> prints "key=value" lines
  local event="$1"; shift
  bash "$GATE" \
    --event "$event" \
    "${PREFIX_ARGS[@]}" \
    --repo-root "$REPO" \
    --state-dir "$STATE" \
    "$@" 2>&1
}

field() {
  # field <output> <key>
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k {print $2}' | tail -1
}

set_state() {
  # set_state <app> <sha>
  printf '%s %s\n' "$(date +%s)" "$2" >"${STATE}/last-ship-$1.txt"
}

echo "== syntax =="
bash -n "$GATE" && echo "  ok  : scheduled-ship-gate.sh parses"

echo "== fixture =="
BASE="$(commit README.md base "base")"
echo "  base commit ${BASE:0:10}"

echo "== 1. push/dispatch events bypass the gate entirely =="
out="$(run_gate push demo)"
check "push -> should_ship" 1 "$(field "$out" should_ship)"
out="$(run_gate workflow_dispatch demo)"
check "workflow_dispatch -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 2. scheduled tick with no ship history skips (hosted runner is empty) =="
out="$(run_gate schedule demo)"
check "no state -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 3. scheduled tick on an already-shipped HEAD skips =="
set_state demo "$BASE"
out="$(run_gate schedule demo)"
check "HEAD already shipped -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 4. backend-only commits since the last ship do NOT ship =="
commit "server/api.ts" "backend change" "feat(server): unrelated to iOS" >/dev/null
commit "docs/notes.md" "docs" "docs: nothing an iOS tester can see" >/dev/null
out="$(run_gate schedule demo)"
check "backend-only -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 5. an iOS change since the last ship DOES ship =="
commit "ios/App/View.swift" "// ui" "fix(ios): visible change" >/dev/null
out="$(run_gate schedule demo)"
check "ios change -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 6. per-app outputs are independent =="
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
set_state demo "$HEAD_SHA"          # caught up
set_state demo-local "$BASE"        # behind, and iOS changed since BASE
out="$(run_gate schedule demo demo-local)"
check "caught-up app" 0 "$(field "$out" ship_demo)"
check "behind app" 1 "$(field "$out" ship_demo_local)"
check "any-app roll-up" 1 "$(field "$out" should_ship)"

echo "== 7. an unreachable last-ship sha falls back to the recorded timestamp =="
# Observed live on Usage-Monitor 2026-08-13: the recorded ship sha was the tip
# of a grok/* ship worktree, not an ancestor of main. Skipping forever would
# make the backstop useless; shipping blind would spam TestFlight.
rm -f "${STATE}/last-ship-demo-local.txt"
FUTURE=$(( $(date +%s) + 600 ))
printf '%s %s\n' "$FUTURE" "0000000000000000000000000000000000000000" >"${STATE}/last-ship-demo.txt"
out="$(run_gate schedule demo)"
check "unreachable sha, no newer iOS commits -> should_ship" 0 "$(field "$out" should_ship)"

PAST=$(( $(date +%s) - 86400 ))
printf '%s %s\n' "$PAST" "0000000000000000000000000000000000000000" >"${STATE}/last-ship-demo.txt"
out="$(run_gate schedule demo)"
check "unreachable sha, iOS commits since -> should_ship" 1 "$(field "$out" should_ship)"

printf 'not-a-timestamp deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >"${STATE}/last-ship-demo.txt"
out="$(run_gate schedule demo)"
check "unreachable sha, unusable ts -> defers to ship script" 1 "$(field "$out" should_ship)"

# Back to a clean skip state for the exit-code assertion below.
set_state demo "$(git -C "$REPO" rev-parse HEAD)"

echo "== 8. deciding 'skip' is never an error exit =="
run_gate schedule demo >/dev/null
check "exit code on skip" 0 "$?"

echo "== 9. a repeatable --path-prefix counts a change under ANY prefix =="
# CodeCaps compiles a handful of shared Sources/QuotaCore files into the iOS
# app and widgets.  A change to one of those must ship; a Mac-only QuotaCore
# file must not (TestFlight is not a commit log).
PREFIX_ARGS=(--path-prefix "ios/" --path-prefix "shared/Used.swift")
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "shared/Unused.swift" "// mac only" "fix: a file the iOS targets do not compile" >/dev/null
out="$(run_gate schedule demo)"
check "unlisted shared file -> should_ship" 0 "$(field "$out" should_ship)"
commit "shared/Used.swift" "// compiled into iOS" "fix: a file the iOS targets compile" >/dev/null
out="$(run_gate schedule demo)"
check "listed shared file -> should_ship" 1 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "ios/App/Other.swift" "// ui again" "fix(ios): second prefix does not mask the first" >/dev/null
out="$(run_gate schedule demo)"
check "first prefix still ships with two prefixes" 1 "$(field "$out" should_ship)"
printf '%s' "$out" | grep -q "ios/, shared/Used.swift" \
  && echo "  ok  : log names every prefix" \
  || { echo "  FAIL: log does not name every prefix"; FAIL=$((FAIL + 1)); }
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
bash "$GATE" --event schedule --path-prefix "" --repo-root "$REPO" --state-dir "$STATE" demo >/dev/null 2>&1
check "empty --path-prefix is refused (exit)" 2 "$?"
bash "$GATE" --event schedule --repo-root "$REPO" --state-dir "$STATE" demo >/dev/null 2>&1
check "missing --path-prefix is refused (exit)" 2 "$?"
PREFIX_ARGS=(--path-prefix "ios/")

echo "== 10. a machinery-only merge the push would have shipped DOES ship =="
# Owner rule 2026-10-29: the cron is the backstop for a missed push event
# (workflow disabled at merge time, GitHub dropping the event, bot merge).
# Patterns below are the push-path shapes from ios-testflight.yml.
PREFIX_ARGS=(--path-prefix "ios/**" --path-prefix "project.yml" \
  --path-prefix ".github/workflows/ios-testflight.yml" \
  --path-prefix "scripts/ios-*.sh" --path-prefix "scripts/ios-fleet/**" \
  --path-prefix "!scripts/ios-fleet/test-*.sh" \
  --path-prefix "!scripts/ios-fleet/README.md")
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
out="$(run_gate schedule demo)"
check "HEAD already shipped still skips with push paths" 0 "$(field "$out" should_ship)"
commit "scripts/ios-fleet/ship-testflight.sh" "# ship fix" "fix(ship): machinery-only merge" >/dev/null
out="$(run_gate schedule demo)"
check "ship-tooling-only merge -> should_ship" 1 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit ".github/workflows/ios-testflight.yml" "# workflow" "fix(ci): touch the ship workflow" >/dev/null
out="$(run_gate schedule demo)"
check "workflow-file-only merge -> should_ship" 1 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "project.yml" "# project" "fix(build): touch project.yml" >/dev/null
out="$(run_gate schedule demo)"
check "project.yml-only merge -> should_ship" 1 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-ship-testflight.sh" "# wrapper" "fix(ship): touch the wrapper" >/dev/null
out="$(run_gate schedule demo)"
check "scripts/ios-*.sh merge -> should_ship" 1 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "ios/App/View2.swift" "// ui" "fix(ios): ios/** still ships" >/dev/null
out="$(run_gate schedule demo)"
check "ios/** merge -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 11. excluded and unrelated merges still skip =="
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-fleet/test-foo.sh" "# test" "test: gate test file is excluded" >/dev/null
out="$(run_gate schedule demo)"
check "excluded test-*.sh -> should_ship" 0 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-fleet/README.md" "# docs" "docs: fleet readme is excluded" >/dev/null
out="$(run_gate schedule demo)"
check "excluded README -> should_ship" 0 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "README.md" "readme change" "docs: top-level readme" >/dev/null
commit "server/api2.ts" "backend" "feat(server): still unrelated" >/dev/null
commit "scripts/test-ios-release.py" "# contract" "test: non-ship script" >/dev/null
out="$(run_gate schedule demo)"
check "unrelated-only merges -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 12. globs follow GitHub semantics (* stays in-segment, ** crosses) =="
PREFIX_ARGS=(--path-prefix "scripts/ios-*.sh")
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-fleet/nested.sh" "# nested" "fix: * must not cross /" >/dev/null
out="$(run_gate schedule demo)"
check "scripts/ios-*.sh does not match a nested path" 0 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-x.sh" "# top level" "fix: * matches in-segment" >/dev/null
out="$(run_gate schedule demo)"
check "scripts/ios-*.sh matches a top-level script" 1 "$(field "$out" should_ship)"
PREFIX_ARGS=(--path-prefix "scripts/ios-fleet/**")
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-fleet/a/b.sh" "# deep" "fix: ** crosses /" >/dev/null
out="$(run_gate schedule demo)"
check "scripts/ios-fleet/** matches a nested path" 1 "$(field "$out" should_ship)"
PREFIX_ARGS=(--path-prefix "scripts/ios-fleet/**" --path-exclude "scripts/ios-fleet/test-*.sh")
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "scripts/ios-fleet/test-alias.sh" "# test" "test: --path-exclude alias" >/dev/null
out="$(run_gate schedule demo)"
check "--path-exclude behaves like a ! prefix" 0 "$(field "$out" should_ship)"
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
bash "$GATE" --event schedule --path-prefix "!" --repo-root "$REPO" --state-dir "$STATE" demo >/dev/null 2>&1
check "bare ! --path-prefix is refused (exit)" 2 "$?"
PREFIX_ARGS=(--path-prefix "ios/")

echo
echo "passed=${PASS} failed=${FAIL}"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "scheduled-ship-gate: all tests passed"
