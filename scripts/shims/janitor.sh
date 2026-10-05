#!/bin/bash
# Thin shim — forwards to Hog Hunter Robotic Vacuum janitor cadence.
set -euo pipefail
REPO="${HOGHUNTER_REPO:-$HOME/Code/HogHunter}"
exec python3 "${REPO}/scripts/robotic-vacuum.py" --run-now janitor
