#!/usr/bin/env bash
# version-number.sh - the one number both ship paths take.
#
# Owner directive 2026-10-26 (HH-191).  A thin shell entry point over
# version-number.mjs, which reads and writes the committed version record in
# project.yml.  Both ship paths call this, so the Mac app and the iPhone app
# of one update carry the same number by construction:
#
#   scripts/install.sh                       the Mac path
#   scripts/ios-fleet/ship-testflight.sh     the iOS path
#
# Usage:
#   version-number.sh record                  -> "<version> <build>"
#   version-number.sh next [--known N] [--write]
#                                           -> "<version> <build>"
#   version-number.sh write <version> [--build B]
#
# The rules that pick the number are pure and live in version-plan.mjs; this
# script only runs the module.  There is no timestamp fallback:  a checkout
# with no readable git history fails loudly.
set -euo pipefail

FLEET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The node that runs the module.  VERSION_NUMBER_NODE overrides it, the way
# IOS_FLEET_NODE overrides the node that runs asc-api.mjs.
NODE_BIN="${VERSION_NUMBER_NODE:-node}"

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "error: node is not on PATH; cannot resolve the version number" >&2
  exit 1
fi

exec "$NODE_BIN" "${FLEET_DIR}/version-number.mjs" "$@"
