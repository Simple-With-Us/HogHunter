#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/staging"
export ASC_STAGING_ROOT="$tmp_dir/staging"
export GITHUB_ENV="$tmp_dir/github-env"
: > "$GITHUB_ENV"

cat > "$tmp_dir/fixture" <<'KEY'
SYNTHETIC-HEADER
SYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE
SYNTHETIC-FOOTER
KEY

bash "$repo_root/scripts/ios-stage-asc-key.sh" < "$tmp_dir/fixture" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"
key_path="$(sed -n 's/^ASC_KEY_PATH=//p' "$GITHUB_ENV")"
[[ -f "$key_path" ]]
file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}
[[ "$(file_mode "$key_path")" == 600 ]]
[[ "$(file_mode "$(dirname "$key_path")")" == 700 ]]
cmp "$tmp_dir/fixture" "$key_path"
[[ "$(cat "$GITHUB_ENV")" == "ASC_KEY_PATH=$key_path" ]]
[[ ! -s "$tmp_dir/stdout" && ! -s "$tmp_dir/stderr" ]]
if grep -Fq 'SYNTHETIC-MULTILINE-FIXTURE' "$GITHUB_ENV" "$tmp_dir/stdout" "$tmp_dir/stderr"; then
  echo 'key material reached environment or log output' >&2
  exit 1
fi

# Guard the workflow handoff itself, not only the staging script.
workflow="$repo_root/.github/workflows/ios-testflight.yml"
if grep -Eq 'for name in .*ASC_KEY_P8' "$workflow"; then
  echo 'workflow still propagates the multiline key through an environment mask' >&2
  exit 1
fi
if ! grep -Fq 'scripts/ios-stage-asc-key.sh' "$workflow"; then
  echo 'workflow does not use the protected key-file handoff' >&2
  exit 1
fi

# A second handoff cannot overwrite the first key, including through aliases.
bash "$repo_root/scripts/ios-stage-asc-key.sh" < "$tmp_dir/fixture" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"
second_path="$(tail -n 1 "$GITHUB_ENV" | sed 's/^ASC_KEY_PATH=//')"
[[ "$key_path" != "$second_path" ]]
cmp "$tmp_dir/fixture" "$key_path"
cmp "$tmp_dir/fixture" "$second_path"

# Empty input must not publish a path or leave a partial key directory.
cp "$GITHUB_ENV" "$tmp_dir/before-empty-env"
if bash "$repo_root/scripts/ios-stage-asc-key.sh" < /dev/null > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"; then
  echo 'empty key input was accepted' >&2
  exit 1
fi
cmp "$GITHUB_ENV" "$tmp_dir/before-empty-env"
[[ "$(find "$ASC_STAGING_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 2 ]]

# Exercise the actual workflow run block using a fake Infisical CLI.
# No Apple or Infisical credentials are used by this test.
python3 - "$workflow" "$tmp_dir/workflow-load.sh" <<'PYTHON'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
section = text.split('      - name: Load ASC credentials (Fleet-OPS prod /asc)\n', 1)[1]
section = section.split('\n      - name:', 1)[0]
run = section.split('        run: |\n', 1)[1]
pathlib.Path(sys.argv[2]).write_text('\n'.join(line[10:] for line in run.splitlines() if line.startswith('          ')) + '\n')
PYTHON
mkdir "$tmp_dir/bin" "$tmp_dir/workspace" "$tmp_dir/workspace/scripts"
ln -s "$repo_root/scripts/ios-stage-asc-key.sh" "$tmp_dir/workspace/scripts/ios-stage-asc-key.sh"
cat > "$tmp_dir/bin/infisical" <<'CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ASC_TEST_CALLS"
case "${1:-}" in
  login) printf '%s\n' synthetic-session-token ;;
  secrets)
    if [[ "${ASC_TEST_MISSING:-}" == "${3:-}" ]]; then
      exit 1
    elif [[ "${3:-}" == ASC_KEY_P8 ]]; then
      cat "$ASC_TEST_FIXTURE"
    elif [[ "${3:-}" == ASC_KEY_ID && "${ASC_TEST_MULTILINE_ID:-}" == 1 ]]; then
      printf '%s\n' SYNTHETIC-ID-FIRST SYNTHETIC-ID-CONTINUATION
    else
      printf 'synthetic-%s\n' "${3:-value}"
    fi
    ;;
  *) exit 1 ;;
esac
CLI
chmod 700 "$tmp_dir/bin/infisical"

run_load() {
  # run_load <env file> <calls file> [extra env assignments...]
  local envfile="$1" calls="$2"; shift 2
  : > "$envfile"
  : > "$calls"
  env -u ASC_KEY_P8 PATH="$tmp_dir/bin:$PATH" \
    GITHUB_WORKSPACE="$tmp_dir/workspace" GITHUB_ENV="$envfile" \
    ASC_INFISICAL_PROJECT_ID=synthetic-fleet-ops \
    INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=synthetic-client \
    INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=synthetic-secret \
    ASC_TEST_FIXTURE="$tmp_dir/fixture" ASC_TEST_CALLS="$calls" \
    "$@" bash "$tmp_dir/workflow-load.sh"
}

