# Disk reclaim deadlock — the maintainer that could not maintain (2026-10-20)

Linear HH-164.  Board `dc74c0ba-7b2d-4431-ad9b-70c9df31541b`.  Python, one small Swift pass, docs.  No LaunchAgent, plist, or bundle-id change.

## What was wrong

The Mac was at 100% with 3.3 GB free on a 460 GB disk and a load average of 611.  Hog Hunter's maintainer had been running and freeing nothing.  Five separate defects, each measured on the live host, and each one alone was enough to stop it.

| Area | Symptom | Cause |
|---|---|---|
| `janitor_cache_reclaim` | `status=skipped freed=0 reason='host under extreme load; cheap steps only'` | The step sat in the heavy-lane step list *and* returned early on `mode == "hard"`, so the disk reclaim never ran on exactly the host that needed it.  A threshold whose value is the normal operating state suppresses the work forever — that is a deadlock, not a guard. |
| `build_status` | `health: "healthy"` while the disk was at 100% | Health read schedule lateness and the last exit code only.  It could not see free space at all. |
| `open_handles` | `lsof could not look at ...; treating it as open` | Every candidate ran its own `lsof` with a 25 s timeout.  A failed lookup counted as one open handle, so under load every cache read as busy and nothing was reclaimable. |
| launchd tick | `runs = 1`, `last exit code = (never exited)` | One tick wedged in `PyImport_ImportModule` for 17 minutes, wrote nothing, and left no child process or open lock behind.  launchd will not start a second instance of a `StartInterval` job while one is running, so a single wedge ended the maintainer with no error and no retry. |
| `hoghunter-clean` | `applied_count = 0, actionable_count = 23, budget_exhausted = True` | A 900 s budget went entirely to the scan, so the deletes never ran and the next run rescanned the same tree and ate the budget again.  A livelock, not progress. |

The owner ruling of 2026-10-02 settles the shape of the answer: pressure changes the *shape* of the work, never its *scope*, and the safe and semi-safe tiers must never be suppressed by a load threshold.

## What changed

**`scripts/hoghunter-clean`**

- One system-wide `lsof` snapshot with an ancestor index, so the per-candidate open-handle lookup is O(1) instead of one subprocess per candidate.  Candidate identity is deduped by inode, because the volume is case-insensitive and `Cache` and `cache` are one directory.
- `SCAN_BUDGET_FRACTION = 0.6`.  The scan gets a fixed 60% share and the apply phase keeps the rest.  "Scan truncated" and "budget spent" are reported as two different outcomes.
- Every scan-side subprocess timeout is clamped by `scan_op_timeout()` to the **scan share**, not merely to the whole run budget.  One candidate pays for three probes (the capped walk, the `find` walk and the `lsof` look), and together they can exceed the 60% share.  The scan share is always the smaller budget, so the whole-budget bound still holds on top of it.  That includes the rules that predate the split — `proc_count`, `rule_snapshots`, `rule_temp_scratch`, `rule_unbounded_logs`, `rule_sqlite_wals` and `rule_brew` — whose probes used to pass a fixed 15 s / 60 s / 90 s and could spend the share `scan()` only checks between rules.  The residual: the marker walk that guards a tree in `apply_delete` is an **apply**-side probe, so it takes `op_timeout()` and draws on the whole run budget rather than a slice of the delete reserve.  It is left there because a walk cut short of its answer fails closed to "marked", and a permanently blocked tree is the failure this document exists to remove.
- Two new safe-tier rules: `app-caches` (idle application caches) and `agent-state` (transient agent logs, tmp and cache).  Both are registered in `config/reclaim-policy.json` *and* in `CleanRegimen.swift`, because a rule that is not in both places does not run.
- A tree named like scratch is not necessarily scratch.  A directory holding a `.project_root` marker is left alone whatever it is called.
- `holds_keep_sentinel(path, timeout)` asks whether a `.janitor-keep` marker exists *anywhere under* a tree, with a bounded `find -iname` walk and no per-file stat.  `-iname`, not `-name`, because the sibling `has_keep_sentinel` resolves the same marker with `Path.exists()`, which is case-insensitive on the default volume: both probes have to recognize exactly the same markers, or a `.JANITOR-KEEP` is honored at a tree root and invisible inside one.  It fails closed: a timeout, an `OSError` or a non-zero return all count as "marked".  It lives in `apply_delete`, the single choke point every delete passes through, so it covers every rule, and the two new rules also ask it at scan time so a marked tree is never offered in the first place.

