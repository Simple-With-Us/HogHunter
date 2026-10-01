#!/usr/bin/env bash
# Manual hosted-runner release only.  No credentials are printed or uploaded as artifacts.
set +o xtrace
set -euo pipefail
umask 077

[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch && "${GITHUB_REF:-}" == refs/heads/main ]] || {
  echo 'error: run the guarded manual workflow on main; local release is disabled' >&2
  exit 1
}
: "${ASC_KEY_ID:?ASC_KEY_ID required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID required}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH required}"
: "${HH_BUILD_NUMBER:?HH_BUILD_NUMBER required}"
: "${RUNNER_TEMP:?RUNNER_TEMP required}"
[[ "$HH_BUILD_NUMBER" =~ ^[1-9][0-9]{0,17}$ ]] || { echo 'error: invalid build number' >&2; exit 1; }
[[ "${HH_TESTFLIGHT_UPLOAD:-false}" == true || "${HH_TESTFLIGHT_UPLOAD:-false}" == false ]] || {
  echo 'error: upload must be true or false' >&2
  exit 1
}
[[ -s "$ASC_KEY_PATH" ]] || { echo 'error: ASC key file missing' >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
work_dir="$(mktemp -d "$RUNNER_TEMP/hoghunter-release.XXXXXX")"
staged_asc_key=""
cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$staged_asc_key" && -f "$staged_asc_key" ]]; then
    rm -f "$staged_asc_key"
  fi
}
trap cleanup EXIT
archive="$work_dir/HogHunterIOS.xcarchive"
auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

validate_app() {
  local app_path="$1"
  local distribution="${2:-false}"
  [[ -f "$app_path/embedded.mobileprovision" ]] || { echo 'error: provisioning profile missing' >&2; return 1; }
  codesign --verify --deep --strict "$app_path"
  security cms -D -i "$app_path/embedded.mobileprovision" > "$work_dir/profile.plist"
  codesign -d --entitlements :- "$app_path" > "$work_dir/entitlements.plist" 2>/dev/null
  local validator=(python3 scripts/validate-ios-release.py --info "$app_path/Info.plist" \
    --profile "$work_dir/profile.plist" --entitlements "$work_dir/entitlements.plist" \
    --build-number "$HH_BUILD_NUMBER")
  if [[ "$distribution" == true ]]; then validator+=(--distribution); fi
  "${validator[@]}"
}

xcodegen generate
xcodebuild -project HogHunter.xcodeproj -scheme HogHunterIOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$work_dir/DerivedData" \
  -archivePath "$archive" -allowProvisioningUpdates "${auth[@]}" \
  DEVELOPMENT_TEAM=CC8UTF7ATG CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$HH_BUILD_NUMBER" archive -quiet
validate_app "$archive/Products/Applications/HogHunter.app"

python3 - "$work_dir/ExportOptions.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'method': 'app-store-connect', 'destination': 'export',
        'signingStyle': 'automatic', 'teamID': 'CC8UTF7ATG',
        'manageAppVersionAndBuildNumber': False,
    }, output)
PY
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work_dir/export" \
  -exportOptionsPlist "$work_dir/ExportOptions.plist" -allowProvisioningUpdates "${auth[@]}" -quiet

shopt -s nullglob
ipas=("$work_dir/export/"*.ipa)
[[ "${#ipas[@]}" == 1 ]] || { echo 'error: expected exactly one exported IPA' >&2; exit 1; }
unzip -q "${ipas[0]}" -d "$work_dir/ipa"
apps=("$work_dir/ipa/Payload/"*.app)
[[ "${#apps[@]}" == 1 ]] || { echo 'error: expected exactly one exported app' >&2; exit 1; }
validate_app "${apps[0]}" true

if [[ "${HH_TESTFLIGHT_UPLOAD:-false}" == true ]]; then
  asc_keys_dir="${HOME}/.appstoreconnect/private_keys"
  mkdir -p "$asc_keys_dir"
  chmod 700 "$asc_keys_dir"
  staged_asc_key="${asc_keys_dir}/AuthKey_${ASC_KEY_ID}.p8"
  cp "$ASC_KEY_PATH" "$staged_asc_key"
  chmod 600 "$staged_asc_key"
  export API_PRIVATE_KEYS_DIR="$asc_keys_dir"

  set +e
  xcrun altool --upload-app -f "${ipas[0]}" --type ios --output-format json \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" > "$work_dir/upload-result.json" 2>&1
  altool_rc=$?
  set -e

  cat "$work_dir/upload-result.json"
  if [[ $altool_rc -ne 0 ]]; then
    echo "error: altool upload failed with exit code $altool_rc" >&2
    exit $altool_rc
  fi

  python3 - "$work_dir/upload-result.json" <<'PYUPLOAD'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as response:
        result = json.load(response)
    if not isinstance(result, dict) or result.get('product-errors') or not result.get('success-message'):
        raise ValueError('altool did not report an unambiguous success')
except (OSError, ValueError) as error:
    raise SystemExit(f'error: App Store Connect upload not confirmed: {error}')
PYUPLOAD
  result='Upload command succeeded.  Confirm Apple processing, the build identity, and beta review separately before sharing an install link.'
else
  result='Archive and export validated.  Upload was disabled for this manual run.'
fi
printf '%s\n' "$result"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '## Hog Hunter iOS\n\n'
    printf 'App Store Connect app: 6816633156  \nBundle: com.simplewithus.hoghunter.ios  \nVersion: 1.0.4  \nBuild: %s\n\n' "$HH_BUILD_NUMBER"
    printf '%s\n' "$result"
  } >> "$GITHUB_STEP_SUMMARY"
fi
