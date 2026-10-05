#!/bin/bash
# Thin shim — forwards to Hog Hunter Robotic Vacuum full cadence.
set -euo pipefail
REPO="${HOGHUNTER_REPO:-$HOME/Code/HogHunter}"
PRESSURE=0
for arg in "$@"; do
  case "$arg" in
    --pressure) PRESSURE=1 ;;
  esac
done
if [[ "${MAC_CLEANUP_PRESSURE:-0}" == "1" ]]; then
  PRESSURE=1
fi
if [[ "$PRESSURE" == "1" ]]; then
  exec python3 "${REPO}/scripts/robotic-vacuum.py" --run-now pressure
fi
exec python3 "${REPO}/scripts/robotic-vacuum.py" --run-now full
