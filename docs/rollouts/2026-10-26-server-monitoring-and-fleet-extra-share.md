# Server monitoring, the fleet-extra share, and the panel's two machines

**2026-10-26 · HH-189, HH-190 · seat MM**

## What the owner asked for

One message, several surfaces:

- Why is the server's CPU so much higher than normal?
- The menu bar drop-down needs a toggle at the bottom to read top activity from
  this Mac or from the server.
- The fleet-extra volume should show its free space like the Mac's external
  volumes do.
- The CPU graph is tiny; the Mac and the server should sit side by side.
- The Dashboard's large "Hog Hunter" heading goes: the title bar says it.
- The Dashboard CPU graph gets the width it needs, and a bar-style graph
  belongs in the menu bar item.
- On This Mac's overview the Server block belongs at the very bottom.
- What do the amber dots on the Tools list mean, and why is the server amber?
- The server needs a monitoring tool that can stop processes and control
  Coolify, for the root and jay accounts.
- The server should hand Muster how Coolify is working, and Muster should be
  able to watch the server's config, settings and AGENTS.md files.
- Turn on file sharing on the server over Tailscale.

## The CPU answer

The server was not, in fact, running at 81% all the time.

The number came from `vps-storage-watch.sh`, which takes one `/proc/stat`
tick delta over one second, every fifteen minutes.  Twelve consecutive
samples of the same formula on the host read between 18% and 35%, and
`vmstat` agreed: 68% idle.  A one-second window is short enough to catch a
burst, and long enough to be shaped by whatever ran during it.

The workloads behind the bursts were real, and the server's own collector now
names them:

| Workload | CPU (share of one core) |
|---|---|
| `trading-analytics-fleet / qdrant-st` | 158% |
| `socratic-trade / st-appworker` | 125% |
| `dockerd` + `containerd` | 33% + 32% |

The first two are Coolify applications doing their own work; the last two are
the container runtime.  So the honest reading is "two applications are busy
and the container runtime costs about half a core", not "the server is at 81%".

The reading the panel shows is still the tick delta, and it is still noisy.
What changed is that the server now publishes per-process CPU from the same
collector, so the question "which process?" has an answer.

### A crash loop found on the way

`claude-remote-control.service` had restarted **5,265 times**.  The Claude
Code remote-control client needs a claude.ai login this host does not have,
so every start failed within a second and `Restart=always` started it again
fifteen seconds later: 236 failed starts an hour, each one a node process.

The unit now carries a start limit
(`/etc/systemd/system/claude-remote-control.service.d/override.conf`), so it
stops trying and reports a failed unit instead of churning forever.  It will
work again once someone runs `claude auth login` on the host.

## The collector (`scripts/server-status/supplement.py`)

The deployed copy on the host was from 2026-10-22 and predated the
fleet-extra code, which is why the volume never appeared.  The repository
version is now deployed, and it publishes more:

- **`fleet_extra`** as a device, with its free space, so the panel's Storage
  section can show it beside the Mac's external volumes.
- **`processes`**: the server's busiest processes with their CPU share, their
  memory, their unix account, the Coolify workload they belong to, and their
  **start time**.  The reading comes from `/proc` executable identity and the
  kernel's own tick counters.  Command arguments, environment variables and
  credential files are never read.
- **`coolify`**: the workloads the host runs, with their type, status, CPU and
  memory.  Identity comes from the containers' own Coolify labels and
  `docker stats`, never from the Coolify API, so no token is needed.
- **`tool_statuses`** with a **reason** for every row.

### The amber dots

Amber meant `unknown`: the collector could not prove whether the tool was
running, because an interpreted CLI's process is named `node` or `python`
rather than after the tool.  On this server that left seven of eleven tools
amber.

Three changes made the answers determinate:

- The MiniMax Code seat's launcher is `minimax-code`, not `mcode`; matching
  only the command name made a running seat read as unknown.
- The Fleet Recall service and the Fleet Listener run as **Coolify
  workloads** here, not as systemd units.  A container's name is the honest
  identity for a tool whose process is an interpreter.
