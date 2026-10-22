# hh-agent — HogHunter Linux Companion Daemon

One binary, two faces: a headless daemon (`hh-agent serve`) that watches and
cleans a Docker host, and a local CLI (`hh-agent <cmd>`) that drives it from
the server itself — over SSH, by fleet agents, or by scripts.  The HogHunter
Mac app's Devices view and the iOS app talk to the daemon over HTTP; the CLI
talks to it over a local Unix socket and degrades gracefully when the daemon
is down.

A managed node is a **device** — a Linux host running this daemon, a Mac
running HogHunter, or an iPhone reporting its own resources.  The Mac app can
connect to many devices at once (multiple companions, and multiple Macs in
the future); each device is independently addressable, so no primary is
needed — the Devices view aggregates per device.

Status: spec + scaffold on branch `feature/linux-companion`.  Host process
listing, lane scanning, the safety policy, and the Docker-socket client are
implemented.  Prune-apply, kill paths, and cgroup limit-setting are wired
through the safety policy but marked clearly in code.

## 1. Goals

- One agent per Docker host, never one per container.  The daemon mounts
  `/var/run/docker.sock` and sees every container on its host through the
  Docker API.
- Disk/storage optimization for Docker hosts: per-container, per-image, and
  per-volume storage reporting; pruning of unused images, dangling volumes,
  stopped containers, and build cache.
- Process monitoring at least as good as the Mac app, better where Linux
  allows: host processes from `/proc`, per-container CPU/RAM/IO from cgroup
  stats via the Docker stats API, top-style views by CPU, RAM, and storage.
- User-initiated stop/kill of containers and host processes, and live
  container resource limits (CPU/memory caps without restart).
- Locally runnable and controllable on the server itself: the CLI is the
  control surface for agents over SSH — no HogHunter UI required.
- Lane drift visibility: report which fleet lane checkouts have changes not
  in GitHub, in the same shape the Mac app reports.
- Infisical for secrets: the Linux daemon takes its API token from Infisical
  (via Coolify env) — no enroll flow.  The Mac app gains Infisical as an auth
  option too, alongside a repaired pairing flow.
- Devices, not hosts: the UI concept is a device.  The Devices view lists
  every connected device, each reachable over SSH or the companion HTTP API,
  with per-device settings.
- iOS as a device: the iPhone app optionally reports its own CPU/RAM/storage
  so the Mac's Devices view can show it.

## 2. Non-goals

- No macOS code, no Swift.  The Mac-app side of the lane schema is future
  HogHunter repo work; this spec only defines the shared schema.
- No metrics history database, no alerting pipeline.  One daemon, one host,
  current state — the Mac app's Devices view aggregates the per-device
  lists; the daemon never does.
- No automatic killing or pruning.  Every destructive action is
  user-initiated (UI, CLI, or explicit API call) and audit-logged.

## 3. Language: Go

Single static binary (`CGO_ENABLED=0`), so Coolify deploys one image with no
runtime.  The standard library covers the HTTP server, the Unix-socket
listener, and JSON; the official Docker Go SDK speaks to the socket mount;
`/proc` parsing is a solved, tiny problem in Go.  Memory footprint stays in
the low tens of MB, which matters for a daemon that lives on every host.
Cross-compilation is one env var, so the same source builds the amd64 VPS
binary and an arm64 test binary.  Rust would match on binary size and
safety but the first-party Docker SDK and faster iteration win for this.

## 4. Architecture

```
                  Tailscale (HTTP :24241, Bearer token)
  Mac Devices view ───────────────▶  hh-agent serve
  iOS app ────────────────────────▶    ├─ Docker client (/var/run/docker.sock)
                                       ├─ /proc reader
  ssh / local agent ──▶ hh-agent ──▶   ├─ lane scanner (git, read-only)
  (Unix socket                        └─ audit log (JSONL)
   /run/hh-agent.sock)
```

