# Robotic Vacuum Recent Runs On The iPhone

Board `5acbcff4`.  Issue #110.  Owner ruling 2026-10-09: the phone matches the Mac as closely as possible.

## What Was Wrong

The phone got one run, and it was nearly always the wrong one.  The engine ticks every five minutes ("watch"), with a janitor run every 30 minutes and a full run every four hours.  `build_status` takes the status file's `last_run` and `step_last_results` from the last history record, so the last run is almost always a watch tick whose only step is "Check disk and memory".  The phone's "Last Run Freed", "Last Run Ended" and step list therefore described a disk check.  The Mac's Cleaning steps list read the same `step_last_results` and showed nothing for every step but the disk check.  On a sample day the history held 22 runs: 11 watch, 9 janitor and 2 full.

## What Changed

| Where | Change |
|---|---|
| `scripts/vacuum/scheduler.py` `build_status` | `step_last_results` holds each step's most recent result from any run (history is oldest first, so a newer result replaces an older one).  `last_run`, `health` and `history_count` are untouched.  This is the Mac fix: its Cleaning steps list needs no Swift change. |
| `Sources/Companion/CompanionVacuum.swift` | The run the phone leads with is the newest run whose trigger is not `watch` (so janitor, full, manual and pressure all count), or the newest run of any kind when every run is a watch tick.  The status file's `last_run` is used only when the history cannot be read.  Its own steps feed `steps`, falling back to the status file's step results for a run that recorded none.  `recentRuns` is the newest 20 runs. |
| `Sources/Companion/CompanionSnapshot.swift` | `CompanionVacuumStatus` gains `lastRunTrigger` and `recentRuns`, and `CompanionVacuumRun` is new (run id, trigger, end time, bytes freed, exit code, duration in seconds). |
| `ios/Sources/CompanionVacuumView.swift` | A Last Run row names the kind of run.  A Recent Runs section lists the runs the way the Mac does (kind, what it freed, when it ended), with how long each took and a Failed mark for a non-zero exit.  Watch ticks are listed, as on the Mac. |
| `ios/Sources/CompanionModel.swift` | The demo and `-HogHunterVacuum` screenshot data carries a recent runs list, one run of which failed. |

## Disclosure

A run in the list carries no step text, so `recentRuns` and `lastRunTrigger` travel in the plain snapshot that the shared pairing code can read.  `vacuum.steps` is still behind Allow iPhone to Run Robotic Vacuum and is still cut to 120 characters per reason.  A test pins that a reason naming a lane folder reaches neither the plain snapshot nor the list.

## Compatibility

Both new fields are optional on the wire.  An older Mac sends neither: the phone decodes the snapshot and says that Mac does not share its recent runs (a Mac that sends an empty list reads "No runs recorded yet", the same words the Mac uses).  An older phone ignores both fields.  The headline change is Swift-only, so it needs no matching Python and works against a status file written by the old `build_status`.

## Where Each Half Takes Effect

The Mac app reads the Python's output; the background job runs the Python.  The Robotic Vacuum LaunchAgent runs `scripts/robotic-vacuum.py --tick scheduler` every 300 seconds from the integration checkout of this repo, so the `build_status` change reaches the Mac's Cleaning steps once that checkout is on this change and the next tick publishes `status.json`.  The Swift half (the phone's last run and the list) needs `scripts/install.sh` on the Mac and a new phone build.

## Not Done

| Item | Note |
|---|---|
| Hiding or collapsing watch ticks | The Mac lists every run and so does the phone.  With a five minute watch tick, 20 runs is about 100 minutes of history, so a full run drops off the list within a few hours.  A "Hide Watch Checks" switch on both would fix that; it is a design call for the owner. |
| More than the newest 30 runs | `RoboticVacuumStore` reads the newest 30 of the 200 the engine keeps, so the headline can be a janitor run when the last full run is older than that.  `lastFullRunAt` still comes from the status file. |
| Run details beyond the headline | Tapping a run for its steps would put step text behind a per-run request.  Not built. |

## Verification

| Command | Result |
|---|---|
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` | 527 tests, 1 failure.  The failure is `DiskCleanerTests.testScanAPFSSnapshotsFallsBackToAggregateWhenListFails`, the known Time Machine test that fails on the author's Mac.  The 16 new or changed vacuum tests pass. |
| `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' build` | Passes. |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-robotic-vacuum.py` | 188 tests pass, 4 of them new (`TestStatusStepResults`). |

No simulator run.  The hosted `test` job launches the iOS app with `-HogHunterVacuum` and uploads the frames as the `app-screenshots` artifact; the sample data now carries a recent runs list with one failed run, so that frame shows the new section.  Nothing here touches the release scripts, so the `release-safety` job covers them as before.

## Next Steps

| Step | Who |
|---|---|
| Decide whether the Mac and the phone should hide or collapse watch ticks (a "Hide Watch Checks" switch). | Owner |
| Update the integration checkout and run `scripts/install.sh`, so the Mac gets the Python and Swift halves. | Owner, or any seat the owner asks |
| Ship a new phone build.  It reaches testers only through the guarded TestFlight workflow, which stays disabled until replacement signing credentials are ready (issue #22). | Owner |

## Rollback

Revert the PR.  The snapshot loses the two fields, a phone built with this change shows "does not share its recent runs" for a Mac without them, and `step_last_results` goes back to the last record's steps.
