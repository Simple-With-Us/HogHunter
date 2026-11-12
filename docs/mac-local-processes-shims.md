# Maintain legacy shims

Optional thin forwards so callers that still point at older cleanup entry points can run Hog Hunter's Maintain engine without editing every script path.  The canonical CLI is `scripts/maintain.py`; `scripts/robotic-vacuum.py` is an alias for installed launchd jobs.

| Repo shim | Purpose |
|-----------|---------|
| `scripts/shims/_resolve-repo.sh` | Shared helper for bash shims to find the Hog Hunter clone (`HOGHUNTER_REPO`, then common install paths). |
| `scripts/shims/mac-resource-watch.py` | One scheduled **watch** tick (disk, memory, pressure). |
| `scripts/shims/mac-auto-cleanup.sh` | One **full** or **pressure** maintain run. |
| `scripts/shims/janitor.sh` | One **janitor** tick (worktrees and low-disk reclaim). |

Set `HOGHUNTER_REPO` to the Hog Hunter clone if it is not discoverable from the environment.  Scheduled cleaning after migrate uses the Maintain launchd agent (`maintain.py`), not these shims.  The inventory of owned vs observed scripts lives at `~/.hoghunter/maintenance/registry.json`.

Operator inventory (fleet process list, Apple Notes, legacy launchd labels) is documented in the Robotic Vacuum rollout handoff **Next Steps & Blockers** for owner follow-up after merge.
