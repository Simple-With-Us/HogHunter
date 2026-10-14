# Mac Panel Swaps Figures With the Sort (2026-10-14)

Board `b3c63f90`.  Issue HH-144.  Follow-up to HH-143.

## What Was Wrong

The owner reported the Mac main window never shows the RAM amount large: toggling the sort to Memory reorders the rows, but the large right-side figure stays %CPU, and the big number only changes because a different process is now on top.  HH-143 fixed the iPhone rows and wrongly claimed the Mac panel already swapped.  It did not: `HogRowView` took no sort parameter and always rendered %CPU large with memory small, and the panel never passed `store.sort`.  The earlier verification read a memory of the code, not the code.

## What Changed

| Where | Change |
|---|---|
| `Sources/UI/RowView.swift` | `HogRowView` gains `sort: HogSort`.  Sorting by Memory puts the RAM amount on top in the large semibold style with %CPU small beneath it; sorting by CPU keeps the existing layout, including the severity color on the large %CPU.  The large memory figure stays neutral primary: rows carry no memory severity, and the phone does the same. |
| `Sources/UI/HogHunterPanel.swift` | The row list passes `sort: store.sort`, so toggling the sort re-renders every row's figures at once. |
| `CHANGELOG.md`, `docs/rollouts/2026-10-14-hh-143-owner-batch.md` | The HH-143 entries that claimed the Mac already swapped now point at HH-144. |

## Verification

Mac Debug build plus the full XCTest suite (CI runs both on the PR).  No new test: figure prominence is layout, and the repo has no view-inspection harness; the wiring (`store.sort` into every row, panel already observing it for the sort picker) is reviewed line by line.  The order itself already sorted correctly and is untouched.
