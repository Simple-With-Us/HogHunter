# Robotic Vacuum legacy shims

Optional thin forwards so callers that still point at older cleanup entry points can run Hog Hunter's Robotic Vacuum engine without editing every script path.

| Repo shim | Purpose |
|-----------|---------|
| `scripts/shims/_resolve-repo.sh` | Shared helper for bash shims to find the Hog Hunter clone (`HOGHUNTER_REPO`, then common install paths). |
| `scripts/shims/mac-resource-watch.py` | One scheduled **watch** tick (disk, memory, pressure). |
| `scripts/shims/mac-auto-cleanup.sh` | One **full** or **pressure** vacuum run. |
| `scripts/shims/janitor.sh` | One **janitor** tick (worktrees and low-disk reclaim). |

Set `HOGHUNTER_REPO` to the Hog Hunter clone if it is not discoverable from the environment.  Scheduled cleaning after migrate uses the Robotic Vacuum launchd agent, not these shims.

Operator inventory (fleet process list, Apple Notes, legacy launchd labels) is documented in the Robotic Vacuum rollout handoff **Next Steps & Blockers** for owner follow-up after merge.
