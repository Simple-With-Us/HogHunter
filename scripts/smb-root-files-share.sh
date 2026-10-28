#!/usr/bin/env bash
#
# Provision the `root-files` Samba share on the fleet server.
#
# The share exposes root's home directory over the tailnet so the owner can browse
# it from the Mac.  It runs under the `jay` account, not `root`:  jay already has
# passwordless sudo on this host, so a read grant costs no new local capability, and
# running the share as root would put SSH and GPG private keys on the network.
#
# The private-key directories are excluded twice over.  The ACL pass prunes them
# at every depth, and the share vetoes their names, so neither a mistaken grant nor
# a symlink reaches them.
#
# Nothing is written unless BOTH --apply and --confirm are given.  Every other mode
# only prints, so the script is safe to run to inspect the plan.
#
# Usage:
#   smb-root-files-share.sh                     # print the plan (no changes)
#   smb-root-files-share.sh --print-config      # print just the share block
#   smb-root-files-share.sh --print-targets     # print every path the grant touches
#   smb-root-files-share.sh --apply --confirm   # apply the change (needs root)
#
set -euo pipefail

PROGRAM_NAME="$(basename "$0")"

DEFAULT_SOURCE="/root"
DEFAULT_SHARE="root-files"
DEFAULT_USER="jay"
DEFAULT_GROUP="fleet"
DEFAULT_SMB_CONF="/etc/samba/smb.conf"
# The names kept out of the grant and out of the share.  The key directories
# are here because a grant on a private key raises the mode OpenSSH reports and
# OpenSSH then refuses the key.  The credential files are here because they must
# not travel over the network:  the share authenticates as jay, and jay has
# passwordless sudo on this host, so excluding a file from the share costs the
# owner nothing locally while keeping live credentials off the wire.
DEFAULT_EXCLUDES="
.ssh
.gnupg
.fleet-extra-smb.pass
.secrets
.zuliprc-bf-monitor
.coolify-admin-password
.coolify-api-token
.coolify-api-token-stats
.congress-sqlite-web-password
.ct-r2-weekly-archive.env
.ct-secrets-export.env
.rclone_config_create.out
.bashrc.before-fleet-secrets
.profile.before-fleet-secrets
.claude.json.before-fleet-secrets
.claude.json.bak-secretsdir
.claude.json.backup-fleettools-20261028T021259Z
.claude.json.before-fleetlink-20261016081245
.st-restart.sh.superseded
"

SOURCE="$DEFAULT_SOURCE"
SHARE="$DEFAULT_SHARE"
SMB_USER="$DEFAULT_USER"
SMB_GROUP="$DEFAULT_GROUP"
SMB_CONF="$DEFAULT_SMB_CONF"

# The excluded names live in an array, so a name is never split on whitespace and
# never glob-expanded.  The first --exclude replaces the default list and every
# later one appends to it, so a second flag can never silently drop the first.
EXCLUDE_ARRAY=()
EXCLUDES_REPLACED=0
PRUNE_EXPRESSION=""

MODE="plan"
CONFIRMED=0
RESULT_CONF=""

usage() {
  cat <<USAGE
Usage: ${PROGRAM_NAME} [options]

  --print-config      print the share block that would be installed
  --print-targets     print every path the ACL grant would touch
  --print-resulting-conf PATH
                      print the configuration file as it would be after the change
  --apply             ask for the change to be made
  --confirm           confirm it; without this flag --apply refuses
  --source DIR        the directory to share (default ${DEFAULT_SOURCE})
  --share NAME        the Samba share name (default ${DEFAULT_SHARE})
  --user NAME         the account the share runs as (default ${DEFAULT_USER})
  --group NAME        the group the share runs as (default ${DEFAULT_GROUP})
  --smb-conf PATH     the Samba configuration file (default ${DEFAULT_SMB_CONF})
  --exclude NAME      a name to keep out of the grant and the share; repeatable,
                      the first one replaces the default list and later ones
                      append to it
  -h, --help          this text

Without --apply nothing is changed.  With --apply but without --confirm the
script refuses and changes nothing.
USAGE
}

# The excluded names are held in an array so that a name is never re-split, and
# the first --exclude replaces the default list while every later one appends.
add_exclude() {
  if [ "$EXCLUDES_REPLACED" -eq 0 ]; then
    EXCLUDE_ARRAY=("$1")
    EXCLUDES_REPLACED=1
  else
    EXCLUDE_ARRAY+=("$1")
  fi
}

for default_exclude in $DEFAULT_EXCLUDES; do
  add_exclude "$default_exclude"
