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
- Every probe a rule starts takes its timeout from the clock of the phase it runs in: the **scan share** during the scan, the whole run budget after it.  `probe_timeout()` is the one door, and `_SCAN_PHASE` says which phase is running.  One candidate pays for three probes (the capped walk, the `find` walk and the `lsof` look), and together they can exceed the 60% share.  The scan share is always the smaller budget, so the whole-budget bound still holds on top of it.  A rule's own wall clock is bounded the same way, by `rule_deadline()`.  That includes the rules that predate the split — `proc_count`, `rule_snapshots`, `rule_temp_scratch`, `rule_unbounded_logs`, `rule_sqlite_wals` and `rule_brew` — whose probes used to pass a fixed 15 s / 60 s / 90 s and could spend the share `scan()` only checks between rules.  The marker walk that guards a tree in `apply_delete` is an **apply**-side probe, so it draws on the whole run budget; the sixth round below caps it to a tenth of what is left, so the guard can never eat the delete reserve.
- Two new safe-tier rules: `app-caches` (idle application caches) and `agent-state` (transient agent logs, tmp and cache).  Both are registered in `config/reclaim-policy.json` *and* in `CleanRegimen.swift`, because a rule that is not in both places does not run.
- A tree named like scratch is not necessarily scratch.  A directory holding a `.project_root` marker is left alone whatever it is called.
- `holds_keep_sentinel(path, timeout)` asks whether a `.janitor-keep` marker exists *anywhere under* a tree, with a bounded `find -iname` walk and no per-file stat.  `-iname`, not `-name`, because the sibling `has_keep_sentinel` resolves the same marker with `Path.exists()`, which is case-insensitive on the default volume: both probes have to recognize exactly the same markers, or a `.JANITOR-KEEP` is honored at a tree root and invisible inside one.  It answers with **three** states, not two: a marker was found, the tree is clean, or the probe could not answer (see the sixth and seventh rounds below).  An unknown tree is never deleted, and the report says the probe failed rather than that the operator marked it.  It lives in `apply_delete`, the single choke point every delete passes through, so it covers every rule, and the two new rules also ask it at scan time so a marked tree is never offered in the first place.

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

## The fifth review round found a hole in the clamp

The clamp described above was real but incomplete, and the hole was in the fix rather than in the original defect.

The rules that predate the budget split start their own subprocesses with a **fixed** timeout — 90 s for `rule_temp_scratch`, `rule_unbounded_logs`, `rule_sqlite_wals` and `rule_brew`, 60 s for `rule_snapshots`, 15 s for `proc_count` — and `scan()` only checks the deadline *between* rules.  A rule that starts with its scan share nearly spent can therefore still run a 90 s walk and consume about 38% of the 240 s delete reserve.  That is the livelock this change exists to break, reproduced inside the fix for it.

Direct verification found **eight** scan-phase sites that bypassed the clamp, not the three the review named, plus the four `read_band` probes and the `du` call inside `dir_bytes`.

- `probe_timeout(default)` is now the one door for every subprocess a rule starts, and `_SCAN_PHASE` says which clock it reads.  `scan_op_timeout()` survives only as the scan-side implementation of that door.
- `rule_deadline()` bounds a rule's own wall clock to `min(RULE_BUDGET_SEC, scan_budget_left())`, so the two rules that walk whole trees stop at the share instead of at their own 90 s.
- The flag is a module global, set in `scan()` and cleared in a `finally`, so a rule that raises cannot leave it set.  The test asserts it from outside the function, because a flag assigned without `global` is a local and the report would never learn the truth.
- A source-level test now walks the module and refuses any subprocess timeout that is neither budget-derived nor a bare literal of at most `MIN_HEAVY_START_SEC`, and any use of `RULE_BUDGET_SEC` outside a clamped deadline.  That is the check that finds the next fixed timeout instead of waiting for the next review round to find it.
- Four mutations were checked against the new tests: a fixed 90 s timeout, an unset phase flag, a rule deadline built from the raw `RULE_BUDGET_SEC`, and a `rule_deadline()` that ignores the phase.  Each is caught, and each by the test meant to catch it.  The first version of the source-level test let the third mutation through, because it only looked at subprocess timeouts and not at rule wall clocks; that hole is closed now.

## The sixth review round: a probe that cannot answer is not a marker

Two findings, both real, and the first was the same class of mistake as the fifth: a guard that reports the wrong thing.

**A failed marker probe was reported as a marker.**  `holds_keep_sentinel` collapsed a timeout, an `OSError` and any nonzero `find` exit into "marker present", so the delete refused the tree and the report blamed the operator's marker.  But `find` exits nonzero when it cannot read a subdirectory, and it still prints every marker it did find: the OUTPUT is the answer, not the exit code.  Read the other way, an ordinary unreadable cache directory became a permanent "the operator marked this" block that recurred every run and reclaimed nothing, which is the exact failure this document exists to remove.

Measured on this Mac before anything changed: 1247 real candidate trees were probed, none of them exited nonzero, and the slowest probe took 5.99 s.  So the false positive was latent rather than active, and the report was the plainly wrong part of it.

The probe now answers with three states rather than two: a marker was found, the tree is clean, or the probe could not answer.  A walk that completed with no output is clean even when `find` exited nonzero for an unreadable subdirectory, because those parts are unreadable to the delete as well, so a marker inside one of them survives the delete instead of being taken with it.  A timeout, or a probe that could not run at all, is "unknown", and an unknown tree is never deleted -- but the report says the probe failed rather than that the operator marked it.

**The apply-phase guard could eat the delete reserve.**  The probe walks the same tree the delete walks, so it is a second full walk of it, and it drew `op_timeout(30.0)` from the whole remaining budget.  A handful of heavy candidates could each spend 30 s of the reserve and free nothing.  The probe now gets at most a tenth of what is left of the budget, with a one second floor so it can still answer.

