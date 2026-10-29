#!/usr/bin/env bash
# plan-release-build ship-helper tests: the pairedBuildFeed fetch is bounded and
# fails closed with the feed URL in the message, the merge stamp of HEAD joins
# the client call, the planned 12-digit build is validated, and the paired
# bundle id reaches the node client (pairedBundleId preferred, macBundleId as
# the alias, reverse lookup for a macOS entry with neither).  The
# max-platform-build helper and the build_exceeds comparison behind the
# fixed-mode --build check are covered too.
#
# Offline: a fake curl, a fake node client, a fixture apps.json and a fixture
# git repo with a fixed committer date.  No network, no App Store Connect, no
# secrets.  The helpers are extracted from ship-testflight.sh the way
# test-asc-credentials.sh extracts load_secrets.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/ship-testflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="${tmp}/tmp"
mkdir -p "$TMPDIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

FEED_URL="https://feeds.example.invalid/ios.xml"
HTTP_FEED_URL="http://feeds.example.invalid/ios.xml"
# The planned build the fake client answers with when CLIENT_BUILD is unset.
FAKE_BUILD="202610290531"

# Fixture repo: one commit with a fixed committer date, so the merge stamp is
# deterministic.  2026-10-20 12:00 -0500 is 12:00 on the America/Chicago clock.
gitrepo="${tmp}/repo"
mkdir -p "$gitrepo"
git -c init.defaultBranch=main init -q "$gitrepo"
git -C "$gitrepo" config user.email test@example.invalid
git -C "$gitrepo" config user.name Test
GIT_COMMITTER_DATE="2026-10-20 12:00:00 -0500" GIT_AUTHOR_DATE="2026-10-20 12:00:00 -0500" \
  git -C "$gitrepo" commit -q --allow-empty -m fixture
STAMP="$(TZ=America/Chicago git -C "$gitrepo" show -s --format=%cd --date=format-local:%Y%m%d%H%M HEAD)"
[[ "$STAMP" == "202610201200" ]] || fail "fixture stamp is $STAMP, want 202610201200"
export REPO_ROOT="$gitrepo"
export ASC_PLATFORM="IOS"

cat > "${tmp}/apps.json" <<JSON
{"apps": {
  "ios-paired": {"bundleId": "com.example.ios", "pairedBundleId": "com.example.mac", "macBundleId": "com.example.mac-legacy", "pairedBuildFeed": "${FEED_URL}"},
  "ios-alias": {"bundleId": "com.example.ios", "macBundleId": "com.example.mac", "pairedBuildFeed": "${FEED_URL}"},
  "mac-paired": {"bundleId": "com.example.mac", "pairedBundleId": "com.example.ios"},
  "solo": {"bundleId": "com.example.solo"},
  "ios-http": {"bundleId": "com.example.ios", "pairedBundleId": "com.example.mac", "pairedBuildFeed": "${HTTP_FEED_URL}"},
  "ios-peer": {"bundleId": "com.example.ios2", "pairedBundleId": "com.example.mac2"},
  "mac-orphan": {"bundleId": "com.example.mac2", "platform": "macOS"},
  "ios-peer4": {"bundleId": "com.example.ios4", "pairedBundleId": "com.example.mac4"},
  "lonely-mac": {"bundleId": "com.example.mac4"},
  "ios-orphan": {"bundleId": "com.example.ios3"},
  "mac-points": {"bundleId": "com.example.mac3", "platform": "macOS", "pairedBundleId": "com.example.ios3"}
}}
JSON

# Fake curl: records its argv, then answers from CURL_MODE.  Never touches the
# network: the feed URLs are under .invalid.
cat > "${tmp}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_ARGS_FILE:?}"
case "${CURL_MODE:?}" in
  ok)
    printf '%s\n' '<?xml version="1.0"?>' '<rss><channel>' \
      '<item><sparkle:version>1200</sparkle:version></item>' \
      '<item><sparkle:version>1400</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  fail)
    echo "curl: (28) Timeout was reached" >&2
    exit 28
    ;;
  empty) exit 0 ;;
  noversion)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>1.0.2</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  padded)
    tab="$(printf '\t')"
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>  1200  </sparkle:version></item>' \
      "<item><sparkle:version>${tab}1400${tab}</sparkle:version></item>" \
      '</channel></rss>'
    ;;
  big)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>9999</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  zero)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>0</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  huge)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>10000</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  huge18)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>123456789012345678</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  giant)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>1234567890123456789</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  edge)
    printf '%s\n' '<rss><channel>' \
      '<item><sparkle:version>1</sparkle:version></item>' \
      '<item><sparkle:version>9998</sparkle:version></item>' \
      '</channel></rss>'
    ;;
  *) echo "curl: unknown CURL_MODE ${CURL_MODE}" >&2; exit 2 ;;
