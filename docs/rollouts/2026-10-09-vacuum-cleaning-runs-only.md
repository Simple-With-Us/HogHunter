# Robotic Vacuum Recent Runs: Cleaning Runs Only (2026-10-09)

Board `f13bbbe7`.  Issue #115.  Follows `docs/rollouts/2026-10-09-vacuum-recent-runs.md` (board `5acbcff4`) and the partial outcome from `docs/rollouts/2026-10-09-vacuum-full-run-fixes.md` (board `4ea933f0`).

## What Was Wrong

The engine ticks every five minutes ("watch"), so the 20 newest runs cover about 100 minutes.  A janitor run (every 30 minutes) or a full run (every four hours) fell off the Mac's list and the phone's within hours, and the owner saw disk checks instead of cleaning.  Two more gaps:

- A run where one step failed and another did its work is `partial`, and it exits 0.  The phone marked only a non-zero exit, so a partial run showed no mark.  The Mac's list showed no mark of any kind, not even for a failed run.
- `RoboticVacuumStore` read the newest 30 rows of the engine's history.  About 25 of every 30 rows are checks, so filtering them out of 30 rows would have left a handful of cleaning runs.

## What Changed

| Where | Change |
|---|---|
| `Sources/Storage/RoboticVacuumModels.swift` | `RoboticVacuumRun` decodes the engine's `outcome` (optional: 25 of 35 rows on the author's Mac predate it, and the store reads each row with `try?`, so a required field would have dropped them).  New helpers say which runs are cleaning runs (`isCleaningRun`), which are checks (`isCheck`), and the run's resolved outcome. |
| `Sources/Companion/CompanionSnapshot.swift` (compiled into the Mac, the phone and the widgets) | `CompanionVacuumRunResult` is the one rule for the mark: a non-zero exit is failed, otherwise the recorded outcome decides (`partial`, `failed`), and anything else is ok.  `CompanionVacuumRun` gains an optional `outcome`.  `CompanionVacuumWatch` (new, every field defaulted) carries the last check, the checks today, and `countedSince`.  `CompanionVacuumStatus` gains `watch` and a `cleaningRuns` view of `recentRuns`. |
| `Sources/Companion/CompanionVacuum.swift` | `recentRuns` is the newest 20 cleaning runs, each with its resolved outcome.  `watch` counts the checks.  The headline last run uses the same rule as the list. |
| `Sources/Storage/RoboticVacuumStore.swift` | Reads up to 600 history rows (the engine keeps 500) instead of 30. |
| `Sources/UI/RoboticVacuumView.swift` | The Mac's Recent Runs lists the same 20 cleaning runs through the same function, with a Failed (red) or Partial (orange) mark, and the watch summary line above them.  Headings are Title Case and the one ASCII-space gap in the header is now a non-breaking space. |
| `ios/Sources/CompanionVacuumView.swift` | The phone shows the watch summary line above its list, reads the list through `cleaningRuns` (so an older Mac that still sends watch ticks reads the same), marks Failed and Partial, and says "No cleaning runs recorded yet" when the list is empty. |
| `ios/Sources/CompanionModel.swift` | Demo and screenshot data: cleaning runs only, one partial and one failed, with a watch summary. |
| `scripts/vacuum/config.py`, `config/robotic-vacuum.json` | `history_max_runs` 200 to 500.  Every run is a record, so 200 held about 14 hours and the count could not honestly say "today". |

The line reads "Last check 5:40pm · 23 checks today": 12-hour time, lower-case am or pm, no zone, whatever the phone's own clock setting is.  A check from an earlier day says "yesterday 11:55pm" or "Oct 6 2:05pm".  The Mac decides what "today" is (its midnight) and sends the count, so the phone and the Mac agree.

## Decisions, On Purpose

1. **A watch tick that went on to clean is a cleaning run.**  The engine records a pressure clean inside the watch tick that asked for it, under trigger `watch`, with the clean's steps added.  On the author's Mac, 7 of the 20 ticks on Oct 9 did that (6 failed, 1 worked).  Filtering on the trigger alone would have hidden exactly the runs the owner wants to see.  So a "check" is a watch tick whose steps are only the disk and memory check (or nothing recorded), and anything else is a cleaning run.  The list and the headline label such a tick "Pressure", which is what its steps ran as.  It also counts toward the check total, because it did take its look first.  A tick that found the lock held is neither (the engine does not count it as a tick either).
2. **"Today" is only said when it is true.**  If the history does not reach back to the Mac's midnight (a long day on an engine that keeps fewer runs, or a Mac that has not yet updated), the count would be low.  `countedSince` is set and the line reads "23 checks since 7:29am".
3. **The mark follows the recorded outcome, not the exit code.**  A non-zero exit is still always Failed, as in the engine.  An older history row has no outcome and is judged by its exit code, as the engine's own reader does.  An older Mac sends no `outcome`, so the phone judges by exit code and cannot show Partial for that Mac.
4. **`CompanionVacuumRun.succeeded` now means "nothing to flag"**, so a partial run is not "succeeded".  Its only caller was the Failed mark.
5. **The footer on the phone** says what Partial means and, while the summary line is on screen, why the checks are not listed.

## Disclosure

`outcome` is one of three words and `watch` is a time and a count.  Neither carries step text, so both travel in the plain snapshot that the shared pairing code can read.  `vacuum.steps` is still behind Allow iPhone to Run Robotic Vacuum.  A test pins that a reason naming a lane folder reaches neither the plain snapshot nor the summary.

## Compatibility

Every new field is optional on the wire and decodes with a default.  An older Mac sends no `outcome` and no `watch`: the phone filters the watch ticks out of that Mac's list itself, shows no summary line, and judges each run by its exit code.  An older phone ignores the new fields; it reads the new, shorter list and has no Partial mark.

## Where Each Half Takes Effect

| Half | Needs |
|---|---|
| The Mac's list, the summary line, the payload | `scripts/install.sh` on the Mac |
| The phone's list and mark | A new phone build |
| History reaching back to midnight | The integration checkout on this change, so the next tick runs with `history_max_runs` 500.  The file then fills toward 500 rows over about a day and a half.  Until a row older than midnight is on record (on a Mac whose history began today, until the first midnight passes) the line says "since" |

## Not Done

| Item | Note |
|---|---|
| Run details | Tapping a run for its steps would put step text behind a per-run request.  Not built. |
| `build_status` health and Run Now | A partial run still leaves health "healthy" and Run Now still reads "did not finish cleanly" only on a non-zero exit.  The row's Partial mark is the visible signal. |
| Lock-skipped janitor and full runs | A janitor or full run that found the lock held is still listed, as it was, with "Nothing freed". |
| Python tag on an escalated tick | The engine could set `pressure` on the tick record.  The Swift side infers it from the steps instead, so it works on every row already on disk. |

## Verification

See the PR description for the commands and results.

## Rollback

Revert the PR.  The snapshot loses `watch` and `outcome`, the lists go back to showing every run, and `history_max_runs` goes back to 200.
