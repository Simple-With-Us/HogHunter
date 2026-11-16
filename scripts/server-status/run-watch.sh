#!/bin/sh
# One writer covers the existing watch, its histories, and the supplemental metrics.
# The base watch publishes to a staging file only;  the supplement is the sole
# writer of the canonical snapshot, so readers never see a base-only file.
set -eu
state=/root/.vps-storage-watch
mkdir -p "$state"
exec 9>"$state/collector.lock"
flock -n 9 || exit 0
VPS_STORAGE_SNAPSHOT="$state/base.json" /root/vps-storage-watch.sh
exec /usr/bin/python3 -S /root/vps-status-supplement.py \
  --snapshot /root/vps-storage-status.json --base "$state/base.json" --home /root --history "$state"
