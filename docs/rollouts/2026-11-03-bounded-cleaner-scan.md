# Bounded Disk Cleaner Scans And Available-Space Reporting

HH-202 replaces open-ended native cleaner discovery with finite cooperative work and incremental category results.  The cleanup summary distinguishes estimated item bytes moved or removed from the signed available-space change observed during the run.

## Scan Limits

| Mode | Scan Time Budget | Scan Entries | Per-Target Time Budget | Directory Depth |
| --- | --- | --- | --- | --- |
| Quick (default) | 8 seconds | 30,000 | 150 milliseconds | 10 |
| Scan Deeper (explicit) | 45 seconds | 150,000 | 800 milliseconds | 32 |

A target also caps entries at 25,000, counting directories as well as files.  Budgets and cancellation are checked between filesystem operations; a blocked kernel call can exceed these times.  These are cooperative budgets, never a hard deadline guarantee.

Each finished category publishes a provisional report while discovery continues.  Cancelling an in-flight scan discards its provisional report and selections, including when the view disappears.  Cleaning refuses a provisional report; default selections are established from the final report.  A final partial report remains reviewable and says that sizes are lower bounds and locations remain unmeasured.  Scan Deeper restarts discovery with larger limits; it does not claim to resume a cursor or guarantee completeness.

Directory stats now enforce depth, count empty directories as work, traverse package contents when measuring a target, and mark access/enumeration failures as incomplete.  Incomplete stats always have an unknown last-modified date and cannot establish age eligibility.  Age-filtered AI suggestions are omitted when measurement is incomplete.  An incomplete installed-app inventory cannot establish an orphan, and incomplete simulator sizes retain device identity so the primary simulator is not inferred from a truncated subset.  Cleaning refuses an incomplete simulator identity inventory, including an unreadable or unidentified device runtime.  Identity enumeration is separate from size measurement, so a partially measured primary device remains protected without blocking other devices from an explicit clean.

The scan captures mount names once, reuses the HH-200 automatic canonical-path preflight before metadata/enumeration, and measures an allowed alias through its resolved target.  External or network destinations remain excluded from automatic cleaner discovery.  The separate explicit directory Measure Now contract is unchanged.  Memoization lasts for one scan only; a root modification time never reuses a prior scan's size.

## Automatic Runs And Child Commands

Automatic discovery excludes categories outside the enabled rules before scanning and uses the bounded deeper budget.  If discovery is incomplete, known eligible items may still be cleaned, but the run records its partial state and leaves the completed-run clock unchanged; the next scheduled check retries rather than delaying unseen categories by a full interval.

Read-only snapshot-listing and worktree-listing commands have a one-second child deadline, cancellation checks, and TERM/KILL fallback.  File-backed output avoids pipe deadlocks, and oversized or failed command output is unknown rather than a complete inventory.  Snapshot creation and thinning retain their separate cleanup semantics.  Synthetic snapshot rows bypass filesystem-path existence checks because their identifiers are not real directories.

## Cleanup Accounting

The existing `bytesReclaimed` field remains compatible with consumers and cleanup history, but means estimated allocated item bytes successfully moved or removed.  It does not measure newly free blocks.  Child-only symlink and simulator cleaning credits only children successfully moved rather than the entire selected parent's estimate.  A moved child link receives zero estimated bytes, since moving the link leaves its target tree untouched.

`CleanResult.observedFreeBytesChange` records an optional signed startup-volume available-space difference, using the same important-usage capacity metric as the Storage card.  A negative change remains negative, and an unavailable reading stays unknown.  Concurrent writes and changes in purgeable capacity affect the observation, so it is not attributed entirely to this cleanup.

The Mac completion panel labels moved/removed estimates and observed available-space changes separately.  It explains that Trash and APFS snapshots can retain blocks, and the volume gauge no longer adds selected item bytes to free space as a promised result.  No new automatic Trash emptying or undo-snapshot deletion is introduced.  Companion JSON keys and cleanup permissions are unchanged; these native report/result types are Sendable, not Codable wire payloads.

## Verification

Focused XCTest fixtures cover provisional report cancellation, partial simulator cleaning, nested-link accounting, partial-regimen retry, child-command deadlines, synthetic snapshots, depth and directory-entry caps, package contents, target and global deadlines, incremental reports, external mount aliases, internal aliases, cancellation, partial-age eligibility, primary simulator identity, per-scan cache lifetime, and signed free-space observations.  The isolated fixture compiles the real cleaner, directory walker, keep sentinel, and temp safety policy with inert app-inventory/capacity stubs; it never scans the real home or invokes cleanup commands.

The exact-source isolated fixture passed all 23 XCTest cases with zero failures; store/view Swift parsing and the diff check also passed.  Native UI integration and the complete app test suite remain CI checks.  No app was installed or quit, and no system cleanup ran during this work.


## Companion Parity

The existing phone cleaner opt-in and device-token checks also gate `depth=deeper` on `POST /v1/clean/scan`; omitted depth keeps the quick scan.  Unknown, empty or repeated depths are refused, and direct store requests validate depth before starting work.  The scanner still accepts no phone-supplied filesystem path or category scope.

The report adds optional `isPartial`, `incompleteCategories` and `scanDepth` fields; older payloads remain readable.  Partial totals carry lower-bound text and the iPhone offers Scan Deeper.  The response and final progress add optional signed `observedFreeBytesChange`, separate from the legacy estimated item-byte fields; iPhone copy labels the estimate and observed change separately.  No new cleanup permission, automatic Trash removal, snapshot removal or secret is introduced.

Shared companion snapshot/HTTP/peer sources passed standalone typechecking, all changed phone/store sources passed parsing, and new app-module tests cover legacy decoding, signed observations, partial/deeper propagation and existing device-token authorization.  Complete native tests, iOS compilation and UI verification remain required CI/delivery checks.