esac
FAKE
chmod +x "${tmp}/curl"

# Fake node client: records its args (minus the asc-api.mjs path asc_client
# prepends), then prints CLIENT_BUILD.  Never touches the network.
cat > "${tmp}/fake-client" <<FAKE
#!/usr/bin/env bash
shift
printf '%s' "\$*" > "\${CLIENT_ARGS_FILE:?}"
if [[ "\${CLIENT_RC:-0}" -eq 0 ]]; then
  printf '%s' "\${CLIENT_BUILD:-$FAKE_BUILD}"
fi
exit "\${CLIENT_RC:-0}"
FAKE
chmod +x "${tmp}/fake-client"

extract() {
  awk '
    /^json_get\(\) \{/ || /^asc_credential_source_present\(\) \{/ || /^asc_client\(\) \{/ || /^asc_next_shared_build\(\) \{/ || /^asc_platform_max_build\(\) \{/ || /^build_exceeds\(\) \{/ { grab = 1 }
    grab { print }
    grab && /^\}/ { grab = 0 }
  ' "$script"
}

funcs="${tmp}/funcs.sh"
{
  echo 'logerr() { echo "[ios-ship] $*" >&2; }'
  echo "APPS_JSON=\"${tmp}/apps.json\""
  echo "FLEET_DIR=\"${here}\""
  echo "ASC_NODE=\"${tmp}/fake-client\""
  extract
} > "$funcs"
grep -q '^asc_next_shared_build()' "$funcs" || fail "asc_next_shared_build not found in ship-testflight.sh"
grep -q '^asc_platform_max_build()' "$funcs" || fail "asc_platform_max_build not found in ship-testflight.sh"
grep -q '^build_exceeds()' "$funcs" || fail "build_exceeds not found in ship-testflight.sh"
grep -q '^json_get()' "$funcs" || fail "json_get not found in ship-testflight.sh"
grep -q '^asc_client()' "$funcs" || fail "asc_client not found in ship-testflight.sh"

cat > "${tmp}/run.sh" <<RUN
set -u
source "${funcs}"
if [[ "\${HELPER_MODE:-shared}" == "max" ]]; then
  asc_platform_max_build
else
  asc_next_shared_build
fi
RUN

export CURL_ARGS_FILE="${tmp}/curl-args"
export CLIENT_ARGS_FILE="${tmp}/client-args"
export PATH="${tmp}:/usr/bin:/bin"

# run_helper <app_key> <bundle_id> [extra env...]: stdout on stdout, stderr
# and the exit code in $tmp/stderr and $tmp/rc.
run_helper() {
  local app="$1" bundle="$2"
  shift 2
  : > "$CURL_ARGS_FILE"
  : > "$CLIENT_ARGS_FILE"
  set +e
  env -u FLEET_SECRETS "APP_KEY=$app" "BUNDLE_ID=$bundle" "$@" \
    /usr/bin/bash "${tmp}/run.sh" >"${tmp}/stdout" 2>"${tmp}/stderr"
  printf '%s' "$?" >"${tmp}/rc"
  set -e
}
rc() { cat "${tmp}/rc"; }
stdout() { cat "${tmp}/stdout"; }
stderr() { cat "${tmp}/stderr"; }
curl_args() { cat "$CURL_ARGS_FILE"; }
client_args() { cat "$CLIENT_ARGS_FILE"; }

CRED="ASC_KEY_ID=test-id"

# 1. The feed fetch is bounded: the exact curl invocation carries the
# https-only protos, both timeouts, the size cap and the feed URL.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(curl_args)" == "-fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 30 --max-filesize 5000000 ${FEED_URL}" ]] \
  || fail "curl argv was not bounded: $(curl_args)"
ok

# 2. A curl failure fails closed with the feed URL and curl's stderr.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=fail
[[ "$(rc)" -eq 1 ]] || fail "curl failure should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a failed feed fetch must print no build"
stderr | grep -q -F "$FEED_URL" || fail "feed failure did not name the URL: $(stderr)"
stderr | grep -q -F "curl: (28)" || fail "feed failure hid curl's stderr: $(stderr)"
ok

# 3. An empty feed body fails closed with the URL and the no-versions
# message in the stderr message.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=empty
[[ "$(rc)" -eq 1 ]] || fail "empty feed should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "an empty feed must print no build"
stderr | grep -q -F "$FEED_URL" || fail "empty feed did not name the URL: $(stderr)"
stderr | grep -q -F "no numeric" || fail "empty feed did not say no versions: $(stderr)"
stderr | grep -q -F "<sparkle:version>" || fail "empty feed did not name the tag: $(stderr)"
ok

# 4. An appcast with no numeric <sparkle:version> fails closed and says so.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=noversion
[[ "$(rc)" -eq 1 ]] || fail "version-less feed should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a version-less feed must print no build"
stderr | grep -q -F "$FEED_URL" || fail "version-less feed did not name the URL: $(stderr)"
stderr | grep -q -F "no numeric" || fail "version-less feed did not say so: $(stderr)"
stderr | grep -q -F "<sparkle:version>" || fail "version-less feed did not name the tag: $(stderr)"
ok

# 5. A missing curl fails closed with the URL in the message.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=ok PATH=/nonexistent
[[ "$(rc)" -eq 1 ]] || fail "missing curl should return 1, got $(rc)"
stderr | grep -q -F "$FEED_URL" || fail "missing curl did not name the URL: $(stderr)"
export PATH="${tmp}:/usr/bin:/bin"
ok

# 6. pairedBundleId is preferred over macBundleId, the feed max joins as the
# floor, and the merge stamp of HEAD joins as the trailing flag.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(stdout)" == "$FAKE_BUILD" ]] || fail "expected the client build on stdout, got: $(stdout)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 1400 --merge-stamp ${STAMP}" ]] \
  || fail "paired passthrough wrong: $(client_args)"
ok

# 7. macBundleId stays accepted as the alias.
run_helper ios-alias com.example.ios "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 1400 --merge-stamp ${STAMP}" ]] \
  || fail "macBundleId alias not passed through: $(client_args)"
ok

# 8. A macOS entry names its iOS app as the paired id.
run_helper mac-paired com.example.mac "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.mac com.example.ios --merge-stamp ${STAMP}" ]] \
  || fail "mac entry passthrough wrong: $(client_args)"
[[ ! -s "$CURL_ARGS_FILE" ]] || fail "no feed configured, but curl ran: $(curl_args)"
ok

# 9. No paired id and no feed: the client gets the bundle and the stamp.
run_helper solo com.example.solo "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.solo --merge-stamp ${STAMP}" ]] \
  || fail "solo passthrough wrong: $(client_args)"
