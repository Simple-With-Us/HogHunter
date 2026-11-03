#!/usr/bin/env bash
# Cursor cloud agent start script for HogHunter.
#
# Runs every time a Cursor cloud agent boots.  Installed disk state persists,
# but exported shell variables do NOT, so secrets fetched from Infisical are
# written to disk here and re-exported by a tiny .source.sh helper.
#
# Optional Cursor dashboard secret: INFISICAL_HOGHUNTER_READ_TOKEN.
# Must be restricted to HogHunter prod / with read-only permission.
#
# Output:
#   - $HOME/.cursor-cloud-env/HogHunter.env        (mode 0600, KEY=VALUE lines)
#   - $HOME/.cursor-cloud-env/HogHunter.source.sh  (sourced to export the env)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_BASENAME="HogHunter"
ENV_DIR="$HOME/.cursor-cloud-env"
ENV_FILE="$ENV_DIR/${REPO_BASENAME}.env"
SOURCE_FILE="$ENV_DIR/${REPO_BASENAME}.source.sh"
INFISICAL_ENV_FILE="$REPO_ROOT/.cursor/infisical.env"

mkdir -p "$ENV_DIR"
chmod 0700 "$ENV_DIR"
# Never reuse a previous boot's credentials, including when auth is now absent.
rm -f "$ENV_FILE" "$SOURCE_FILE"


# ── Load non-secret Infisical project metadata from the repo ──
if [ -f "$INFISICAL_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$INFISICAL_ENV_FILE"; set +a
fi

PROJECT_ID="${INFISICAL_PROJECT_ID:-}"
INFISICAL_ENV_VALUE="${INFISICAL_ENV:-prod}"
INFISICAL_DOMAIN_VALUE="${INFISICAL_DOMAIN:-https://app.infisical.com}"

# ── Guard: prod only (owner, 2026-10-10) ──
# The dev and staging Infisical environments are retired.  Refuse to export
# anything from another environment, whether the value came from
# .cursor/infisical.env or from the session environment.
if [ "$INFISICAL_ENV_VALUE" != "prod" ]; then
  echo "==> ERROR: INFISICAL_ENV is '$INFISICAL_ENV_VALUE'; only 'prod' is allowed (dev and staging are retired)." >&2
  exit 1
fi

# A missing service token leaves boot usable without any persisted export.
if [ -z "${INFISICAL_HOGHUNTER_READ_TOKEN:-}" ]; then
  echo "==> No INFISICAL_HOGHUNTER_READ_TOKEN; continuing without secret export."
  exit 0
fi
if [ -z "$PROJECT_ID" ]; then
  echo "==> ERROR: INFISICAL_PROJECT_ID is empty; check .cursor/infisical.env." >&2
  exit 1
fi
umask 077
TMP="$(mktemp "$ENV_DIR/.fetch.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
# No CLI or machine-identity fallback. The shared helper checks exact scope.
INFISICAL_SERVICE_TOKEN="$INFISICAL_HOGHUNTER_READ_TOKEN" \
INFISICAL_PROJECT_ID="$PROJECT_ID" \
INFISICAL_ENVIRONMENT="$INFISICAL_ENV_VALUE" \
INFISICAL_SITE_URL="$INFISICAL_DOMAIN_VALUE" \
INFISICAL_SECRET_PATH=/ INFISICAL_SHELL_FILE="$TMP" \
  node "$REPO_ROOT/scripts/infisical-fetch.mjs"

# ── Persist env file (0600) and source helper ──
umask 077
mv "$TMP" "$ENV_FILE"
chmod 0600 "$ENV_FILE"
trap - EXIT

# This path is generated locally; quote it for safe sourcing even in a lane.
printf '#!/usr/bin/env bash\n. %q\n' "$ENV_FILE" > "$SOURCE_FILE"
chmod 0600 "$SOURCE_FILE"

echo "==> Loaded $(grep -c '=' "$ENV_FILE" 2>/dev/null || echo 0) secrets into $ENV_FILE (mode 0600)."
echo "==> Source with: . $SOURCE_FILE"
