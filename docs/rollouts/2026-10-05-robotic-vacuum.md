# Robotic Vacuum (2026-10-05)

## Context & Objective

Hog Hunter becomes the home for scheduled Mac cleaning (**Robotic Vacuum**), replacing loose `com.jay.*` launchd jobs with one agent, durable history, alerts, and a Storage UI tab.

## Changes Made

- `config/robotic-vacuum.json`
- `docs/rollouts/2026-10-05-robotic-vacuum.md`
- `launchd/com.simplewithus.hoghunter.robotic-vacuum.plist`
- `scripts/hoghunter-mcp.py`
- `scripts/robotic-vacuum.py`
- `scripts/robotic-vacuum-migrate.sh`
- `scripts/robotic-vacuum-rollback.sh`
- `scripts/shims/janitor.sh`
- `scripts/shims/mac-auto-cleanup.sh`
- `scripts/shims/mac-resource-watch.py`
- `scripts/test-robotic-vacuum.py`
- `scripts/vacuum/` (engine, scheduler, alerts, janitor helpers)
- `Sources/Storage/RoboticVacuumModels.swift`
- `Sources/Storage/RoboticVacuumStore.swift`
- `Sources/UI/RoboticVacuumView.swift`
- `Sources/UI/StorageView.swift`
- `Tests/HogHunterTests/RoboticVacuumTests.swift`
- `.github/workflows/ci.yml`
- `README.md`
- `docs/mac-local-processes-shims.md`

## Decisions & Trade-offs

- **Single 5-minute launchd tick** runs watch (300s), janitor (1800s), and full (14400s) cadences internally instead of three agents.
- **Janitor parity:** Python port covers retirement, pressure gates, and cheap truncations; full bash `du` bucket probes and prod/dev `.next` CACHE-only sweeps stay deferred to `hoghunter-clean` until production logs show gaps.
- **Safety:** Preserves legacy rules (no Simulator Devices delete, no `simctl shutdown all`, install-aware cache prunes, in-place log truncation, tracked-git guard, re-entrant housekeeper lock, no RAM optimize).
- **Migration not automated from CI:** `robotic-vacuum-migrate.sh` is owner-run on Mac after review.

## Verification State

| Command | Result |
|---------|--------|
| `python3 scripts/test-robotic-vacuum.py` | PASS (Linux CI) |
| `python3 scripts/test-hoghunter-clean.py` | PASS (Linux CI) |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` | PASS (GitHub Actions `test` job after `UInt64` fix) |
| Robotic Vacuum Swift UI (code review + GitHub Actions `test` job) | PASS |
| `bash scripts/robotic-vacuum-migrate.sh` on owner Mac | NOT RUN (post-merge) |

## Next Steps & Blockers

- After merge, from the repo root on a Mac: `bash scripts/robotic-vacuum-migrate.sh`.  The script prints `export MIGRATION_BACKUP_PATH=...` — use that value only; rollback paths are not duplicated in this doc (Rule 1).
- Rollback: `bash scripts/robotic-vacuum-rollback.sh "${MIGRATION_BACKUP_PATH:?set from migrate output}"`.
- **Owner fleet inventory (tracked, post-merge):** mirror `docs/mac-local-processes-shims.md` into the Mac-only fleet process list (`MAC-LOCAL-PROCESSES.md` under the owner apps workspace) and refresh the linked Apple Note for the resource-watch shim.  Jay agreed these are good suggestions — fix after merge, not in this PR.
- After migrate, confirm the Robotic Vacuum launchd job is loaded and that `~/Library/Logs/HogHunter/robotic-vacuum.{out,err}.log` shows scheduler ticks (literal labels and plist paths live only in `scripts/robotic-vacuum-migrate.sh` / `-rollback.sh`).
- Expand `janitor_cache_reclaim` if janitor parity gaps appear in production.

## Zero-Code Findings

- Fleet agents poll `hoghunter_robotic_vacuum_status` / `python3 scripts/hoghunter-mcp.py --cli vacuum`.
- Shim inventory for fleet docs: `docs/mac-local-processes-shims.md`.