ok

# 10. A failing client fails closed and prints nothing.
run_helper ios-alias com.example.ios "$CRED" CURL_MODE=ok CLIENT_RC=2
[[ "$(rc)" -eq 1 ]] || fail "client failure should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a failed client must print no build"
ok

# 11. A malformed client answer fails closed, including the retired
# four-digit counter form.
run_helper ios-alias com.example.ios "$CRED" CURL_MODE=ok CLIENT_BUILD=xyz
[[ "$(rc)" -eq 1 ]] || fail "malformed client output should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a malformed client answer must print no build"
run_helper ios-alias com.example.ios "$CRED" CURL_MODE=ok CLIENT_BUILD=1501
[[ "$(rc)" -eq 1 ]] || fail "a four-digit client answer should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a four-digit client answer must print no build"
run_helper ios-alias com.example.ios "$CRED" CURL_MODE=ok CLIENT_BUILD=02610290531
[[ "$(rc)" -eq 1 ]] || fail "a zero-leading client answer should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a zero-leading client answer must print no build"
ok

# 12. No credential source fails closed without running curl or the client.
run_helper solo com.example.solo PATH=/nonexistent HOME="${tmp}/emptyhome" \
  ASC_KEY_ID= APPLE_API_KEY_ID= FLEET_SECRETS_BIN=/nonexistent-test-dir/fleet-secrets
[[ "$(rc)" -eq 1 ]] || fail "missing credentials should return 1, got $(rc)"
stderr | grep -q -F "no ASC_*" || fail "missing credentials said nothing: $(stderr)"
[[ ! -s "$CURL_ARGS_FILE" ]] || fail "curl ran without credentials"
[[ ! -s "$CLIENT_ARGS_FILE" ]] || fail "client ran without credentials"
export PATH="${tmp}:/usr/bin:/bin"
ok