**`scripts/vacuum/engine.py`**

- `janitor_cache_reclaim` leaves the heavy-lane list and no longer returns early in hard mode, so the safe tier always runs and pressure only changes the chunk size.
- The reclaim step prefers the cleaner's measured `disk_free_delta_gb` over its own estimate.  The measured count is clamped at zero, because the delta is a net change and can be negative; when it is, the reason says in words that the host used the space, so no negative number is ever printed next to "freed".

**`scripts/vacuum/scheduler.py`**

- `build_status` reads the last known free space and classifies the disk `ok`, `acute`, `critical` or `unknown`, using the same thresholds (`crit` 15, `warn` 25) that the watch's own threshold hits use, so the headline and the watch can never disagree.  A critically low disk outranks every other headline state: `critical` > `failed` > `degraded` > `overdue` > `healthy`.

**`scripts/maintain.py`**

- `TICK_WATCHDOG_SEC = 900.0`.  The watchdog is armed at module scope, before the vacuum imports, so a wedge in the import itself cannot escape it.  It exits with code 3 and a reason on stderr rather than blocking, and the atomic temp-file-plus-rename writes mean a kill loses nothing.  900 s cannot cut a legitimate 600 s reclaim plus its 180 s grace.
- The dry-run contract holds: a dry run does not arm the watchdog.
- `_argv_tick_timeout` and `main()` are built from one parser builder, so the pre-import parse cannot drift from the real one.

**Swift**

- `MaintainStatus.disk` carries free space, a health class and a display string; the Maintain panel shows a Disk Space row.
- `CleanRegimen.ruleNames(for:)` returns a `Set<String>`; `.userCaches` maps to `dev-caches` and `app-caches`, and `.aiArtifacts` maps to `agent-state` and `xcode-artifacts`.

## Two bugs the review did not name

Underneath the scan-livelock finding were two defects the finding itself did not identify.

- Both new rules assigned the module global `_SCAN_BUDGET_EXHAUSTED` without declaring it `global`, so Python created a function-local name and the module flag never moved.  A run could hit its scan share, free nothing, and still report a clean run.
- The deadline guard only fired inside the candidate loop, so a rule whose target list was empty never said the scan had hit its share.

Both are verified with an AST walk rather than by reading, and the tests assert the flag from outside the function.

## One deliberate divergence from a review suggestion

The suggestion clamped the scan probes to the whole run budget.  That stops a probe outliving the run's hard stop, but not outliving the scan's own 60% share.  The clamp is to the scan share instead, which is always the smaller of the two budgets, so the whole-budget bound still holds on top of it.

## Measured

| | Before | After |
|---|---|---|
| Free space | 3.3 GB | ~46 GB |
| Load average | 611 | ~45 |
| Deleted by the engine | 0 | 6.48 GB across 43 safe-tier candidates, 0 failures |

The agent session transcripts (5.4 GB) are report-only by policy and were left intact.

## Verify

- `python3 scripts/test-hoghunter-clean.py` -> ok (74 tests)
- `python3 scripts/test-robotic-vacuum.py` -> ok (299 tests)
- `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` -> ok

## Still open

- A restart is the biggest remaining win on the host: about 25 GB, being 21.3 GB of swap plus 4.05 GB that LaunchServices still holds open in deleted files.  It is the owner's call because it kills the running agent sessions.
- `scripts/vacuum/store.py` `_locked_json_update()` still uses a blocking `fcntl.flock(LOCK_EX)` with no timeout.  That is a latent hang hazard and is unchanged here.
- The open item in `docs/rollouts/2026-10-09-vacuum-full-run-fixes.md` — expand `janitor_cache_reclaim` if janitor parity gaps appear in production — still stands.
