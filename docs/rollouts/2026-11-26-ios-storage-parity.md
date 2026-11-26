# iOS Display Parity: The Mac's App Storage List and Its All/Running Filter (2026-11-26)

Second half of the owner's 2026-11-26 parity direction.  The server half is PR #401 (server maintenance gate, reclaimable bytes and run history).  This half closes the largest remaining display gap between the phone and the Mac: the Mac's Storage pane has a full installed-app list with an All/Running filter; the phone received the eight largest apps with no running state.

## What changed

- `CompanionAppStorageRow` gains an optional `isRunning`.  Older Macs never send it and their snapshots still decode; nil means the Mac did not say.
- The builder's cached scan now carries 40 rows instead of eight, with each row's running state; the same single background scan and five-minute cache serve it, so the phone's poll stays free.
- iOS Storage > Apps mirrors the Mac's filter: a segmented All / Running control beside the existing sort, an honest empty row when the filter admits nothing ("No running app is in the list"), and footer copy that names the 40-row bound and what Running means.

## What deliberately did not change

Everything that runs on the Mac stays Mac-only: Reveal in Finder, Copy PID, Activity Monitor, the menu-bar toggles, the cleaner's item paging, the maintenance configuration surface, pairing management and updates.  The All/Running filter here filters the rows the Mac chose to send; it adds no route and no new data about the phone's own storage.

## Verification

- Two new tests in `CompanionAppStorageTests`: a row without `isRunning` decodes (older Macs), and a row with it round-trips.
- The companion target builds; the storage test class passes 6/6.
