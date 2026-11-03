# Bounded Maintenance And Truthful Progress

Fixes HH-196.

## Observed Problem

An October 30 pressure pass took 829 seconds and reclaimed 13.2 GB; that was useful work, not a proven hang.  A later long tick and legacy lock holder delayed manual cleanup.  Lock contention was recorded as `ok`, and the Mac discarded the status file's `partial_run` field.

## Changes

- A shared monotonic soft deadline derives from the 900-second watchdog with a 120-second reserve.  Nested watch-to-pressure work shares that deadline; independent runs receive a new deadline.
- Lane doctor and process probes clamp timeouts to remaining time.  Incremental directory enumeration checks time between entries rather than collecting an entire directory first.  Failed sizing no longer falls back to an unbounded recursive walk.
- Dependency deletion uses descriptor-relative traversal without following symlinks, checks the deadline between filesystem calls, and checkpoints completed unlink bytes and the current step/target.  Existing idle, clean-tree, open-handle, keep-marker and containment safeguards remain.
- Engine subprocesses run in owned process groups.  Spawn and registration serialize with watchdog shutdown, and the lock's inner child barrier drains live or unknown descendants before normal release.  Zombie-only process groups cannot write and are treated as stopped.
- On a hard watchdog exit, children are stopped first and the valid owner record stays until the parent actually dies.  The next reader can recover a dead-PID owner immediately; releasing before process death would permit the main thread to continue deleting after a peer acquired the lock.
- Lock contention has a neutral `skipped` outcome and does not replace the latest completed cadence.  A skipped peer cannot clear or hide the actual holder's checkpoint.  Normal completion clears only its own run's checkpoint.
- The Mac decodes and shows incomplete recorded progress without claiming the run is still active.  Detailed checkpoint paths remain Mac-only; no new plain companion snapshot fields were added.  Mac and iPhone run rows support the neutral outcome.
- Python and Swift readers apply the acquisition-time PID-reuse check even when start tokens match exactly, and agree with the merged AFC-582 readers on impossible timezone offsets and invalid acquisition metadata.  Writers retain the existing local C-locale token during the reader-first rollout.

## Verification

Hermetic tests use temporary homes, injected clocks and synthetic processes, never a real cleaner.  Coverage includes deadline expiry within a wide directory, dependency deletion progress, symlink protection, scope sharing, shutdown spawn refusal, child/grandchild cleanup, peer checkpoint preservation, legacy skipped records, PID reuse and hard-exit owner recovery.

The lane suite passed 198 tests before the final process-runner migration; its affected lane/budget subset passed 39 afterward.  The non-lane suite passed 204 tests.  Targeted Swift lock/outcome tests passed; current-head CI is the final source qualification gate.

## Operational Limits And Rollout

A cooperative check cannot interrupt an individual kernel filesystem call.  If child liveness cannot be established, serialization stays held rather than permitting overlapping deletion.  Do not infer physical APFS savings from summed logical file sizes.

Merge and deployed behavior are separate.  Check the installed job's actual source, the two AFC helper copies and the signed app before calling rollout complete.  No cadence, retention, snapshot consent, enabled step or user setting changes are part of this fix.  No production service or database is restarted or pruned.
