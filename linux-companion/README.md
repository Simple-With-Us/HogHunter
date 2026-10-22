# hh-agent

Headless Linux companion for Hog Hunter.  One static binary: `hh-agent serve`
runs the daemon, `hh-agent <cmd>` controls the local host.  Full design in
[SPEC.md](SPEC.md).

## Layout

- `cmd/hh-agent/main.go` — CLI (serve, status, ps, top, containers, prune,
  stop, kill, limit, lanes, pair).  Talks to the daemon over
  `/run/hh-agent.sock`; `status`, `ps`, and `lanes` fall back to direct
  `/proc`/git reads when the daemon is down.
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

## What's implemented vs stubbed

Implemented: CLI parsing and scripting contract, `/proc` process reads,
lane scanner, safety policy, Docker socket client (list/stats/stop/kill/
update/prune/df), audit logging, Unix-socket + HTTP listeners, guarded
stop/kill/limit/prune handlers, pairing-based auth (token store with
hash-only persistence, `POST /v1/pair-request`, CLI `hh-agent pair`
approve/deny/revoke with per-device `hh1_` tokens, Unix-socket-only admin
routes), and the unauthenticated cheap `GET /v1/health` endpoint for
Muster's running/not-running check.

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
