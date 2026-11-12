# Root's files, shared over the tailnet

**2026-10-28 · seat MM · board: not filed (see "Not done here")**

## What the owner asked for

> add file sharing to the server under the jay account if it can see all the
> files of root but under root account if it can't see all those or be made
> able to see them all

The conditional resolves in `jay`'s favour, and the reason was measured rather
than assumed.

## What jay could see before

`jay` is uid 1001 and sits in `adm`, `sudo`, `docker`, `systemd-journal` and
`fleet`, and it has passwordless sudo on the server.

`/root` was `drwxr-x--x root:root`, so `jay` could walk into it but not list
it.  Of the 118 top-level entries under `/root`, **38 were unreadable** by
`jay`:  the SSH and GnuPG directories, the Coolify admin credential and API
token files, the R2 archive credential files, the weekly secrets export, the
Samba password file and several agent state directories.

So `jay` could not see all of root's files, and the owner asked for it to be
made able to.

## Why the share runs as jay and not as root

Running the share as `root` would have been the blunt answer, and it is the
wrong one here.  Two measurements decided it.

**An ACL grant breaks OpenSSH.**  Adding a named-user ACL to a private key
raises the mode OpenSSH reports, and OpenSSH then refuses the key:

    Permissions 0640 for 'keytest' are too open.

`/root/.ssh` holds the three `coolify_deploy_*` keys that Coolify uses to
push deployments, the `fleet_hetzner_to_mac_ed25519` key that the server uses
to reach the Mac, and `/root/.gnupg` holds the GnuPG private keys.  A blanket
grant over `/root` would have raised every one of them to 0640 and broken all
of them.

**A share as root puts those keys on the network.**  Even with the grant
fixed, serving `/root` as `root` means the share can reach the key
material.  As `jay`, the share can only reach what `jay` can reach, and `jay`
already has passwordless sudo, so the grant costs no new local capability.

## What was installed

- A second share, `root-files` → `/root`, read only, `valid users = jay`,
  `force user = jay`, `force group = fleet`.
- `hide dot files = no` on that share.  The Samba default is `yes`, which
  would have hidden exactly the content worth seeing.
- `wide links = no` on that share, so an absolute symlink inside `/root`
  cannot walk out of it.  `/root/.codex/tmp/arg0-linux/codex-linux-sandbox`
  points into `/home/jay/.codex`, and the socket paths point at
  `/root/.ssh/agent` and `/tmp/codex-daemon-0`.
- A POSIX ACL grant:  `jay` gets read and traverse on `/root` and on everything
  in it except the excluded names.
- The existing `fleet-extra` share, the tailnet-only firewall rules and the
  `smbd` dependency on the firewall unit are unchanged.

The share is still tailnet-only:  port 445 is accepted on `tailscale0` and
dropped everywhere else, for IPv4 and IPv6.

## Two details that cost a pass

**`setfacl --no-messages` does not exist on that host.**  The `acl` package
there is 2.3.2 and only knows the short `-n`, so the first apply died on its
first call with a usage message.  The script now uses `-n`.

**`setfacl --mask` is required, and the grant is useless without it.**  By
default setfacl keeps the file's old group bits as the ACL mask.  On a 0600
file those bits are `---`, so the mask stayed `---` and the new `user:jay:r--`
entry was reported as `#effective:---`:  the ACL was in place and jay still
could not read the file.  With `--mask` the mask is recalculated as the union
of the group class and the named entries, so the grant takes effect.  This
does not widen the group class:  the effective group permission is the group
entry intersected with the mask, and the mask always contains the group entry.

Recalculating the mask also raises the mode a granted file is reported as, from
0600 to 0640.  That is why the key directories are pruned from the grant
entirely rather than granted and then protected some other way:  a key that
OpenSSH refuses is worse than a key that is not on the share.

## The excluded names

The script keeps a named list out of both the ACL grant and the share, and
`veto files` carries the same list.  The two halves are pruned at every depth,
not only at the top level, so a key directory nested inside another directory is
pruned as well.  The script also takes the grant back off the excluded names,
because the first version of it granted them and a grant is a mode change as
well as an access change:  removing the entry restores the file's own mode, and
the host is left where a fresh install would have left it.

The key directories are in the list for the OpenSSH reason above.  The
credential files are in the list because they must not travel over the network:
the Coolify admin credential and API token, the R2 archive credential file, the
weekly secrets export, the Samba password file, the `secrets` directory, the
monitoring bot's Zulip credential, the rclone configuration output, and the
pre-migration copies of the shell profile and the agent configuration that
still carry a secret.

