#!/bin/bash
# Restore com.jay.* launchd cleanup jobs and remove Robotic Vacuum agent.
set -euo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  echo "Usage: $0 <migration-backup-dir>" >&2
  exit 2
fi

HOME_DIR="${HOME}"
DOMAIN="gui/$(id -u)"
LABEL="com.simplewithus.hoghunter.robotic-vacuum"

if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
fi
rm -f "${HOME_DIR}/Library/LaunchAgents/${LABEL}.plist"

for plist in "${BACKUP_DIR}"/*.plist; do
  [[ -f "${plist}" ]] || continue
  base="$(basename "${plist}")"
  [[ "${base}" == "${LABEL}.plist" ]] && continue
  if [[ "${base}" == *.system.plist ]]; then
    label="${base%.system.plist}"
    echo "System-scope backup ${base} is in ${BACKUP_DIR}; restore with:"
    echo "  sudo cp -a \"${plist}\" \"/Library/LaunchAgents/${label}.plist\""
    echo "  sudo launchctl bootstrap system \"/Library/LaunchAgents/${label}.plist\""
    continue
  fi
  if [[ "${base}" == *.user.plist ]]; then
    label="${base%.user.plist}"
    dest="${HOME_DIR}/Library/LaunchAgents/${label}.plist"
  else
    dest="${HOME_DIR}/Library/LaunchAgents/${base}"
  fi
  cp -a "${plist}" "${dest}"
  launchctl bootstrap "${DOMAIN}" "${dest}" 2>/dev/null || launchctl load "${dest}"
  echo "Restored $(basename "${dest}")"
done

echo "Rollback complete."