- A tool that is not installed on the host is `absent`, whatever else is
  running.  That answer does not depend on the process list.

The result on the host:

| Tool | Before | After |
|---|---|---|
| Claude Code | unknown | unknown — *runs under an interpreter; not provable from process identity* |
| Codex | running | running (2) |
| Muse | unknown | unknown, with the reason shown |
| MiniMax Code | unknown | **running (1)** |
| Fleet CLI | unknown | unknown, with the reason shown |
| Fleet Listener | unknown | **running (1 container)** |
| Fleet Recall | unknown | **running (1 container)** |
| Shellular, Docker, PostgreSQL, Redis | running | running |

The three that stay amber say why, in words, on the row itself.  An unknown
state without a reason is a dot nobody can do anything about.

## The control agent (`scripts/server-status/control.py`)

Installed at `/usr/local/sbin/hoghunter-control`, root-owned, not writable by
anyone else.  It is what the Mac calls over the same SSH path the readings
use.

- `list` — the processes and Coolify workloads the host will act on.
- `stop-process --pid N --start-time T [--force] --confirm`
- `stop-container --name NAME --confirm`
- `restart-container --name NAME --confirm`

The rules it keeps:

- **Identity, not a bare pid.**  The caller names the pid *and* the start
  time the collector read, so a pid that was recycled between the reading and
  the click is refused.  This is the same rule the Mac's own `ProcessControl`
  keeps.
- **The owner allowlist**: the root and jay accounts, and Coolify's
  workloads.  Anything else is refused.
- **The denylist**: `systemd`, `sshd`, `dockerd`, `containerd`, `tailscaled`,
  `fail2ban-server`, the Datadog agents, the Coolify containers and the
  login shells.  Kernel threads are never offered and never signalled.
- **The caller's own session** is never stopped, and neither is any process
  above it in the tree.
- **`--confirm` is required.**  Without it the command refuses and says so.
- **An audit log** at `/var/log/hoghunter-control.log`, root-only, naming
  every action and every refusal.

The Mac's Server page now lists the server's processes and workloads with a
Stop button, behind a confirmation dialog.

## File sharing over Tailscale

Samba is installed and the fleet-extra volume is shared over the tailnet.

- The share is `fleet-extra` → `/mnt/fleet-extra`, readable and writable by
  the `jay` account, which is already in the `fleet` group that owns the
  volume, so the files the Mac leaves behind belong to the same accounts.
- Samba cannot bind a `/32` tailnet address, so `smbd` listens on every
  interface and `/usr/local/bin/smb-tailnet-firewall.sh` decides who reaches
  it: 445 is accepted on `tailscale0` and dropped everywhere else, for both
  address families.  An external check confirms **445 is closed on the public
  address** and open on `100.69.77.26`.
- `smbd` requires the firewall unit, so there is no window where the share is
  open before the rules are in place.
- The SMB password is in `/root/.fleet-extra-smb.pass`, root-only.

To mount it on the Mac: `smb://jay@server.boa-roygbiv.ts.net/fleet-extra`.

## The panel and the dashboard

- The drop-down's CPU section is two columns now: this Mac and the server,
  each with a bar graph that fills its half.  The Mac's old graph was a
  sparkline pinned to 36 points inside a full-width row, which is why it read
  as a small drawing in a large space.
- The drop-down's Top Activity has a **This Mac / Server** toggle under the
  list.  The server's rows come from the collector's `processes`.
- The Dashboard's large "Hog Hunter" heading is gone; the window's title bar
  already says it.
- The Dashboard's CPU graph takes the width the memory meter was using.
- The Server block on This Mac's overview sits at the very bottom of the
  window, under a rule, instead of tucked under Top Activity.
- The server's CPU keeps its own minute history, so the two machines' graphs
  have the same shape and can be read against each other.

## Not done here

- **Muster** (AFC-548): the server-side Coolify and config/AGENTS.md report
  and the Muster panel are a separate change in AI-Fleet-Coordinator.
- **The Mac build**: the Swift changes are verified by CI and by review; the
  owner builds and installs with `scripts/install.sh`.