done
EXCLUDES_REPLACED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-config) MODE="config" ;;
    --print-targets) MODE="targets" ;;
    --print-resulting-conf) MODE="result"; RESULT_CONF="${2:?--print-resulting-conf needs a value}"; shift ;;
    --apply) MODE="apply" ;;
    --confirm) CONFIRMED=1 ;;
    --source) SOURCE="${2:?--source needs a value}"; shift ;;
    --share) SHARE="${2:?--share needs a value}"; shift ;;
    --user) SMB_USER="${2:?--user needs a value}"; shift ;;
    --group) SMB_GROUP="${2:?--group needs a value}"; shift ;;
    --smb-conf) SMB_CONF="${2:?--smb-conf needs a value}"; shift ;;
    --exclude) add_exclude "${2:?--exclude needs a value}"; shift ;;
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

# An excluded name is matched against a single path segment, so it cannot escape
# the shared directory either.  It also reaches a find expression, so it must
# carry no whitespace and no glob character.
for excluded in "${EXCLUDE_ARRAY[@]}"; do
  case "$excluded" in
    ""|.|..) echo "${PROGRAM_NAME}: an excluded name must be one plain path segment" >&2; exit 2 ;;
    */*) echo "${PROGRAM_NAME}: an excluded name must be one plain path segment" >&2; exit 2 ;;
    -*) echo "${PROGRAM_NAME}: an excluded name must not start with a dash" >&2; exit 2 ;;
    *[[:space:]]*) echo "${PROGRAM_NAME}: an excluded name must not contain whitespace" >&2; exit 2 ;;
    *[\*\?\[\]]*) echo "${PROGRAM_NAME}: an excluded name must not contain a glob character" >&2; exit 2 ;;
  esac
done

# The find expression that prunes the excluded names at every depth.  It is
# built from names that were validated above, so it carries no quoting hazard.
first=1
for excluded in "${EXCLUDE_ARRAY[@]}"; do
  if [ "$first" -eq 1 ]; then
    PRUNE_EXPRESSION="-name ${excluded}"
    first=0
  else
    PRUNE_EXPRESSION="${PRUNE_EXPRESSION} -o -name ${excluded}"
  fi
done

is_excluded() {
  local name="$1"
  local excluded
  for excluded in "${EXCLUDE_ARRAY[@]}"; do
    if [ "$name" = "$excluded" ]; then
      return 0
    fi
  done
  return 1
}

# The share block.  This is the single source of truth:  --print-config prints it,
# --apply installs exactly this text between the marker comments.
render_share_block() {
  local veto=""
  local excluded
  # Samba separates the entries of "veto files" with a slash and matches each
  # entry against a name, never a path, so the list reads /.ssh/.gnupg/.
  for excluded in "${EXCLUDE_ARRAY[@]}"; do
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

# Every path the grant touches, NUL separated.  This is the single source of truth
# for the exclusion decisions:  the plan prints it, the apply path grants exactly
# it, and neither can drift from the other.  The excluded names are pruned at
# every depth, not only at the top level, and symbolic links are left alone so a
# link cannot carry the grant out of the tree.
acl_targets() {
  local entry
  local name
  for entry in "${SOURCE}"/* "${SOURCE}"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ -L "$entry" ] && continue
    name="$(basename "$entry")"
    if is_excluded "$name"; then
      continue
    fi
    if [ -n "$PRUNE_EXPRESSION" ]; then
      find "$entry" \( $PRUNE_EXPRESSION \) -prune -o \( -type f -o -type d \) -print0
    else
      find "$entry" \( -type f -o -type d \) -print0
    fi
  done
}

# Grant one batch of paths.  setfacl fails the whole batch when a path vanishes
# between the scan and the grant, so a failed batch is retried one path at a time
# and only a path that is genuinely gone is ignored.
grant_batch() {
  if setfacl -n --mask -m "u:${SMB_USER}:rX" -- "$@" 2>/dev/null; then
    return 0
  fi
  local path
  local real_failure=0
  for path in "$@"; do
    if ! setfacl -n --mask -m "u:${SMB_USER}:rX" -- "$path" 2>/dev/null; then
      if [ -e "$path" ]; then
        echo "${PROGRAM_NAME}: could not grant on ${path}" >&2
        real_failure=1
      fi
    fi
  done
  return "$real_failure"
}

# Take the grant back off the excluded names.   An earlier run of this script
# granted them, and a grant is a mode change as well as an access change, so
# removing the entry restores the file's own mode with it.
revoke_excluded_grant() {
  local excluded
  local path
  local failed=0
  for excluded in "${EXCLUDE_ARRAY[@]}"; do
    path="${SOURCE}/${excluded}"
    [ -e "$path" ] || continue
    if ! setfacl -R -x "u:${SMB_USER}" "$path" 2>/dev/null; then
      echo "${PROGRAM_NAME}: could not take the grant back off ${path}" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

# The grant itself.  It walks the target list in batches so that one
# ungrantable path cannot abort the whole run.
apply_acl_grant() {
  local -a batch=()
  local path
  local failed=0
  local granted=0
  while IFS= read -r -d '' path; do
    batch+=("$path")
    granted=$((granted + 1))
    if [ "${#batch[@]}" -ge 500 ]; then
      grant_batch "${batch[@]}" || failed=1
      batch=()
    fi
  done < <(acl_targets)
  if [ "${#batch[@]}" -gt 0 ]; then
    grant_batch "${batch[@]}" || failed=1
  fi
  setfacl -n --mask -m "u:${SMB_USER}:rx" "$SOURCE"
  revoke_excluded_grant
  echo "granted:   ${granted} paths"
  [ "$failed" -eq 0 ]
}

# Remove a previous copy of the managed block, leaving every other line alone.
# Only a block that is closed by its end marker is removed, so an unmatched
# begin marker cannot swallow the rest of the configuration.
strip_share_block() {
  local rc=0
  local stripped
  stripped="$(mktemp "${TMPDIR:-/tmp}/smb-strip.XXXXXX")"
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { skip = 1; opened = 1; next }
    $0 == end   { if (skip) { skip = 0; closed = 1 }; next }
    !skip       { print }
    END         { if (opened && !closed) exit 3 }
  ' "$1" > "$stripped" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$stripped"
    if [ "$rc" -eq 3 ]; then
      echo "${PROGRAM_NAME}: ${1} has an unmatched begin marker for the ${SHARE} share." >&2
      echo "${PROGRAM_NAME}: fix the file by hand; nothing was changed." >&2
    fi
    return "$rc"
  fi
  cat "$stripped"
  rm -f "$stripped"
}

render_plan() {
  local excluded
  local entry
  local name
  echo "source:      ${SOURCE}"
  echo "share:      ${SHARE}"
  echo "account:    ${SMB_USER}:${SMB_GROUP}"
  local joined=""
  for excluded in "${EXCLUDE_ARRAY[@]}"; do
    joined="${joined}${excluded} "
  done
  echo "excluded:   ${joined}"
  echo "config:     ${SMB_CONF}"
  echo
  echo "steps:"
  echo "  1. grant ${SMB_USER} read and traverse on the tree, pruning the excluded names at every depth"
  echo "  2. take the grant back off the excluded names, restoring their own mode"
  echo "  3. install the share block between the marker comments in ${SMB_CONF}"
  echo "  4. validate with testparm, then restart smbd"
  echo
  echo "commands:"
  echo "setfacl -n --mask -m u:${SMB_USER}:rx ${SOURCE}"
  for entry in "${SOURCE}"/* "${SOURCE}"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ -L "$entry" ] && continue
    name="$(basename "$entry")"
    if is_excluded "$name"; then
      echo "skipped:    ${entry}"
      continue
    fi
    echo "find ${entry} \\( ${PRUNE_EXPRESSION} \\) -prune -o \\( -type f -o -type d \\) -print0 | setfacl -n --mask -m u:${SMB_USER}:rX"
  done
}

if [ "$MODE" = "config" ]; then
  render_share_block
  exit 0
fi

if [ "$MODE" = "targets" ]; then
  acl_targets | tr '\0' '\n'
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

for required in setfacl getfacl testparm pdbedit systemctl find; do
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

SMB_DIR="$(dirname "$SMB_CONF")"
ORIGINAL_MODE="$(stat -c '%a' "$SMB_CONF")"
ORIGINAL_OWNER="$(stat -c '%u:%g' "$SMB_CONF")"

BACKUP="${SMB_CONF}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$SMB_CONF" "${BACKUP}.tmp"
mv -f "${BACKUP}.tmp" "$BACKUP"
echo "backup:  ${BACKUP}"

# The grant, over the paths the target list names.
apply_acl_grant

# The share block, replacing any previous copy of itself and leaving the rest of
# the file untouched.  The new file is written beside the live one and renamed
# into place, so an interrupted run cannot leave a truncated configuration
# behind.
TMP_CONF="$(mktemp "${SMB_DIR}/.smb-root-files-share.XXXXXX")"
trap 'rm -f "$TMP_CONF"' EXIT
strip_share_block "$SMB_CONF" > "$TMP_CONF"
render_share_block >> "$TMP_CONF"

if ! testparm -s "$TMP_CONF" >/dev/null 2>&1; then
  echo "${PROGRAM_NAME}: the new configuration does not pass testparm; nothing was installed." >&2
  exit 4
fi

chmod "$ORIGINAL_MODE" "$TMP_CONF"
chown "$ORIGINAL_OWNER" "$TMP_CONF"
mv -f "$TMP_CONF" "$SMB_CONF"

if ! testparm -s "$SMB_CONF" >/dev/null 2>&1; then
  echo "${PROGRAM_NAME}: the installed configuration does not pass testparm; restoring ${BACKUP}." >&2
  RESTORE_CONF="$(mktemp "${SMB_DIR}/.smb-root-files-share.XXXXXX")"
  cp -a "$BACKUP" "$RESTORE_CONF"
  mv -f "$RESTORE_CONF" "$SMB_CONF"
  exit 4
fi

systemctl restart smbd

echo "installed: ${SMB_CONF} (share ${SHARE} -> ${SOURCE})"
echo "restarted: smbd"
