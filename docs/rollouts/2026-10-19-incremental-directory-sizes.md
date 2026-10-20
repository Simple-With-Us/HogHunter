# Incremental Directory Sizes

HH-170 replaces whole-root `du` timeouts with a resumable metadata walk.  A single background executor advances one row at a time in round-robin order, so a large lane tree does not consume every scan slot before small directories get a turn.  No source, lane, or personal data is changed.

Each slice visits at most 256 entries or 40 milliseconds, then yields for 30 milliseconds.  Elevated CPU load, warning memory pressure, or serious thermal pressure reduces that to 32 entries or 10 milliseconds with a 250 millisecond yield.  Critical memory or thermal pressure pauses new work for 15 seconds.  These are internal work budgets, not app settings or a new background job.

`HogStore` owns the directory store for the app's lifetime.  The panel advances work in two-second bursts and resumes unfinished rows promptly.  Completed rows are scheduled on 15-minute slots anchored to their observation's start, rather than 15 minutes after the entire scan finishes; a long scan skips missed slots without overlap.  Switching away from Activity or closing the panel cancels view-triggered work; its current bounded slice may finish and its cursor/result is retained.

A separate weak-self task, started and stopped with `HogStore`, may continue the same cursors while the panel is closed.  It uses the same executor and overlap guard, runs at most a two-second burst, then sleeps at least 15 seconds.  New background I/O is allowed only under normal memory/thermal pressure, with one-minute CPU load below the smaller of 4 and half the logical processor count, and swap use below 90%.  Unknown pressure readings also defer background work.  Deferred rows say they are awaiting an idle Mac, lower CPU load/swap, or readable pressure; the gate does not delay a foreground attempt.  Sampler stop disables both view-triggered and idle work, and cancels the idle task; deinit cancels it as well.  There is no LaunchAgent.

The idle gate is deliberately conservative for an always-active fleet.  A million-entry tree could require hours of accumulated foreground progress at the reduced work budget, and sustained fleet load can defer background completion indefinitely.  The app-lived cursor avoids restarting on each menu opening, but neither aggregate completion on the saturated owner host nor a stable 24-hour cadence for that aggregate has been verified.  This rollout claims bounded progress and honest deferred/cache states, not a measured completion rate or a verified full aggregate.

A filesystem syscall already blocked in the kernel cannot be interrupted safely.  There is at most one such operation, on the background queue; the UI remains responsive and identifies slow disk I/O after one second.  A blocked operation can delay other rows until the kernel returns.  This implementation does not start parallel fallback walks or repeatedly restart the same prefix after a time budget expires.

## Values And Source Times

The primary number is always the last **complete** walk, persisted through `SizeGrowthHistory`.  A separate status suffix reports allocated bytes scanned and entry count while a walk is incomplete.  Partial progress never enters size history or the 24-hour calculation.  Failure, pressure pause, waiting, and cancellation retain the last complete value and explain why the current walk has not finished.

The source timestamp is when the walk began.  The tooltip also gives its finish time when known; these are directory walks over a changing filesystem, not atomic filesystem snapshots.  A completed long walk can still have an old source time; it is not relabeled as a fresh filesystem snapshot merely because it just finished.  A cached value keeps its original timestamp, and a stale baseline does not acquire a fresh timestamp merely because the panel was reopened.  Before publishing a completed walk, the background executor re-resolves its logical root; a retargeted symlink invalidates that completion instead of caching the old target under the changed alias.  A logical alias cache uses the same standardized key for reading and writing and carries its canonical source path, so a retargeted link cannot reuse the former target's value or growth baseline.

Completed values survive app relaunch.  Incomplete cursors survive panel recreation and observer cancellation within the process, but are not serialized; relaunch starts a new walk while displaying the last complete cache.

## Physical Bytes And Linked Lanes

Sizes sum `st_blocks * 512`, matching allocated-block `du` semantics rather than apparent file length.  Sparse files, hard links, directory blocks, and symlink blocks retain those semantics.  This is not an APFS clone-exclusive or purgeable-space estimate.

The root resolves to its physical path with POSIX `realpath` in the background.  Foundation can shorten `/private/tmp` back to the `/tmp` symlink, so the walker retains the POSIX result for its no-follow root checks.  Ordinary child symlinks remain leaves, and normal traversal stays on its root device.  For a logical `lanes` root, explicit links at the first two layout levels may introduce external roots.  Device-aware canonical root partitions deduplicate aliases and overlaps: a newly found parent counts its extra data and skips previously counted child-root boundaries.  An explicitly linked mounted descendant on a different device remains a separate root, since a parent’s same-device walk excludes it.  Links to the base or its ancestors do not expand the walk.

Directory identities are retained only for the current ancestor stack, capped at 64 levels; explicit canonical root partitions are capped at 4,096.  Normal directory/file counts do not grow an identity cache.  Hard-linked files use per-device inode sets with a one-million-identity budget; exhausting that budget or a depth limit fails explicitly and preserves the last complete value.  An unreadable entry also fails the walk instead of publishing a smaller partial result.  Concurrently disappearing entries are skipped only while their opened parent still names the same directory inode.  Parent identity is checked at each resumed slice and before completing a directory stream; a moved or replaced parent invalidates the observation instead of persisting a partial total.  Undecodable entry names fail explicitly rather than substituting bytes and potentially counting a different path.

## Persistence And Verification

History mutation captures an immutable snapshot under the history lock.  One coalescing serial writer encodes and atomically replaces the cache off the caller's actor and outside that lock.  Older writes cannot overtake newer writes; write failure preserves the last good file and the in-memory observations, with the next mutation retrying persistence.  Tests use an explicit flush barrier when they need to reopen the file deterministically.  Application termination also drains queued history before exit so an immediate quit retains the newest completed observations.

Focused fixture tests cover physical-block counting, hard-link deduplication, overlapping lane roots, repository symlink boundaries, fair small-row completion, complete-only history, cancellation/resume, foreground and idle pressure gating, sampler enable/disable, source-aware alias caches, and newest-snapshot persistence.  No test traverses production roots.  Local verification uses targeted Swift parsing/typechecking and a standalone fixture harness; full app/XCTest/CI verification is left to hosted CI because the owner's Mac is under severe load.

## Server Tool State Labels

The tool grid now prints a status beside each dot: running, not running, not found, or unknown.  A gray stopped tool is different from a faint-gray executable that was not found in the checked locations; neither color alone should imply installation status.  Hover text and accessibility labels use the same readable state.  The broader independent HH-174 navigation study remains a proposal; the owner-requested Server layout below is implemented in this change.

## Compact Server Layout And Daily Changes

At the default 680 by 720 point panel size, Server uses a three-column, two-row metrics grid above two balanced columns.  Databases and the two-column tool grid occupy the left column; all significant directories remain visible in the right column.  The Server container no longer scrolls.  Refresh, snapshot age, error states, tool counts, and all metric details remain available.

A standalone render of the actual views with six metrics, three databases, thirteen directories, twelve tools, all four tool states, and populated daily changes measures 652 by 523 points naturally.  The regression fixture asserts natural report height no greater than 580 points at the panel's inner width and saves an image; it does not force a height that could hide overflow.

Directory and database changes have no parentheses.  The shared row colors growth red and decreases green while retaining the arrow, signed decreases, significant-digit rounding, and two-space gaps.  The suffix is black `∕d`, using U+2215 and a four-point-smaller `d`.  Unknown history stays a dash instead of an invented change.  CPU and memory do not gain daily percentage deltas.
