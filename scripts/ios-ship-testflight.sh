#!/usr/bin/env bash
# Thin wrapper: ship the Hog Hunter iPhone companion to TestFlight through the
# fleet script (scripts/ios-fleet/ship-testflight.sh), the same path the other
# fleet apps use.  The fleet script owns the version (1.0.<commit_count>) and the
# build number (<commit_count>), the rate gate and same-HEAD skip,
# ensure-tf-ready, and the What to Test notes.
#
# Release lane only:  .github/workflows/ios-testflight.yml runs this on a
# GitHub-hosted macOS runner.  A local upload is refused, as the old release
# script refused it.  --dry-run and --help stay available anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET="${ROOT}/scripts/ios-fleet/ship-testflight.sh"
[[ -f "$FLEET" ]] || { echo "error: ${FLEET} not found" >&2; exit 1; }

local_ok=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-h|--help) local_ok=1 ;;
  esac
done
if [[ "${GITHUB_ACTIONS:-}" != true && "$local_ok" -ne 1 ]]; then
  echo 'error: ship through .github/workflows/ios-testflight.yml; a local upload is disabled (use --dry-run to see the plan)' >&2
  exit 1
fi

exec bash "$FLEET" hoghunter --repo-root "$ROOT" "$@"
