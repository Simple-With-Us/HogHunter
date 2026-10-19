#!/usr/bin/env bash
# AFC-359: ship-testflight.sh resolves App Store Connect credentials from the environment
# first, then from Infisical through fleet-secrets, and never from the old secrets folder.
# This test extracts fs_get/load_secrets/cleanup_asc_tmp from the script and runs them
# against a FAKE fleet-secrets binary under a throwaway HOME.  No network, no real secrets.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/ship-testflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="${tmp}/home"
export TMPDIR="${tmp}/tmp"
mkdir -p "$HOME" "$TMPDIR"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake fleet-secrets: prints synthetic values, records the folders it was asked for.
cat > "${tmp}/fleet-secrets" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == get ]] || exit 2
name="$2"; folder="$4"
echo "${name} ${folder}" >> "${FAKE_LOG}"
case "${folder}:${name}" in
  /asc:ASC_KEY_ID) printf 'ABCDE12345\n' ;;
  /asc:ASC_ISSUER_ID) printf 'issuer-synthetic\n' ;;
  /asc:ASC_KEY_P8) printf -- '-----BEGIN PRIVATE KEY-----\nSYNTHETIC\n-----END PRIVATE KEY-----\n' ;;
  /authkey-otherkey01-p8:AUTHKEY_OTHERKEY01) printf -- '-----BEGIN PRIVATE KEY-----\nOTHERKEYMATERIAL\n-----END PRIVATE KEY-----\n' ;;
  *) exit 3 ;;
esac
FAKE
chmod +x "${tmp}/fleet-secrets"
export FAKE_LOG="${tmp}/fake.log"
: > "$FAKE_LOG"

extract() {
  awk '
    /^fs_get\(\) \{/ || /^load_secrets\(\) \{/ || /^cleanup_asc_tmp\(\) \{/ || /^expand_tilde\(\) \{/ { grab = 1 }
    grab { print }
    grab && /^\}/ { grab = 0 }
  ' "$script"
}
funcs="${tmp}/funcs.sh"
{
  echo 'log() { :; }'
  echo 'ASC_TMP_DIR=""'
  echo "FLEET_SECRETS_BIN=\"${tmp}/fleet-secrets\""
  extract
} > "$funcs"
grep -q '^load_secrets()' "$funcs" || fail "load_secrets not found in ship-testflight.sh"
grep -q '^fs_get()' "$funcs" || fail "fs_get not found in ship-testflight.sh"

# 1. Nothing in the environment:  credentials come from Infisical, the key is a 0600 temp file.
out="$(env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key ]]
  [[ "$ASC_KEY_ID" == ABCDE12345 && "$ASC_ISSUER_ID" == issuer-synthetic ]]
  [[ -f "$ASC_KEY_PATH" ]]
  mode="$(stat -c %a "$ASC_KEY_PATH" 2>/dev/null || stat -f %Lp "$ASC_KEY_PATH")"
  [[ "$mode" == 600 ]]
  [[ "$API_PRIVATE_KEYS_DIR" == "$ASC_TMP_DIR" ]]
  grep -q SYNTHETIC "$ASC_KEY_PATH"
  echo "$ASC_KEY_PATH"
  cleanup_asc_tmp
  [[ ! -e "$ASC_KEY_PATH" ]]
')" || fail "load_secrets from Infisical"
[[ ! -e "$out" ]] || fail "temp key file survived cleanup"
grep -q '^ASC_KEY_ID /asc$' "$FAKE_LOG" || fail "did not ask Infisical /asc for the key id"
grep -q '^ASC_KEY_P8 /asc$' "$FAKE_LOG" || fail "did not ask Infisical /asc for the key"

# 2. An explicit ASC_* environment wins and fleet-secrets is not called.
: > "$FAKE_LOG"
printf 'synthetic' > "${tmp}/env-key.p8"
env ASC_KEY_ID=ENVKEY0001 ASC_ISSUER_ID=env-issuer ASC_KEY_PATH="${tmp}/env-key.p8" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ENVKEY0001 && -z "$ASC_TMP_DIR" ]]
' || fail "environment credentials were not honored"
[[ ! -s "$FAKE_LOG" ]] || fail "fleet-secrets was called although the environment was complete"

# 2b. An env key id that is NOT the /asc one never gets the /asc key:  its own .p8 comes from
# /authkey-<id>-p8, and /asc ASC_KEY_P8 is not requested.
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_ISSUER_ID ASC_KEY_ID=OTHERKEY01 bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == OTHERKEY01 ]]
  grep -q OTHERKEYMATERIAL "$ASC_KEY_PATH"
  ! grep -q SYNTHETIC$ "$ASC_KEY_PATH"
  cleanup_asc_tmp
' || fail "env key id different from /asc was not given its own key"
grep -q '^AUTHKEY_OTHERKEY01 /authkey-otherkey01-p8$' "$FAKE_LOG" || fail "did not ask the per-key folder"
if grep -q '^ASC_KEY_P8 ' "$FAKE_LOG"; then fail "mixed an env key id with the /asc key"; fi

# 2c. An env key id equal to the /asc one uses the /asc key.
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_ISSUER_ID ASC_KEY_ID=ABCDE12345 bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ABCDE12345 ]]
  grep -q SYNTHETIC "$ASC_KEY_PATH"
  cleanup_asc_tmp
' || fail "env key id equal to /asc was not served from /asc"
grep -q '^ASC_KEY_P8 /asc$' "$FAKE_LOG" || fail "did not ask /asc ASC_KEY_P8"

# 2d. An env key id with no key material anywhere fails closed (no api_key mode).
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_ISSUER_ID ASC_KEY_ID=NOSUCHKEY0 bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == none && -z "$ASC_TMP_DIR" ]]
' || fail "missing key material did not fail closed"

# 2e. Only a leading "~/" is expanded:  "~user/x" must not be merged with $HOME.
env ASC_KEY_ID=TILDE00001 ASC_ISSUER_ID=tilde-issuer bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  [[ "$(expand_tilde "~/k.p8")" == "$HOME/k.p8" ]]
  [[ "$(expand_tilde "~other/k.p8")" == "~other/k.p8" ]]
  [[ "$(expand_tilde "/abs/k.p8")" == "/abs/k.p8" ]]
' || fail "expand_tilde"

# 3. Nothing is created under the old secrets folder or ~/.appstoreconnect.
[[ ! -e "${HOME}/.secrets" ]] || fail "created the old secrets folder"
[[ ! -e "${HOME}/.appstoreconnect" ]] || fail "created ~/.appstoreconnect"

# 4. The script text itself no longer names the old folder as a source.
if grep -nE '(~|\$\{?HOME\}?)/\.secrets' "$script" >/dev/null; then
  fail "ship-testflight.sh still names the old secrets folder"
fi

echo "ok: ASC credential resolution (env first, then Infisical, temp key removed)"
