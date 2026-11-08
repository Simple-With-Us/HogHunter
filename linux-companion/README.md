# hh-agent

Headless Linux companion for Hog Hunter.  One static binary: `hh-agent serve`
runs the daemon, `hh-agent <cmd>` controls the local host.  Full design in
[SPEC.md](SPEC.md).

## Layout

- `cmd/hh-agent/main.go` — CLI (serve, status, ps, top, containers, prune,
  autoclean, stop, kill, limit, lanes, pair).  Talks to the daemon over
  `/run/hh-agent.sock`; `status`, `ps`, and `lanes` fall back to direct
  `/proc`/git reads when the daemon is down.  `autoclean` runs in-process
  and needs no daemon at all.
- `internal/auth/` — device token store (SHA-256 hashes only, 0600 files),
  pairing-request ledger with 15-minute TTL, per-IP rate limiting, and
  `hh1_` token minting (192-bit entropy).
- `internal/daemon/` — HTTP API server (`:24241`), safety-checked writes.
- `internal/docker/` — Docker Engine API client over the Unix socket
  (stdlib only, no SDK).
- `internal/host/` — `/proc` process listing with delta-based CPU%.
- `internal/lanes/` — read-only git lane drift scanner, shared schema.
- `internal/safety/` — the single choke point for destructive actions.
- `internal/audit/` — append-only JSONL audit log.
- `internal/autoclean/` — automatic root-disk cleanup (SPEC.md §14):
  threshold-triggered, safe categories only, with the pure planners
  (backup keep-1, stale-tmp, journal vacuum) split from the runner so
  the safety logic is unit-tested without a filesystem.
- `deploy/` — systemd oneshot + timer for hosts that prefer scheduled
  `hh-agent autoclean --yes` runs over the daemon's built-in loop.

## What's implemented vs stubbed

Implemented: CLI parsing and scripting contract, `/proc` process reads,
lane scanner, safety policy, Docker socket client (list/stats/stop/kill/
update/prune/df), audit logging, Unix-socket + HTTP listeners, guarded
stop/kill/limit/prune handlers, pairing-based auth (token store with
hash-only persistence, `POST /v1/pair-request`, CLI `hh-agent pair`
approve/deny/revoke with per-device `hh1_` tokens, Unix-socket-only admin
routes), the unauthenticated cheap `GET /v1/health` endpoint for
Muster's running/not-running check, and automatic root-disk cleanup
(`internal/autoclean`, SPEC.md §14): a threshold-triggered loop in the
daemon (opt-in via `HH_AGENT_AUTOCLEAN=1`), `hh-agent autoclean`, and
`POST /v1/autoclean` / `GET /v1/autoclean/history`, all sharing one
runner, the audit log, and a cleanup history in the Mac app's
`cleanup-history.jsonl` schema.

Stubbed (marked `STUB` in code): `/v1/snapshot` host detail, the daemon's
15-minute lane cache, the legacy `/root/vps-storage-status.json` bridge.

## Build

```sh
cd linux-companion
CGO_ENABLED=0 go build -o hh-agent ./cmd/hh-agent
```

Or via Docker (no local Go needed): `docker build -t hh-agent .`

## Quick start on a host

```sh
# Daemon (needs the Docker socket):
sudo ./hh-agent serve --http 127.0.0.1:24241

# From the same host, over SSH, no config:
./hh-agent status
./hh-agent ps --sort mem --limit 10
./hh-agent containers
./hh-agent prune --dry-run
./hh-agent lanes
./hh-agent limit <container> --memory 2g --cpus 1.5
```

`HH_AGENT_SOCKET`, `HH_AGENT_HTTP`, `HH_AGENT_TOKEN`,
`HH_AGENT_LANE_ROOTS` (comma-separated), and `HH_AGENT_STATE_DIR` (token
store; default `/var/lib/hh-agent`) override the defaults.

## Automatic root-disk cleanup

Off by default.  With `HH_AGENT_AUTOCLEAN=1`, the daemon checks the
root filesystem every 15 minutes and, only when it is at or over 80%
used or under 30 GiB free, reclaims the safe categories: Docker build
cache, dangling Docker images, superseded local backups (newest
complete dump per app kept), the systemd journal (vacuumed to 500 MiB,
never below a 200 MiB floor), and stale temp files (7+ days old, not
open).  Live app data, Docker volumes, tagged images, lanes, and the
sole local backup copy of any app are never touched.  Applied runs land
in the audit log and in `cleanup-history.jsonl` next to it.

```sh
# On the host, any time — no daemon needed:
./hh-agent autoclean --dry-run     # show the plan for the current disk state
./hh-agent autoclean --yes         # apply, if the trigger is met
./hh-agent autoclean --yes --force # apply regardless of the trigger
./hh-agent autoclean --history     # what past runs reclaimed, per category
```

Overrides: `HH_AGENT_AUTOCLEAN_USED_PCT`, `HH_AGENT_AUTOCLEAN_MIN_FREE_GB`,
`HH_AGENT_AUTOCLEAN_CHECK_MINUTES`, `HH_AGENT_AUTOCLEAN_COOLDOWN_HOURS`,
`HH_AGENT_AUTOCLEAN_BACKUP_DIRS` (comma-separated),
`HH_AGENT_AUTOCLEAN_JOURNAL_MAX_MB`, `HH_AGENT_AUTOCLEAN_TMP_DAYS`, and
`HH_AGENT_AUTOCLEAN_DISABLE` (comma-separated category ids to turn off).
A systemd timer pair for the oneshot form lives in `deploy/`.

Pairing (headless): a new device asks to pair over Tailscale, someone with
shell on the host approves, and the device gets its own revocable token.

```sh
# On the Mac (or any new device), request pairing:
curl -X POST http://<tailscale-ip>:24241/v1/pair-request \
  -d '{"device_name":"Jays Mac"}'

# On the host, every hh-agent invocation shows pending requests; approve:
./hh-agent pair
# approve by id, deny, or revoke a device (scripts):
./hh-agent pair --approve <request-id>   # prints the device token once
./hh-agent pair --deny <request-id>
./hh-agent pair --revoke <device-id>
```