**Excluding a file from the share costs the owner nothing locally.**  The
share authenticates as `jay`, and `jay` holds passwordless sudo, so `jay` can
read every one of those files on the host with or without the grant.  What
the exclusion changes is that the file does not travel over the wire to
anybody who holds the SMB password.

**The list is named, not derived.**  It is a bounded set of file names in the
script, not a secret scanner, so a credential that appears later under a new
name is not covered by it.  The agent state directories are deliberately not
excluded, because seeing them is the point of the share, and they carry token
material of their own.  Three of the excluded files are world-readable on the
host already, so the host itself should tighten them.  Anyone who can
authenticate to this share can read root's working files, so the SMB password
should be treated as a root credential and rotated whenever the tailnet
membership changes.

## Taking the grant back off

The script takes its own earlier grant back off the excluded names with
`setfacl -R -x u:jay`, and it does so without `-n`.  Both of those
details were measured on the host rather than assumed.

**The revoke recalculates the mask on purpose.**  A file that was
granted and then has its entry removed keeps the mask it had:  with `-n` the
mask stays `r--` and the file is still reported as 0640, which is the mode
OpenSSH refuses.  Recalculating the mask restores the file's own mode
with the entry, so a granted private key comes back to 0600.

**The revoke covers the key directories too.**  They are never
granted, but the first version of the script granted them, and the revoke is
what repairs that.  A file that was never granted is untouched by the
revoke:  its mode stays what it was and no mask entry is left behind.

## What the review changed

Two review bots read the first version of the script and both found real
defects.  The changes below are in the same commit as the share.

**A repeated `--exclude` overwrote the list.**  The flag is documented as
repeatable, but each occurrence replaced the whole list, so
`--exclude .ssh --exclude .gnupg` left `.gnupg` alone and dropped `.ssh` from
both the grant and the veto list.  The exclusions are held in an array now:
the first `--exclude` replaces the default list and every later one appends to
it.  A name is also rejected when it carries whitespace or a glob character,
because the list used to be expanded unquoted.

**The exclusion only looked at the top level.**  The grant descended into
every directory that was not excluded by name, so a nested key directory would
have been granted, and a file that vanished during the walk made `setfacl`
fail the whole run under `set -e`.  The grant now walks a target list that
prunes the excluded names at every depth and leaves symbolic links alone, and
it works in batches so that one ungrantable path cannot abort the run.

**The live configuration was rewritten in place.**  The new file was
installed straight over `/etc/samba/smb.conf`, so an interrupted run could
leave a truncated configuration behind.  The file is now written beside the
live one and renamed into place, for the install and for the restore.

**An unmatched begin marker took the rest of the file with it.**  The block
stripper was a two-state toggle, so a half-written block made it discard every
remaining line of the configuration, and `testparm` still passed on what was
left.  Only a block that is closed by its end marker is removed now, and an
unmatched marker stops the run instead.

**The plan and the grant were two copies of the same decision.**  The
exclusion logic was written once for the plan and once for the apply, and only
the plan was covered by a test.  One target list drives both now, so the
printed plan and the applied grant cannot drift.

**The credential exposure.**  The first version served root's credential files
over the network, and the review was right to call it.  See the section above
for what was excluded and why.

## The tracked script

`scripts/smb-root-files-share.sh` is the source of truth for the share.  It
refuses to write anything without both `--apply` and `--confirm`, and every
other mode only prints:  the plan, the share block, the configuration file as
it would be after the change, or the list of paths the grant would touch.

It owns a marked block in `/etc/samba/smb.conf`:

    # BEGIN hoghunter root-files share
    [root-files]
       ...
    # END hoghunter root-files share

and replaces that block rather than appending a second copy, so the run is
idempotent and the rest of the file is untouched.  It backs the configuration
up before it changes it, validates the result with `testparm` before it
installs it, and restores the backup if the installed file does not pass
`testparm`.

Deploy it with `sudo install -o root -g root -m 0755
scripts/smb-root-files-share.sh /usr/local/bin/smb-root-files-share.sh`, and
never edit the deployed copy in place.

Tests: `scripts/test-smb-root-files-share.py`, 40 cases, covering the rendered
block, the plan, the refusal paths, the repeated-exclusion behaviour, the
nested pruning, the unmatched marker, the atomic install and the revoke.  CI runs
`bash -n` over the script and the test suite on every pull request.

## Not done here

- **The board item was not filed.**  Writing to Linear needs a bearer that
  this seat does not have, so there is no `HH-` number on this change.  The
  blocker is the seat's own missing bearer, not the work.
- **The firewall script is still untracked.**  The file
  `/usr/local/bin/smb-tailnet-firewall.sh` and the `smbd` unit override live
  only on the host.  The share this change adds does not touch them, and
  bringing them under the same tracking is its own piece of work.
