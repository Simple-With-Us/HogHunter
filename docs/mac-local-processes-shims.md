# Mac local process shims (Robotic Vacuum)

Canonical registry for Robotic Vacuum **thin shims** in this repository.  Copy or mirror these rows into the owner Mac fleet inventory (`MAC-LOCAL-PROCESSES.md` under `~/apps/`) after migrate.

| Shim (repo path) | Replaces / legacy caller | Invokes | Notes |
|------------------|--------------------------|---------|-------|
| `scripts/shims/mac-resource-watch.py` | `~/apps/mac-resource-watch.py`, launchd `com.jay.mac-resource-watch` | `python3 "$HOGHUNTER_REPO/scripts/robotic-vacuum.py" --run-now watch` | Accepts `--once` (ignored; always one watch tick).  Set `HOGHUNTER_REPO` if the clone is not at `~/Code/HogHunter`. |
| `scripts/shims/mac-auto-cleanup.sh` | `~/apps/mac-auto-cleanup.sh`, `com.jay.mac-cleanup` | `robotic-vacuum.py --run-now full` or `--run-now pressure` with `--pressure` / `MAC_CLEANUP_PRESSURE=1` | Does not run migrate; scheduling is `com.simplewithus.hoghunter.robotic-vacuum`. |
| `scripts/shims/janitor.sh` | `~/.claude-disk-janitor/janitor.sh`, `com.jay.disk-janitor` | `robotic-vacuum.py --run-now janitor` | Worktree retirement + low-disk reclaim live in the Python engine. |

**Primary scheduler (not a shim):** launchd label `com.simplewithus.hoghunter.robotic-vacuum` → `scripts/robotic-vacuum.py --tick scheduler` every 300s.
