#!/bin/sh
# One writer covers the existing watch, its histories, and the supplemental metrics.
set -eu
state=/root/.vps-storage-watch
mkdir -p "$state"
exec 9>"$state/collector.lock"
# Exit 1 from `flock -n` means the lock is held, so another collector is already
# doing this work and a clean no-op is correct.  Every other status (127 when
# `flock` is missing, or a real lock error) means the collector did not run, so
# report it instead of exiting successfully and letting cron report a healthy run.
lock_status=0
flock -n 9 || lock_status=$?
case "$lock_status" in
  0) ;;
  1) exit 0 ;;
  *) echo "run-watch: flock failed with status $lock_status" >&2; exit "$lock_status" ;;
esac
/root/vps-storage-watch.sh
exec /usr/bin/python3 -S /root/vps-status-supplement.py \
  --snapshot /root/vps-storage-status.json --home /root --history "$state"