# 13. Whitespace-padded <sparkle:version> values still count.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=padded
[[ "$(rc)" -eq 0 ]] || fail "padded feed should return 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 1400 --merge-stamp ${STAMP}" ]] \
  || fail "padded versions misread: $(client_args)"
ok

# 14. A non-https feed is rejected before curl runs.
run_helper ios-http com.example.ios "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 1 ]] || fail "http feed should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a rejected feed must print no build"
stderr | grep -q -F "$HTTP_FEED_URL" || fail "http feed did not name the URL: $(stderr)"
stderr | grep -q -F "not https" || fail "http feed did not say why: $(stderr)"
[[ ! -s "$CURL_ARGS_FILE" ]] || fail "curl ran for a non-https feed: $(curl_args)"
[[ ! -s "$CLIENT_ARGS_FILE" ]] || fail "client ran for a non-https feed"
ok

# 15. A feed max of 9999 joins the plan: the 1..9998 cap is gone.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=big
[[ "$(rc)" -eq 0 ]] || fail "9999 floor should return 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 9999 --merge-stamp ${STAMP}" ]] \
  || fail "9999 floor misread: $(client_args)"
ok

# 16. A feed max of 10000 joins the plan the same way.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=huge
[[ "$(rc)" -eq 0 ]] || fail "10000 floor should return 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 10000 --merge-stamp ${STAMP}" ]] \
  || fail "10000 floor misread: $(client_args)"
ok

# 17. A feed max below 1 fails closed with the URL in the message.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=zero
[[ "$(rc)" -eq 1 ]] || fail "zero floor should return 1, got $(rc)"
stderr | grep -q -F "$FEED_URL" || fail "zero floor did not name the URL: $(stderr)"
stderr | grep -q -F "not a positive integer" || fail "zero floor did not say why: $(stderr)"
ok

# 18. The boundary floors 1 and 9998 are accepted; the max joins.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=edge
[[ "$(rc)" -eq 0 ]] || fail "edge feed should return 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 9998 --merge-stamp ${STAMP}" ]] \
  || fail "edge floor misread: $(client_args)"
ok

# 19. A macOS entry with no paired id reverse-resolves its peer, so the
# peer's iOS builds join the plan.
run_helper mac-orphan com.example.mac2 "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.mac2 com.example.ios2 --merge-stamp ${STAMP}" ]] \
  || fail "mac reverse lookup wrong: $(client_args)"
[[ ! -s "$CURL_ARGS_FILE" ]] || fail "no feed configured, but curl ran: $(curl_args)"
ok

# 20. The -mac key suffix counts as a macOS entry for the reverse lookup.
run_helper lonely-mac com.example.mac4 "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.mac4 com.example.ios4 --merge-stamp ${STAMP}" ]] \
  || fail "suffix reverse lookup wrong: $(client_args)"
[[ ! -s "$CURL_ARGS_FILE" ]] || fail "no feed configured, but curl ran: $(curl_args)"
ok

# 21. An iOS entry with no paired id stays solo even when a macOS entry
# names it: the reverse lookup is for macOS ships only.
run_helper ios-orphan com.example.ios3 "$CRED" CURL_MODE=ok
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios3 --merge-stamp ${STAMP}" ]] \
  || fail "ios entry should stay solo: $(client_args)"
ok

# 22. The feed max is computed with POSIX tools, not a hardcoded interpreter.
grep -q 'sort -n' "$funcs" || fail "feed max lost its POSIX sort"
max_line="$(grep -F 'sparkle:version>' "$funcs" | grep -F 'grep -o' | head -n 1 || true)"
[[ -n "$max_line" ]] || fail "feed scrape line not found in extracted helper"
case "$max_line" in
  *python*) fail "feed max still calls python: $max_line" ;;
esac
case "$max_line" in
  *'[[:space:]]'*) ok ;;
  *) fail "feed scrape is not whitespace-tolerant: $max_line" ;;
esac

