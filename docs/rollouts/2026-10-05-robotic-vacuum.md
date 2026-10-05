# Robotic Vacuum (2026-10-05)

Hog Hunter now owns Jay's scheduled Mac cleaning under **Robotic Vacuum**.

## What moved in

- `scripts/robotic-vacuum.py` and `scripts/vacuum/` — engine, scheduler, alerts, history.
- `scripts/hoghunter-clean` — still the reclaim core; full vacuum calls it with `--band=cheap|full`.
- Steps ported from `mac-auto-cleanup.sh`, `janitor.sh`, and `mac-resource-watch.py` with the same safety rules (no Simulator Devices delete, no `simctl shutdown all`, skip package cache prunes during installs, truncate logs in place, refuse tracked git paths, no forced worktree removal, re-entrant housekeeper lock, no RAM optimize).

## Scheduling

One launchd agent: `com.simplewithus.hoghunter.robotic-vacuum` every 5 minutes runs `--tick scheduler`, which:

- **Watch** (~5 min): sample disk/RAM/CPU; pressure cleanup with cooldown when thresholds hit.
- **Janitor** (~30 min): worktree retirement and low-disk cache reclaim.
- **Full** (~4 h): full vacuum cadence (former `mac-auto-cleanup`).

## Migrate (run on Mac after review)

```bash
cd ~/Code/HogHunter   # or your clone
bash scripts/robotic-vacuum-migrate.sh
```

Backups land under `~/Library/Application Support/HogHunter/RoboticVacuum/migration-backup/`.

## Rollback

```bash
bash scripts/robotic-vacuum-rollback.sh ~/Library/Application\ Support/HogHunter/RoboticVacuum/migration-backup/<timestamp>
```

## Shims

`scripts/shims/` can replace old script paths so external callers keep working.

## Fleet polling

`python3 scripts/hoghunter-mcp.py --cli vacuum` or MCP tool `hoghunter_robotic_vacuum_status`.

## Intentionally lighter than bash janitor

The full 700-line `janitor.sh` includes extensive `du` bucket probes, per-repo watchdogs, and prod/dev `.next` cache clears.  The Python port covers retirement, pressure gates, cheap truncations, and defers bulk reclaim to `hoghunter-clean`.  Expand `janitor_cache_reclaim` if parity gaps show up in production logs.

## Linux / CI

`python3 scripts/test-robotic-vacuum.py` runs on Linux.  Swift UI and launchd were not compiled in the cloud VM.
