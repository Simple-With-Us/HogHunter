#!/usr/bin/env bash
# Cursor cloud agent install script for HogHunter.
#
# Runs during the Cursor cloud Build phase.  Persisted on the install disk,
# so re-runs must be idempotent and fast (no secret export here — that
# belongs in cursor-cloud-start.sh, which runs every agent boot).
#
# Targets: Ubuntu Linux only.  HogHunter is a Swift macOS menu bar app with
# an iOS companion (ios/Sources, scheme HogHunterIOS) — both require Xcode
# and are Mac-only.  The Linux install is therefore minimal: it prepares
# tooling that an agent can use to read, lint, and reason about the repo
# (XcodeGen project generation, docs / scripts) without attempting a build.
#
# Required Cursor dashboard secrets (org-wide):
#   - INFISICAL_CLIENT_ID
#   - INFISICAL_CLIENT_SECRET

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Cursor cloud install: HogHunter"
echo "==> Host: $(uname -srm 2>/dev/null || echo unknown)"

if [ "$(uname -s)" != "Linux" ]; then
  echo "==> ERROR: this script is Linux-only (got $(uname -s))." >&2
  exit 1
fi

# ── Node + npm (for the iOS Bonjour / Node-tooled docs helpers if any) ─
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "==> Installing Node.js + npm via NodeSource (Ubuntu)."
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
    apt-get install -y nodejs >/dev/null
  else
    echo "==> ERROR: apt-get not found; cannot install Node.js." >&2
    exit 1
  fi
fi

echo "==> Node: $(node --version)  npm: $(npm --version)"

# ── Infisical CLI (official Linux install) ────────────────
if ! command -v infisical >/dev/null 2>&1; then
  echo "==> Installing Infisical CLI."
  curl -fsSL https://infisical.com/install.sh | bash -s -- >/dev/null
fi

if ! command -v infisical >/dev/null 2>&1; then
  echo "==> WARN: infisical CLI not available; start script will fall back to API fetch." >&2
else
  echo "==> Infisical CLI: $(infisical --version 2>/dev/null || echo installed)"
fi

# ── xcodegen (project.yml is the project source of truth) ─
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> Installing xcodegen (Swift project generator)."
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen >/dev/null
  else
    echo "==> WARN: brew not available; skipping xcodegen install (Mac-only build tooling)." >&2
  fi
fi

if command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen: $(xcodegen --version 2>/dev/null || echo installed)"
fi

# ── Repo-level optional npm deps (only when a lockfile ships) ─
if [ -f "$REPO_ROOT/package.json" ] && [ -f "$REPO_ROOT/package-lock.json" ]; then
  echo "==> Installing repo root npm dependencies (npm ci --include=dev)."
  npm ci --include=dev --prefix "$REPO_ROOT"
elif [ -f "$REPO_ROOT/package.json" ]; then
  echo "==> Installing repo root npm dependencies (npm install --include=dev, no lockfile)."
  npm install --include=dev --prefix "$REPO_ROOT"
else
  echo "==> No root package.json — skipping npm install."
fi

# ── Skipped on Linux (HogHunter is a Mac / Xcode project) ─
cat <<'SKIP'

==> Skipping native builds on Linux:
    - macOS app HogHunter (scheme HogHunter, xcodebuild, code signing) — Xcode required
    - iOS companion HogHunterIOS (scheme HogHunterIOS, xcodebuild) — Xcode required
    - xcodegen generate is available but the produced .xcodeproj is not
      committed; a Linux agent can lint project.yml and run scripts, not
      build the .app or .ipa.

SKIP

echo "==> Cursor cloud install: complete."