- The daemon alone holds the Docker socket mount.  Nothing else needs it.
- CLI reads that don't need Docker (host `ps`, disk overview) work even
  when the daemon is down, by reading `/proc` and the filesystem directly.
  Container operations report "daemon unavailable" with exit code 3 instead
  of failing silently.
- HTTP API version is `/v1` under a new device path namespace.  It is
  deliberately separate from the Mac companion protocol (`Sources/Companion`
  in this repo): different device class, different capabilities.
- Backward compatibility with the existing Server tab (becoming the Devices
  view): the daemon can also
  emit the legacy `/root/vps-storage-status.json` shape
  (`VPSStatusSnapshot`, snake_case, `generated_at`) that
  `Sources/Storage/VPSStatusStore.swift` already polls over SSH.  The HTTP
  API is the primary surface; the legacy file is a bridge until the Mac app
  migrates.
- Devices view (Mac app, future work in this repo): a settings screen lists
  devices — each with a name, address, and transport: the companion HTTP API
  (preferred) or an SSH command that runs the helper remotely.  Multiple
  companions, and later multiple Macs, are all first-class; the view shows
  one section per device and every action targets the device the user
  picked.  No primary device is needed.

## 5. Security model — read this first

Mounting the Docker socket is **root-equivalent on that host**: any process
that can write to it can start a privileged container and own the machine.
This is not a limitation to work around; it is the design.  Consequences:

- The daemon runs only on Jay's own hosts (Hetzner VPS fleet via Coolify).
  Never on shared or customer infrastructure.
- The HTTP listener binds to the Tailscale IP (and loopback) only — never
  `0.0.0.0` on a public interface.  All callers present a Bearer token.
- Auth, Linux daemon: Infisical only — no pairing-code enroll flow.  The
  daemon reads its API token from the `HH_AGENT_API_TOKEN` env var, which
  Coolify injects from Infisical (the same sync Jay already uses for app
  env).  Token format follows the Mac convention (`hh1_` prefix); the
  daemon stores only a SHA-256 hash for comparison.  `POST /v1/enroll` is
  not implemented on the daemon.
- Auth, Mac app (future work): Infisical becomes an auth option alongside
  the pairing flow — Jay's call 2026-10-21, since the Infisical session
  persists and the current pairing barely works on the Mac or the iOS app.
  The pairing/enroll flow itself needs repair too; that is Mac/iOS app
  work, tracked separately.  Per this repo's AGENTS.md, the Mac app owns
  the Infisical read and the iOS app never touches Infisical.
- Destructive routes sit behind explicit opt-ins, off by default, following
  the repo's route-table convention (`AGENTS.md`):

| Route | Credential | Opt-in (daemon config) | Peer must be |
|---|---|---|---|
| `GET /v1/*` reads | a device token, or the pairing code | none (reads only) | tailnet |
| `POST /v1/processes/{pid}/kill`, `POST /v1/containers/{id}/stop|kill` | a device's own token | Allow Remote Process Control | tailnet |
| `POST /v1/containers/{id}/limit` | a device's own token | Allow Remote Process Control | tailnet |
| `POST /v1/prune` | a device's own token | Allow Remote Disk Pruning | tailnet |
| `POST /v1/enroll` | not implemented on the daemon (Infisical only) | — | — |

  Each device confirms every destructive action in its own UI; the daemon
  re-checks the safety policy (§8) per action.
- The Unix socket is mode 660, group-owned by a dedicated `hh-agent` group;
  fleet agent users are added to that group.  No token needed locally —
  socket file permissions are the auth.
- Every stop/kill/limit/prune is appended to an audit log:
  `/var/log/hh-agent/audit.jsonl`, one JSON object per action with
  timestamp, actor (token id or local user), action, target, and result.

## 6. HTTP API (daemon)

Base: `http://<tailscale-ip>:24241/v1`.  JSON everywhere.  Auth: Bearer
token, except `/v1/health` and `/v1/version` which are unauthenticated.

Reads:

- `GET /v1/health` → `{"ok": true, "version": "0.1.0"}`
- `GET /v1/snapshot` → host overview: hostname, uptime, loadavg, cpu
  (model, count, usage %), memory, swap, disks (per device: total/used/
  avail), PSI (cpu/memory/io pressure, when the kernel exposes it).
- `GET /v1/processes?sort=cpu|mem|pid&limit=50` → host processes from
  `/proc`: pid, ppid, user, comm, cmdline (truncated), cpu %, rss, state,
  start time.  CPU % is delta-based over a 1s sample window.
- `GET /v1/containers` → every container: id (short), name, image, state,
  cpu %, mem usage/limit, block IO, net IO, pids, writable-layer bytes
  (exact, from the overlay diff dir), OOM-kill count (cgroup
  `memory.events`), and current live limits.
- `GET /v1/storage` → Docker disk usage: images (per image: repo tags,
  size, containers using it, dangling bool), volumes (per volume: size
  where available, containers using it), build cache total, plus
  `docker system df` reclaimable totals.
- `GET /v1/lanes` → lane scan, shared schema (§9).

Writes (all require explicit confirmation semantics; see §8):

- `POST /v1/prune` — body `{"targets": ["images","volumes","build-cache",
  "stopped-containers"], "dry_run": true}`.  `dry_run` defaults true; the
  response lists what would be / was reclaimed.  An additional opt-in target
  `"host-temp"` covers host-level temp (`/tmp`, journal logs); it is never
  included unless explicitly requested — Docker-scoped is the default
  (Jay's call 2026-10-21: optionally both).
- `POST /v1/processes/{pid}/kill` — body `{"signal": "TERM"}`; TERM first,
  escalates to KILL after a grace period unless `{"signal":"KILL"}`.
- `POST /v1/containers/{id}/stop` — body `{"timeout": 10}`; then
  `/v1/containers/{id}/kill`.
- `POST /v1/containers/{id}/limit` — body `{"memory": "2g", "cpus": 1.5}`.
  Live-updates cgroup limits via the Docker API; no container restart.

Every write returns `{"ok": true, ...}` or
`{"ok": false, "error": "<reason>", "refused_by": "safety-policy"|...}`.

## 7. CLI — the local control surface

One binary.  No config file for basic use; sensible defaults
(socket `/run/hh-agent.sock`, HTTP fallback `http://127.0.0.1:24241`).

```
hh-agent status [--json]
  Host overview: uptime, load, cpu/mem/swap, disk usage.  Works without the daemon.

hh-agent ps [--sort cpu|mem|pid] [--limit N] [--json]
  Host processes, top-style.  Works without the daemon (reads /proc directly).

hh-agent top [--json]
  Same as ps --sort cpu; kept as the familiar name.

hh-agent containers [--json]
  All containers with cpu/mem/io/storage/limits/oom-kills.  Needs the daemon.

hh-agent prune [--images] [--volumes] [--cache] [--stopped-containers]
               [--host-temp] [--dry-run] [--yes] [--json]
  Default with no flags: dry-run across the four Docker targets and print
  what would go.  --dry-run is the default; applying requires --yes.  Never
  touches running containers, in-use images, or in-use volumes.  --host-temp
  adds host-level temp and journal logs; it is opt-in only.

hh-agent stop <container|pid> [--timeout 10] [--yes] [--json]
hh-agent kill <container|pid> [--yes] [--json]
  Interactive confirmation when stdin is a TTY; --yes for agents/scripts.
  Refuses protected targets (see §8) with exit code 3.

hh-agent limit <container> [--memory 2g] [--cpus 1.5] [--json]
  Set live CPU/memory caps.  At least one flag required.

hh-agent lanes [--json]
  Lane drift scan per the shared schema (§9).  Works without the daemon.

hh-agent serve [--http 127.0.0.1:24241] [--socket /run/hh-agent.sock]
  Run the daemon.
```

Scripting contract:

- `--json` on every read command; JSON goes to stdout, human prose to
  stderr or not at all.
- Exit codes: 0 success · 1 operational error · 2 bad usage/flags ·
  3 refused by safety policy or daemon unavailable.
- No interactive prompts when stdin is not a TTY unless `--yes` is given;
  without `--yes` and without a TTY, destructive commands refuse (exit 3)
  rather than guessing.
- Destructive operations always require an explicit apply signal: `--yes`
  on the CLI, `"dry_run": false` on the API.  There is no "just do it"
  default.

## 8. Safety policy (mandatory)

The policy lives in one place (`internal/safety`) and both the CLI and the
HTTP handlers consult it before any destructive action.  A refusal is a
refusal everywhere, with the reason returned.

Never kill, stop, or limit:

- PID 1, the agent's own PID, or anything in the agent's process tree.
- `dockerd`, `containerd`, `containerd-shim*`, `docker-proxy`.
- `coolify*`, the Coolify agent/realtime processes.
- `tailscaled`, `tailscale` — killing the management plane strands the host.
- `sshd` and its active sessions — killing the shell you came in on is a
  classic foot-gun.
- Kernel threads (no cmdline, ppid 2) — meaningless to kill.

Never prune:

- Running containers, images with running containers, volumes attached to
  any container (running or stopped), volumes carrying a `keep` label.
- Anything when free disk is not actually the problem and `--yes` was not
  given?  No — prune is explicit; the policy only guards targets, not
  motives.

Confirmation ladder:

1. UI/API/CLI without apply flag → dry-run or refusal, never action.
2. Interactive TTY → print the exact target list, require typed `yes`.
3. `--yes` / `"dry_run": false` → act, and append to the audit log.

The audit log is append-only JSONL; log rotation never deletes the current
day's file.

## 9. Lane status — shared schema (Mac app + Linux companion)

Both apps report lanes in this identical shape so the Devices view renders one
table per device.  JSON keys are snake_case, matching the existing
`VPSStatusSnapshot` conventions.

```json
{
  "path": "/workspace/ai-fleet-coordinator",
  "repo": "ai-fleet-coordinator",
  "branch": "muse-assist/lane-policy",
  "upstream": "origin/muse-assist/lane-policy",
  "dirty": true,
  "dirty_file_count": 3,
  "dirty_paths": ["Sources/UI/Foo.swift", "docs/bar.md"],
  "ahead": 2,
  "behind": 0,
  "last_commit_at": "2026-10-21T19:00:00Z",
  "verdict": "unpushed",
  "scanned_at": "2026-10-21T19:44:00Z"
}
```

Fields:

- `path`: absolute lane path.  `repo`: directory basename (the repo name).
- `branch`: current branch, or `DETACHED@<sha>` when detached.
- `upstream`: tracking ref or null.  `ahead`/`behind`: commit counts vs
  upstream (0/0 when no upstream).
- `dirty`: working tree differs from HEAD (staged, unstaged, or untracked).
  `dirty_file_count`: porcelain line count; `dirty_paths`: first 10 paths.
- `last_commit_at`: HEAD commit time, ISO-8601, or null on empty repo.
- `verdict`: `clean` | `dirty` | `unpushed` | `diverged` | `no-upstream`
  | `error`.
  - `clean`: not dirty, ahead == 0, behind == 0.
  - `dirty`: dirty (regardless of ahead/behind — dirt is the headline).
  - `unpushed`: not dirty, ahead > 0, behind == 0.
  - `diverged`: ahead > 0 and behind > 0.
  - `no-upstream`: no tracking ref configured.
  - `error`: the lane could not be read; `error` field carries the reason.
- `scanned_at`: when this lane was read.

Discovery:

- Lane roots are configured (`lane_roots: ["/workspace", ...]` on Linux;
  the Mac app will use its own, e.g. `/Volumes/External/Lanes/*/*`).
- A lane is any directory containing `.git` — a file means git worktree, a
  directory means full clone.  Non-git directories are skipped silently.
- The `git` invocations are read-only, always:
  `git status --porcelain=v1`, `git rev-parse --abbrev-ref HEAD`,
  `git rev-parse @{u}`, `git rev-list --count HEAD..@{u}` /
  `@{u}..HEAD`, `git log -1 --format=%cI`.  Never `fetch`, never anything
  that mutates.  A per-lane timeout (10s) keeps one stuck repo from
  stalling the scan; lanes scan in parallel (bounded worker pool).
- A per-lane failure sets `verdict: "error"` with the reason; the scan as
  a whole still succeeds.
- Rescan triggers: HTTP `GET /v1/lanes?refresh=1`, CLI `hh-agent lanes`,
  and a configurable interval (default 15 min) for the daemon's cached copy.

The Linux companion implements the scanner now (`internal/lanes`).  The
Mac-app-side implementation is future work in this repo — it implements the
same schema and discovery conventions, no new fields without updating this
spec.

## 10. "Better than Mac" — what Linux genuinely enables

Only the real advantages, no marketing:

- **Live resource limits.** `POST /v1/containers/{id}/limit` rewrites
  cgroup CPU/memory caps on a running container via the Docker API — no
  restart.  macOS has no supported per-process RAM cap for arbitrary
  processes; the Mac app can only kill runaways.  Here a runaway gets
  throttled first, killed only if the user says so.
- **Exact attribution instead of sampling.** Container CPU/RAM come from
  cgroup v2 `cpu.stat` / `memory.stat`, not from sampled process tables.
  Per-container numbers add up; on the Mac they are estimates that drift.
- **OOM-kill visibility.** `memory.events` exposes `oom_kill` per
  container — the daemon reports which containers the kernel actually
  killed, with counts.  macOS exposes no equivalent per-process counter.
- **Pressure stall information (PSI).** `/proc/pressure/{cpu,memory,io}`
  shows resource contention *before* anything dies — "memory is 40%
  stalled" is an earlier and better signal than "memory is 90% full".
- **Exact writable-layer sizes.** Overlay diff directories give the true
  per-container disk cost; no estimation, no double-counting shared layers.

## 11. Deployment (Coolify)

- One Docker image, multi-stage build: `golang:1.23-alpine` compiles the
  static binary, final stage is `scratch` + the binary + CA certs.
- Coolify app per VPS host, with mounts:
  - `/var/run/docker.sock` → `/var/run/docker.sock` (rw; the privileged
    one — see §5),
  - `/proc` → `/host/proc` (ro), `/sys` → `/host/sys` (ro),
  - a named volume for `/var/log/hh-agent` (audit log survives restarts).
- The agent's own container gets resource limits in Coolify
  (e.g. 0.5 CPU, 256 MB) so the watchdog cannot become the problem.
- Env: `HH_AGENT_PORT` (default 24241), `HH_AGENT_LANE_ROOTS`
  (comma-separated), `HH_AGENT_API_TOKEN` (injected by Coolify from
  Infisical — the daemon's only auth source; never in the image or repo).
- Tailscale: the Coolify host is already on the tailnet; the daemon binds
  the host's Tailscale IP.  No exposure outside the tailnet.

## 12. Decisions (Jay, 2026-10-21)

1. Auth: the Linux daemon is Infisical-only (token via Coolify env from
   Infisical; no enroll flow).  The Mac app gains Infisical as an auth
   option, and its pairing flow gets repaired — pairing barely works on the
   Mac or the iOS app today.
2. Prune scope: Docker objects by default; host-level temp (`/tmp`,
   journals) is an explicit opt-in (`--host-temp` / `"host-temp"`).
3. Devices: the UI concept is Devices, not Hosts.  The Devices view lists
   every connected device with per-device transport (companion HTTP API or
   an SSH command running the helper); multiple companions and future
   multiple Macs are first-class, with no primary device.
4. iOS as a device: the iPhone app optionally reports its own CPU/RAM/
   storage so the Mac's Devices view can show it (iOS app work; spec the
   payload alongside the existing snapshot).

Open: legacy `/root/vps-storage-status.json` bridge — keep the SSH-script
path working in parallel, or cut the Devices view to HTTP immediately?