# 23. An 18-digit feed max joins the plan; a 19-digit one fails closed.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=huge18
[[ "$(rc)" -eq 0 ]] || fail "18-digit floor should return 0, got $(rc): $(stderr)"
[[ "$(client_args)" == "plan-release-build com.example.ios com.example.mac 123456789012345678 --merge-stamp ${STAMP}" ]] \
  || fail "18-digit floor misread: $(client_args)"
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=giant
[[ "$(rc)" -eq 1 ]] || fail "19-digit floor should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "an over-long floor must print no build"
stderr | grep -q -F "$FEED_URL" || fail "19-digit floor did not name the URL: $(stderr)"
stderr | grep -q -F "not a positive integer" || fail "19-digit floor did not say why: $(stderr)"
[[ ! -s "$CLIENT_ARGS_FILE" ]] || fail "client ran with an over-long floor"
ok

# 24. An unreadable merge stamp fails closed before the client runs.
run_helper solo com.example.solo "$CRED" CURL_MODE=ok REPO_ROOT="${tmp}/no-such-dir"
[[ "$(rc)" -eq 1 ]] || fail "unreadable stamp should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "an unreadable stamp must print no build"
stderr | grep -q -F "merge stamp" || fail "unreadable stamp did not say why: $(stderr)"
[[ ! -s "$CLIENT_ARGS_FILE" ]] || fail "client ran without a merge stamp"
ok

# 25. The platform max asks for this app record on this platform only: no
# paired id, no feed fetch, even when both are configured.
run_helper ios-paired com.example.ios "$CRED" CURL_MODE=ok HELPER_MODE=max CLIENT_BUILD=202610190645
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(stdout)" == "202610190645" ]] || fail "expected the client max on stdout, got: $(stdout)"
[[ "$(client_args)" == "max-platform-build com.example.ios IOS" ]] \
  || fail "platform max passthrough wrong: $(client_args)"
[[ ! -s "$CURL_ARGS_FILE" ]] || fail "feed fetched for a platform max: $(curl_args)"
run_helper mac-orphan com.example.mac2 "$CRED" CURL_MODE=ok HELPER_MODE=max ASC_PLATFORM=MAC_OS CLIENT_BUILD=0
[[ "$(rc)" -eq 0 ]] || fail "expected rc 0, got $(rc): $(stderr)"
[[ "$(stdout)" == "0" ]] || fail "expected 0 for an empty platform, got: $(stdout)"
[[ "$(client_args)" == "max-platform-build com.example.mac2 MAC_OS" ]] \
  || fail "mac platform max passthrough wrong: $(client_args)"
ok

# 26. A failing or malformed platform max fails closed and prints nothing.
run_helper solo com.example.solo "$CRED" CURL_MODE=ok HELPER_MODE=max CLIENT_RC=2
[[ "$(rc)" -eq 1 ]] || fail "max client failure should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a failed max must print no build"
run_helper solo com.example.solo "$CRED" CURL_MODE=ok HELPER_MODE=max CLIENT_BUILD=xyz
[[ "$(rc)" -eq 1 ]] || fail "malformed max should return 1, got $(rc)"
[[ -s "${tmp}/stdout" ]] && fail "a malformed max must print no build"
run_helper solo com.example.solo PATH=/nonexistent HOME="${tmp}/emptyhome" \
  ASC_KEY_ID= APPLE_API_KEY_ID= FLEET_SECRETS_BIN=/nonexistent-test-dir/fleet-secrets \
  HELPER_MODE=max
[[ "$(rc)" -eq 1 ]] || fail "max without credentials should return 1, got $(rc)"
[[ ! -s "$CLIENT_ARGS_FILE" ]] || fail "client ran without credentials"
export PATH="${tmp}:/usr/bin:/bin"
ok

# 27. build_exceeds compares integers of any length: a requested build equal
# to the paired platform's existing build is accepted (the check only sees
# this platform's max), while at-or-below this platform's max is rejected.
# shellcheck disable=SC1090
source "$funcs"
build_exceeds 202610290532 202610290531 || fail "greater 12-digit build rejected"
build_exceeds 202610290531 202610290531 && fail "equal build accepted"
build_exceeds 202610290530 202610290531 && fail "lesser build accepted"
build_exceeds 202610290531 0 || fail "build above an empty platform rejected"
build_exceeds 202610290531 202610190645 || fail "paired platform's build rejected against a lower platform max"
build_exceeds 1000000000000 999999999999 || fail "length-greater build rejected"
build_exceeds 999999999999 1000000000000 && fail "length-lesser build accepted"
build_exceeds 1234567890123456789 123456789012345678 || fail "over-long comparison misread"
ok

echo "PASS: ${pass} plan-release-build ship-helper checks"
