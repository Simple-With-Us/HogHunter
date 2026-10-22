# hh-agent

Headless Linux companion for Hog Hunter.  One static binary: `hh-agent serve`
runs the daemon, `hh-agent <cmd>` controls the local host.  Full design in
[SPEC.md](SPEC.md).

## Layout

- `cmd/hh-agent/main.go` — CLI (serve, status, ps, top, containers, prune,
  stop, kill, limit, lanes).  Talks to the daemon over `/run/hh-agent.sock`;
  `status`, `ps`, and `lanes` fall back to direct `/proc`/git reads when the
  daemon is down.
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
stop/kill/limit/prune handlers.

Stubbed (marked `STUB` in code): Bearer-token verification (accepts any
non-empty token until the `hh1_` token store lands), `/v1/snapshot` host
detail, the daemon's 15-minute lane cache, the legacy
`/root/vps-storage-status.json` bridge.

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

`HH_AGENT_SOCKET`, `HH_AGENT_HTTP`, `HH_AGENT_TOKEN`, and
`HH_AGENT_LANE_ROOTS` (comma-separated) override the defaults.