run_load "$tmp_dir/workflow-env" "$tmp_dir/calls" > "$tmp_dir/workflow-stdout" 2> "$tmp_dir/workflow-stderr"
if grep -Fq -f "$tmp_dir/fixture" "$tmp_dir/workflow-env" "$tmp_dir/workflow-stdout" "$tmp_dir/workflow-stderr"; then
  echo 'workflow leaked multiline key material' >&2
  exit 1
fi
[[ "$(grep -c '^ASC_KEY_PATH=' "$tmp_dir/workflow-env")" == 1 ]]
[[ "$(grep -c '^ASC_KEY_ID=synthetic-ASC_KEY_ID$' "$tmp_dir/workflow-env")" == 1 ]]
[[ "$(grep -c '^ASC_ISSUER_ID=synthetic-ASC_ISSUER_ID$' "$tmp_dir/workflow-env")" == 1 ]]
workflow_key="$(sed -n 's/^ASC_KEY_PATH=//p' "$tmp_dir/workflow-env")"
cmp "$tmp_dir/fixture" "$workflow_key"
[[ "$(file_mode "$workflow_key")" == 600 ]]
if [[ -s "$tmp_dir/workflow-stderr" ]]; then
  echo 'workflow step wrote to stderr:' >&2
  sed 's/^/  /' "$tmp_dir/workflow-stderr" >&2
  exit 1
fi
# The three ASC values are read from the Fleet-OPS project at /asc, and nowhere else.
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  grep -Fq "secrets get $name " "$tmp_dir/calls"
done
[[ "$(grep -c '^secrets get ' "$tmp_dir/calls")" == 3 ]]
[[ "$(grep -c -- '--projectId=synthetic-fleet-ops --env=prod --path=/asc' "$tmp_dir/calls")" == 3 ]]
# No certificate credential is loaded or exported by this step.
if grep -q 'IOS_DIST_P12' "$tmp_dir/workflow-env" "$tmp_dir/calls"; then
  echo 'certificate credentials were handled by the ASC step' >&2
  exit 1
fi

# A missing key must fail before any path is published.
if run_load "$tmp_dir/missing-env" "$tmp_dir/missing-calls" ASC_TEST_MISSING=ASC_KEY_P8 \
  > "$tmp_dir/missing-stdout" 2> "$tmp_dir/missing-stderr"; then
  echo 'a missing ASC key was accepted' >&2
  exit 1
fi
grep -q 'Missing ASC key material' "$tmp_dir/missing-stderr"
[[ "$(grep -c '^ASC_KEY_PATH=' "$tmp_dir/missing-env")" == 0 ]]

# A wrapped identifier must fail before add-mask can print continuation lines.
if run_load "$tmp_dir/multiline-env" "$tmp_dir/multiline-calls" ASC_TEST_MULTILINE_ID=1 \
  > "$tmp_dir/multiline-stdout" 2> "$tmp_dir/multiline-stderr"; then
  echo 'multiline ASC identifier was accepted' >&2
  exit 1
fi
if grep -Fq 'SYNTHETIC-ID-' "$tmp_dir/multiline-env" "$tmp_dir/multiline-stdout" "$tmp_dir/multiline-stderr"; then
  echo 'multiline identifier material leaked' >&2
  exit 1
fi
grep -q 'must be single-line' "$tmp_dir/multiline-stderr"

# No machine identity at all must say so rather than fall back to a repository secret.
: > "$tmp_dir/noid-env"
if env -u ASC_KEY_P8 -u INFISICAL_UNIVERSAL_AUTH_CLIENT_ID -u INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET \
  PATH="$tmp_dir/bin:$PATH" GITHUB_WORKSPACE="$tmp_dir/workspace" GITHUB_ENV="$tmp_dir/noid-env" \
  ASC_INFISICAL_PROJECT_ID=synthetic-fleet-ops INFISICAL_UNIVERSAL_AUTH_CLIENT_ID= \
  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET= INFISICAL_CLIENT_ID= INFISICAL_CLIENT_SECRET= \
  ASC_TEST_FIXTURE="$tmp_dir/fixture" ASC_TEST_CALLS="$tmp_dir/noid-calls" \
  bash "$tmp_dir/workflow-load.sh" > "$tmp_dir/noid-stdout" 2> "$tmp_dir/noid-stderr"; then
  echo 'a missing Infisical identity was accepted' >&2
  exit 1
fi
grep -q 'Missing Infisical machine identity' "$tmp_dir/noid-stdout" "$tmp_dir/noid-stderr"

# The ASC key is never read from a repository secret, and the certificate is
# scoped to the import step alone.
if grep -Eq 'secrets\.ASC_(KEY_ID|ISSUER_ID|KEY_P8)' "$workflow"; then
  echo 'workflow reads an ASC repository secret' >&2
  exit 1
fi
python3 - "$workflow" <<'PYTHON'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
steps = re.split(r'\n      - name: ', text)
holders = [s.split('\n', 1)[0] for s in steps if 'secrets.IOS_DIST_P12' in s]
assert holders == ['Import signing identity'], holders
PYTHON

echo 'synthetic ASC key-file and workflow handoff passed'