**The second walk is gone.**  The two rules that delete whole trees already probe at scan time, so the verdict is carried on the candidate and the apply phase does not walk the tree again to ask the same question.  A rule that did not probe at scan time still gets the probe at `apply_delete`, the choke point every delete passes through, so the marker contract still covers every rule.

Four mutations were checked against the new tests and each is caught by the test meant to catch it:  the old exit-code reading, the old budget, the walk that was not carried, and the unknown verdict that deleted anyway.

## The seventh review round: a verdict that cannot vouch, and a report that cannot claim

Six findings.  The first was critical, and it was the price of the sixth round's own optimisation: the verdict the scan carries to the apply phase was trusted without a freshness check, so the delete could take a tree together with a marker the operator had dropped into it after the scan.

**A carried verdict has to be re-checked at delete time.**  The scan spends 60% of the budget before the apply phase starts, and the apply queue adds chunk pauses and a band re-read between chunks, so a carried verdict can be fifteen minutes old by the time `find -depth -delete` runs.  The verdict also belongs to an inode: an app that recreates its cache directory between the scan and the delete leaves a verdict that describes a tree that is no longer there.  The carry is kept, because the duplicate walk was measured at up to 5.99 s on one real cache tree, but the verdict now carries the moment it was taken and the directory it was taken against.  `apply_delete` re-probes when the verdict is older than `KEEP_VERDICT_MAX_AGE_SEC` (120 s) or when the inode no longer matches, and a re-probe that cannot answer refuses the delete.  A verdict that is still fresh and still describes the same directory is used as it is, so the walk is saved exactly while the answer is worth trusting.

**A path that is already gone is not a delete.**  `apply_delete` returned `(0, "")` for a path that had disappeared, and the caller read that as success: the candidate was counted as an applied delete and its scan estimate was counted as bytes the run freed, for a path that was never touched.  Before this work the same condition raised `FileNotFoundError` and counted as a failure.  The apply step now has three outcomes -- applied, skipped, failed -- and a vanished path is a skip.  The report counts the three apart, so a skip is never read as "freed" and never as "failed".

**A run with no budget left says so instead of starting work.**  `op_timeout` floors at 5 s, so a candidate started with the budget already spent still cost 5 s each, and the delete's `find -depth -delete` was bounded by that same floor -- a delete cut off mid-walk leaves a half-removed tree.  A candidate with no budget left is now skipped and says so, and the delete is given the budget it actually has (`delete_timeout()`, a 1 s floor) rather than a floor that lets it overrun.  A delete that is cut off mid-walk now reports itself as a partial removal instead of as a path that is merely still present.

**A rejected tree must not pay for the full-tree walk.**  `rule_agent_state` probed for a marker before the cheap `.project_root` and inode filters, and `find -quit` only stops early when the marker is there, so every project working tree under `~/.gemini/tmp` paid for a complete traversal before the filter that discards it.  The probe now runs after the cheap filters, exactly as `rule_app_caches` runs its probe after its policy filter.

**The source-level check was too generous.**  `apply_probe_timeout` reads the whole-run budget, not the phase clock, but it was accepted as one of the budget clocks, so a scan rule could use it and pass the check while spending the reserve the deletes need.  It is out of the clock set now, and a separate check refuses any `apply_probe_timeout` call site outside `apply_delete`.

**The docstring still described a boolean.**  `holds_keep_sentinel` returns a `MarkerVerdict`, and a NamedTuple is always truthy, so `if holds_keep_sentinel(...)` would read every tree as marked and `if not holds_keep_sentinel(...)` would read every tree as clean.  The contract is now stated in the docstring, and the three states are described in the operator-facing bullet above.

Seven mutations were checked against the new tests and each is caught by the test meant to catch it: the stale verdict, the replaced directory, the vanished path counted as a delete, the missing no-budget skip, the probe back in front of the cheap filters, a scan rule using the whole-run clock, and the delete that is not bounded by the budget it has.

## One deliberate divergence from a review suggestion

The suggestion clamped the scan probes to the whole run budget.  That stops a probe outliving the run's hard stop, but not outliving the scan's own 60% share.  The clamp is to the scan share instead, which is always the smaller of the two budgets, so the whole-budget bound still holds on top of it.

## Measured

| | Before | After |
|---|---|---|
| Free space | 3.3 GB | ~46 GB |
| Load average | 611 | ~10 |
| Deleted by the engine | 0 | 6.48 GB across 43 safe-tier candidates, 0 failures |

The agent session transcripts (5.4 GB) are report-only by policy and were left intact.

## Verify

- `python3 scripts/test-hoghunter-clean.py` -> ok (89 tests)
- `python3 scripts/test-robotic-vacuum.py` -> ok (299 tests)
- `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` -> ok

## Still open

- A restart is the biggest remaining win on the host: about 22 GB, which is the 22.2 GB of swap this Mac is carrying.  The 4.05 GB that LaunchServices held open in deleted files was released on its own during the run -- `lsof` now reports zero deleted-but-open handles.  A restart is the owner's call because it kills the running agent sessions.
- `scripts/vacuum/store.py` `_locked_json_update()` still uses a blocking `fcntl.flock(LOCK_EX)` with no timeout.  That is a latent hang hazard and is unchanged here.
- `newest_file_age_min()` is bounded by an entry count (4000) rather than by a wall clock, so on a very slow volume one call can run long.  It starts no subprocess, so it cannot outrun the scan share the way a subprocess could, but it is not on the same clock as the probes around it.
- The open item in `docs/rollouts/2026-10-09-vacuum-full-run-fixes.md` — expand `janitor_cache_reclaim` if janitor parity gaps appear in production — still stands.
