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
it.   Of the 118 top-level entries under `/root`, **38 were unreadable** by
`jay`: the SSH and GnuPG directories, the Coolify admin credential and API
token files, the R2 archive credential files, the weekly secrets export, the
Samba password file and several agent state directories.

So `jay` could not see all of root's files, and the owner asked for it to be
made able to.

## Why the share runs as jay and not as root

Running the share as `root` would have been the blunt answer, and it is the
wrong one here.   Two measurements decided it.

**An ACL grant breaks OpenSSH.**   Adding a named-user ACL to a private key
raises the mode OpenSSH reports, and OpenSSH then refuses the key:

    Permissions 0640 for 'keytest' are too open.

`/root/.ssh` holds the three `coolify_deploy_*` keys that Coolify uses to
push deployments, the `fleet_hetzner_to_mac_ed25519` key that the server uses
to reach the Mac, and `/root/.gnupg` holds the GnuPG private keys.   A blanket
grant over `/root` would have raised every one of them to 0640 and broken all
of them.

**A share as root puts those keys on the network.**   Even with the grant
fixed, serving `/root` as `root` means the share can reach the key
material.   As `jay`, the share can only reach what `jay` can reach, and `jay`
already has passwordless sudo, so the grant costs no new local capability.

## What was installed

- A second share, `root-files` → `/root`, read only, `valid users = jay`,
  `force user = jay`, `force group = fleet`.
- `hide dot files = no` on that share.   The Samba default is `yes`, which
  would have hidden exactly the content worth seeing.
- `wide links = no` on that share, so an absolute symlink inside `/root`
  cannot walk out of it.   `/root/.codex/tmp/arg0-linux/codex-linux-sandbox`
  points into `/home/jay/.codex`, and the socket paths point at
  `/root/.ssh/agent` and `/tmp/codex-daemon-0`.
- `veto files = /.ssh/.gnupg/`, so the key directories are not served even if
  a grant slips.   Samba separates the entries with a slash and matches each
  entry against a name, never a path.
- A POSIX ACL grant: `jay` gets read and traverse on `/root` and on everything
  in it except `.ssh` and `.gnupg`.
- The existing `fleet-extra` share, the tailnet-only firewall rules and the
  `smbd` dependency on the firewall unit are unchanged.

The share is still tailnet-only:   port 445 is accepted on `tailscale0` and
dropped everywhere else, for IPv4 and IPv6.

## Two details that cost a pass

**`setfacl --no-messages` does not exist on that host.**   The `acl` package
there is 2.3.2 and only knows the short `-n`, so the first apply died on its
first call with a usage message.   The script now uses `-n`.

**`setfacl --mask` is required, and the grant is useless without it.**   By
default setfacl keeps the file's old group bits as the ACL mask.   On a 0600
file those bits are `---`, so the mask stayed `---` and the new `user:jay:r--`
entry was reported as `#effective:---`:   the ACL was in place and jay still
could not read the file.   With `--mask` the mask is recalculated as the union
of the group class and the named entries, so the grant takes effect.   This
does not widen the group class:   the effective group permission is the group
entry intersected with the mask, and the mask always contains the group entry.

Recalculating the mask also raises the mode a granted file is reported as, from
0600 to 0640.   That is why the key directories are pruned from the grant
entirely rather than granted and then protected some other way:   a key that
OpenSSH refuses is worse than a key that is not on the share.

## The tracked script

`scripts/smb-root-files-share.sh` is the source of truth for the share.   It
refuses to write anything without both `--apply` and `--confirm`, and every
other mode only prints:   the plan, the share block, or the configuration file
as it would be after the change.

It owns a marked block in `/etc/samba/smb.conf`:

    # BEGIN hoghunter root-files share
    [root-files]
       ...
    # END hoghunter root-files share

and replaces that block rather than appending a second copy, so the run is
idempotent and the rest of the file is untouched.   It backs the configuration
up before it changes it, validates the result with `testparm` before it
installs it, and restores the backup if the installed file does not pass
`testparm`.

Deploy it with `sudo install -o root -g root -m 0755
scripts/smb-root-files-share.sh /usr/local/bin/smb-root-files-share.sh`, and
never edit the deployed copy in place.

Tests: `scripts/test-smb-root-files-share.py`, which checks the rendered
block, the plan, the refusals and the idempotence of the managed block.   CI
runs `bash -n` over the script and the test suite on every pull request.

## Not done here

- **The board item was not filed.**   Writing to Linear needs a bearer that
  this seat does not have, so there is no `HH-` number on this change.   The
  blocker is the seat's own missing bearer, not the work.
- **The firewall script is still untracked.**   The file
  `/usr/local/bin/smb-tailnet-firewall.sh` and the `smbd` unit override live
  only on the host.   The share this change adds does not touch them, and
  bringing them under the same tracking is its own piece of work.
