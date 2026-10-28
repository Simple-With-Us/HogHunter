#!/usr/bin/env bash
#
# Provision the `root-files` Samba share on the fleet server.
#
# The share exposes root's home directory over the tailnet so the owner can browse
# it from the Mac.  It runs under the `jay` account, not `root`:  jay already has
# passwordless sudo on this host, so a read grant costs no new local capability, and
# running the share as root would put SSH and GPG private keys on the network.
#
# The private-key directories are excluded twice over.  The ACL pass prunes them, and
# the share vetoes their names, so neither a mistaken grant nor a symlink reaches them.
#
# Nothing is written unless BOTH --apply and --confirm are given.  Every other mode
# only prints, so the script is safe to run to inspect the plan.
#
# Usage:
#   smb-root-files-share.sh                     # print the plan (no changes)
#   smb-root-files-share.sh --print-config      # print just the share block
#   smb-root-files-share.sh --apply --confirm   # apply the change (needs root)
#
set -euo pipefail

PROGRAM_NAME="$(basename "$0")"

DEFAULT_SOURCE="/root"
DEFAULT_SHARE="root-files"
DEFAULT_USER="jay"
DEFAULT_GROUP="fleet"
DEFAULT_SMB_CONF="/etc/samba/smb.conf"
DEFAULT_EXCLUDES=".ssh .gnupg"

SOURCE="$DEFAULT_SOURCE"
SHARE="$DEFAULT_SHARE"
SMB_USER="$DEFAULT_USER"
SMB_GROUP="$DEFAULT_GROUP"
SMB_CONF="$DEFAULT_SMB_CONF"
EXCLUDES="$DEFAULT_EXCLUDES"

MODE="plan"
CONFIRMED=0
RESULT_CONF=""

usage() {
  cat <<USAGE
Usage: ${PROGRAM_NAME} [options]

  --print-config      print the share block that would be installed
  --print-resulting-conf PATH
                      print the configuration file as it would be after the change
  --apply             ask for the change to be made
  --confirm           confirm it; without this flag --apply refuses
  --source DIR        the directory to share (default ${DEFAULT_SOURCE})
  --share NAME        the Samba share name (default ${DEFAULT_SHARE})
  --user NAME         the account the share runs as (default ${DEFAULT_USER})
  --group NAME        the group the share runs as (default ${DEFAULT_GROUP})
  --smb-conf PATH     the Samba configuration file (default ${DEFAULT_SMB_CONF})
  --exclude NAME      a top-level name to keep out of the grant and the share;
                      repeatable, replaces the default list
  -h, --help          this text

Without --apply nothing is changed.  With --apply but without --confirm the
script refuses and changes nothing.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-config) MODE="config" ;;
    --print-resulting-conf) MODE="result"; RESULT_CONF="${2:?--print-resulting-conf needs a value}"; shift ;;
    --apply) MODE="apply" ;;
    --confirm) CONFIRMED=1 ;;
    --source) SOURCE="${2:?--source needs a value}"; shift ;;
    --share) SHARE="${2:?--share needs a value}"; shift ;;
    --user) SMB_USER="${2:?--user needs a value}"; shift ;;
    --group) SMB_GROUP="${2:?--group needs a value}"; shift ;;
    --smb-conf) SMB_CONF="${2:?--smb-conf needs a value}"; shift ;;
    --exclude) EXCLUDES="${2:?--exclude needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "${PROGRAM_NAME}: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# The share name is interpolated into the configuration file, so it has to be a
# plain Samba section name and nothing else.
case "$SHARE" in
  ""|*[!A-Za-z0-9_-]*) echo "${PROGRAM_NAME}: the share name must be letters, digits, dash or underscore" >&2; exit 2 ;;
esac

BEGIN_MARK="# BEGIN hoghunter ${SHARE} share"
END_MARK="# END hoghunter ${SHARE} share"

