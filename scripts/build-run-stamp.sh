#!/bin/bash
# One timestamp at invocation, including rebuilds. Never derive from Git or a counter.
set -euo pipefail
if ! stamp="$(TZ=America/Chicago date +%Y%m%d%H%M)"; then
  echo 'error: could not read the build start time in America/Chicago.' >&2
  exit 1
fi
[[ "$stamp" =~ ^[1-9][0-9]{11}$ ]] || {
  echo 'error: build start timestamp must be YYYYMMDDHHMM in America/Chicago.' >&2
  exit 1
}
printf '%s\n' "$stamp"
