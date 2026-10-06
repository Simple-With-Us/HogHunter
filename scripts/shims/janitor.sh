#!/bin/bash
# Thin shim - forwards to Hog Hunter Robotic Vacuum janitor cadence.
set -euo pipefail
# shellcheck source=_resolve-repo.sh
source "$(cd "$(dirname "$0")" && pwd)/_resolve-repo.sh"
REPO="$(resolve_hoghunter_repo)" || {
  echo "set HOGHUNTER_REPO to the Hog Hunter clone" >&2
  exit 2
}
exec python3 "${REPO}/scripts/robotic-vacuum.py" --run-now janitor