# The excluded names are matched against a single path segment, so they cannot
# escape the shared directory either.
for excluded in $EXCLUDES; do
  case "$excluded" in
    ""|.|..|*/*) echo "${PROGRAM_NAME}: an excluded name must be one plain path segment" >&2; exit 2 ;;
  esac
done

# The share block.  This is the single source of truth:  --print-config prints it,
# --apply installs exactly this text between the marker comments.
render_share_block() {
  local veto
  veto=""
  # Samba separates the entries of "veto files" with a slash and matches each
  # entry against a name, never a path, so the list reads /.ssh/.gnupg/.
  for excluded in $EXCLUDES; do
    veto="${veto}/${excluded}"
  done
  veto="${veto}/"
  cat <<BLOCK
${BEGIN_MARK}
[${SHARE}]
   comment = Root's files (read only, served as ${SMB_USER})
   path = ${SOURCE}
   read only = Yes
   valid users = ${SMB_USER}
   force user = ${SMB_USER}
   force group = ${SMB_GROUP}
   inherit permissions = no
   browseable = Yes
   hide dot files = no
   map hidden = no
   wide links = no
   follow symlinks = yes
   strict symlinks = yes
   veto files = ${veto}
${END_MARK}
BLOCK
}

# The ACL grant.  Each top-level entry of the shared directory is walked on its own,
# so an excluded name is never descended into, and symbolic links are never followed,
# so a link inside the tree cannot carry the grant outside it.
render_acl_commands() {
  local entry name
  echo "setfacl -n --mask -m u:${SMB_USER}:rx ${SOURCE}"
  for entry in "${SOURCE}"/* "${SOURCE}"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ -L "$entry" ] && continue
    name="$(basename "$entry")"
    case " ${EXCLUDES} " in
      *" ${name} "*) continue ;;
    esac
    echo "setfacl -n --mask -R -m u:${SMB_USER}:rX ${entry}"
  done
}

# Remove a previous copy of the managed block, leaving every other line alone.
strip_share_block() {
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$1"
}

render_plan() {
  echo "source:      ${SOURCE}"
  echo "share:      ${SHARE}"
  echo "account:    ${SMB_USER}:${SMB_GROUP}"
  echo "excluded:   ${EXCLUDES}"
  echo "config:     ${SMB_CONF}"
  echo
  echo "steps:"
  echo "  1. grant ${SMB_USER} read and traverse on the tree, skipping the excluded names"
  echo "  2. install the share block between the marker comments in ${SMB_CONF}"
  echo "  3. validate with testparm, then restart smbd"
  echo
  echo "commands:"
  render_acl_commands
  echo "install the rendered share block into ${SMB_CONF}"
  echo "testparm -s ${SMB_CONF}"
  echo "systemctl restart smbd"
}

if [ "$MODE" = "config" ]; then
  render_share_block
  exit 0
fi

if [ "$MODE" = "plan" ]; then
  render_plan
  exit 0
fi

if [ "$MODE" = "result" ]; then
  [ -f "$RESULT_CONF" ] || { echo "${PROGRAM_NAME}: ${RESULT_CONF} does not exist." >&2; exit 3; }
  strip_share_block "$RESULT_CONF"
  render_share_block
  exit 0
fi

# Apply mode from here on.
if [ "$CONFIRMED" -ne 1 ]; then
  echo "${PROGRAM_NAME}: --apply needs --confirm; nothing was changed." >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "${PROGRAM_NAME}: --apply needs root." >&2
  exit 3
fi

for required in setfacl getfacl testparm pdbedit systemctl; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "${PROGRAM_NAME}: ${required} is not installed." >&2
    exit 3
  }
done

[ -d "$SOURCE" ] || { echo "${PROGRAM_NAME}: ${SOURCE} is not a directory." >&2; exit 3; }
[ -f "$SMB_CONF" ] || { echo "${PROGRAM_NAME}: ${SMB_CONF} does not exist." >&2; exit 3; }

pdbedit -L 2>/dev/null | grep -q "^${SMB_USER}:" || {
  echo "${PROGRAM_NAME}: there is no Samba account named ${SMB_USER}; create it first." >&2
  exit 3
}

getent group "$SMB_GROUP" >/dev/null 2>&1 || {
  echo "${PROGRAM_NAME}: there is no group named ${SMB_GROUP}." >&2
  exit 3
}

BACKUP="${SMB_CONF}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$SMB_CONF" "$BACKUP"
echo "backup:  ${BACKUP}"

# The grant, one top-level entry at a time, skipping the excluded names and every
# symbolic link.
for entry in "${SOURCE}"/* "${SOURCE}"/.[!.]*; do
  [ -e "$entry" ] || continue
  [ -L "$entry" ] && continue
  name="$(basename "$entry")"
  case " ${EXCLUDES} " in
    *" ${name} "*) echo "skipped:  ${entry}"; continue ;;
  esac
  setfacl -n --mask -R -m "u:${SMB_USER}:rX" "$entry"
done
setfacl -n --mask -m "u:${SMB_USER}:rx" "$SOURCE"

# The share block, replacing any previous copy of itself and leaving the rest of
# the file untouched.
TMP_CONF="$(mktemp)"
trap 'rm -f "$TMP_CONF"' EXIT
strip_share_block "$SMB_CONF" > "$TMP_CONF"
render_share_block >> "$TMP_CONF"

if ! testparm -s "$TMP_CONF" >/dev/null 2>&1; then
  echo "${PROGRAM_NAME}: the new configuration does not pass testparm; nothing was installed." >&2
  exit 4
fi

install -m 0644 -o root -g root "$TMP_CONF" "$SMB_CONF"

if ! testparm -s "$SMB_CONF" >/dev/null 2>&1; then
  echo "${PROGRAM_NAME}: the installed configuration does not pass testparm; restoring ${BACKUP}." >&2
  install -m 0644 -o root -g root "$BACKUP" "$SMB_CONF"
  exit 4
fi

systemctl restart smbd

echo "installed: ${SMB_CONF} (share ${SHARE} -> ${SOURCE})"
echo "restarted: smbd"
