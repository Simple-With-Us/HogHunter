#!/bin/bash
# Install Hog Hunter Robotic Vacuum launchd agent and retire com.jay.* cleanup jobs.
# Does NOT run cleaning — only installs scheduling.  Review before running on a Mac.
set -euo pipefail

HOME_DIR="${HOME}"
REPO="${HOGHUNTER_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
LABEL="com.simplewithus.hoghunter.robotic-vacuum"
DOMAIN="gui/$(id -u)"
BACKUP_DIR="${HOME_DIR}/Library/Application Support/HogHunter/RoboticVacuum/migration-backup/$(date +%Y%m%d-%H%M%S)"
OLD_LABELS=(
  com.jay.mac-cleanup
  com.jay.disk-janitor
  com.jay.mac-resource-watch
)

mkdir -p "${BACKUP_DIR}"
mkdir -p "${HOME_DIR}/Library/Logs/HogHunter"

echo "Backing up old launchd jobs to ${BACKUP_DIR}"
for old in "${OLD_LABELS[@]}"; do
  for base in "${HOME_DIR}/Library/LaunchAgents/${old}.plist" "/Library/LaunchAgents/${old}.plist"; do
    if [[ -f "${base}" ]]; then
      cp -a "${base}" "${BACKUP_DIR}/"
    fi
  done
  if launchctl print "${DOMAIN}/${old}" &>/dev/null; then
    launchctl bootout "${DOMAIN}/${old}" 2>/dev/null || true
  fi
done

RENDERED="${BACKUP_DIR}/${LABEL}.plist"
sed -e "s|__HOME__|${HOME_DIR}|g" -e "s|__HOGHUNTER_REPO__|${REPO}|g" \
  "${REPO}/launchd/com.simplewithus.hoghunter.robotic-vacuum.plist" > "${RENDERED}"

DEST="${HOME_DIR}/Library/LaunchAgents/${LABEL}.plist"
cp "${RENDERED}" "${DEST}"
launchctl bootstrap "${DOMAIN}" "${DEST}" 2>/dev/null || launchctl load "${DEST}"

cat > "${BACKUP_DIR}/rollback-instructions.txt" <<EOF
To rollback:
  bash "${REPO}/scripts/robotic-vacuum-rollback.sh" "${BACKUP_DIR}"
EOF

echo "Installed ${LABEL}.  Old plists backed up under ${BACKUP_DIR}"
echo "Thin shims (optional): copy scripts/shims/* to your old script paths if something still calls them."
