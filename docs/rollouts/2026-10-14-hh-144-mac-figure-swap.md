# Mac Panel Swaps Figures With the Sort (2026-10-14)

Board `b3c63f90`.  Issue HH-144.  Follow-up to HH-143.

## What Was Wrong

The owner reported the Mac main window never shows the RAM amount large: toggling the sort to Memory reorders the rows, but the large right-side figure stays %CPU, and the big number only changes because a different process is now on top.  HH-143 fixed the iPhone rows and wrongly claimed the Mac panel already swapped.  It did not: `HogRowView` took no sort parameter and always rendered %CPU large with memory small, and the panel never passed `store.sort`.  The earlier verification read a memory of the code, not the code.

## What Changed

| Where | Change |
|---|---|
| `Sources/UI/RowView.swift`, `Sources/UI/HogHunterPanel.swift` | No change on this branch.  The fix was written here first (a `sort: HogSort` parameter on `HogRowView`, passed `store.sort` by the row list), then the panel overhaul (#158) reached `main` with the same row change.  The two were identical in the `body`, so the merge keeps `main`'s version: `HogRowView` has `var sort: HogSort = .cpu`, and the panel passes `sort: store.sort` after `store:`.  Sorting by Memory puts the RAM amount on top in the large semibold style (neutral primary, since rows carry no memory severity) with %CPU small beneath it; sorting by CPU keeps the severity color on the large %CPU. |
| `CHANGELOG.md`, `docs/rollouts/2026-10-14-hh-143-owner-batch.md` | The HH-143 entries that claimed the Mac already swapped now say it did not, and point at HH-144.  The changelog also records that the swap reached `main` in #158. |

## Verification

Run on the merged tree (this branch after merging `origin/main`, code identical to `main`), 2026-10-16.

| Command | Result |
|---|---|
| `xcodegen generate` | Passed (project created) |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""` (Debug build plus the full XCTest suite) | `** TEST SUCCEEDED **`, 632 tests, 0 failures |
| `DiskCleanerTests.testScanAPFSSnapshotsFallsBackToAggregateWhenListFails` (the APFS-snapshot test the review named) | Passed in the same run |

No new test: figure prominence is layout, and the repo has no view-inspection harness.  The wiring (`store.sort` into every row, the panel already observing it for the sort picker) was read in the merged files, not remembered.  The order itself already sorted correctly and is untouched.  The CI `Headless UI smoke test` step builds and drives the real views on the PR.

## Next

- Real-Mac visual confirmation is not captured.  CI has no screenshot of the main window and the owner does not run local UI previews, so per `AGENTS.md` this stays a code-review and CI check (the headless UI smoke step) until a view-inspection harness exists.
- No follow-up code work is open for this issue.  If an APFS-snapshot test in `DiskCleanerTests` fails on a host with real snapshots, that belongs to the cleaner and is unrelated to this row change.
