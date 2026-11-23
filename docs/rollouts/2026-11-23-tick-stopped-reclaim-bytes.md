# A reclaim the tick stopped still freed bytes

Date: Nov 23, 2026
Seat: MM
Repo: HogHunter
Board: HH-235

## What was wrong

The Robotic Vacuum's reclaim step runs `scripts/hoghunter-clean` as a child process and reports what it reclaimed.  The child prints its report when it finishes.  A child the tick's budget killed never got there, and the parent threw the whole step away.

The result was a run that recorded zero bytes on a disk that was visibly full.

Measured on this Mac on Nov 23, 2026, from the Maintain history in `~/Library/Application Support/HogHunter/Maintain/history.json`.  The full trigger at 00:10 ran 818.2 seconds and ended as a partial with zero bytes freed:

```
xcode_derived_data skipped   8.7s
shutdown_simulators skipped 14.5s  skipped: pgrep failed (pgrep timed out after 3s); treated as busy
npm_cache skipped            6.2s  skipped: pgrep failed (pgrep timed out after 3s); treated as busy
pnpm_store skipped           6.8s  skipped: pgrep failed (pgrep timed out after 3s); treated as busy
yarn_cache skipped           6.7s  skipped: pgrep failed (pgrep timed out after 3s); treated as busy
brew_cleanup skipped          7.0s  skipped: pgrep failed (pgrep timed out after 3s); treated as busy
hoghunter_reclaim failed   748.5s  maintenance work budget exhausted
cleanmymac_cli failed        0.0s  maintenance work budget exhausted; step not started
```

Two things were wrong with that.

The first was the report.  The reclaim step had no way to say what the child had done, because the child had not printed its report, and the parent had nothing else to go on.  It recorded zero.  The disk may have given back gigabytes during those 748 seconds and the run said nothing had been freed.

The second was the output.  The parent's own code called `work.check()` after the child was reaped, and that call raised `BudgetExceeded` instead of returning.  The raise propagated out of the step, and the step was recorded as a failure with zero bytes.  The partial output the child had printed was discarded with it.

The janitor trigger showed the same shape.  Its reclaim step reported `band=cheap: removed 0 of 0 items, 0 B freed, the host used 203.8 MB while the run worked` on a volume that had 51 GiB of abandoned Xcode DerivedData under `/private/tmp`.

## What changed

`scripts/vacuum/engine.py` gains three changes.

`_disk_free_bytes()` measures the free bytes on the data volume with `os.statvfs`, and `VacuumEngine` takes an injectable `disk_free` so a test can drive the measurement instead of reading the host's real disk.

`_run_in_own_group` no longer throws a finished child's output away.  When the child completed and printed its report but the tick's deadline passed while the parent was waiting for it, the report is handed back.  The caller's next step sees the spent budget and the tick ends there, with this step's result kept.  The same applies when the child was stopped: the partial output it managed to print is handed back rather than raising past it.

`_hoghunter_reclaim` measures the disk around the child.  A cleaner that reports its own `disk_free_delta_gb` is still preferred, because that is the cleaner's own measurement of the same thing.  The parent's measurement is the witness for the runs that never get to print one.  A cleaner the tick stopped is reported with the bytes the disk actually gained, and the step is marked incomplete so the run is a partial one.

## What did not change

The budget numbers are the same.  `_RECLAIM_BUDGET_SECONDS`, `_RECLAIM_GRACE_SECONDS` and `_RECLAIM_RESERVE_SECONDS` still come from the 900 second watchdog, and the reclaim still gets a hard stop below it.

No rule was added, removed or widened, and no simulator path was touched.  The reclaim still deletes only what its own rules allow it to delete.

The negative case is unchanged in meaning and changed only in shape.  The host can write more while a reclaim works, so the net change in free space can be negative.  The measured bytes are floored at zero, so the panel never shows `reclaimed -51.2 MB`.

## Verification

`scripts/test-robotic-vacuum.py` passes 485 of 485, including five new tests.

- A cleaner the tick stopped reports the bytes the disk actually gained.
- A cleaner the tick stopped never reports a negative number.
- A cleaner the tick stopped is marked incomplete, so the run is a partial one.
- The disk measurement is injectable, so a test cannot be made flaky by the host writing to its own disk.
- A child the tick stopped keeps the output it printed, instead of the step being thrown away.

`scripts/test-hoghunter-clean.py` passes 246 of 246, and the four `scripts/server-status` suites pass.

## What this does not cover

The tick still has to fit inside the watchdog.  The janitor's `janitor_worktree_retire` step is the lane doctor, a read-only inventory that measured 377 to 518 seconds across hundreds of lanes on the external volume, and it ends as skipped with no lanes eligible.  A janitor tick measured at 619.5 seconds was zero bytes as well.  That step is not part of this change; it is board HH-235's other half and it wants the doctor's report cached across ticks rather than recomputed.

The reclaim step also reports `skipped: pgrep failed (pgrep timed out after 3s); treated as busy` on a loaded host.  A pgrep that never returns is a busy host, not a busy app, and the difference matters when the host is the reason nothing is being cleaned.
