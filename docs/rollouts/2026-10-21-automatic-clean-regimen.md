# Automatic clean regimen, wired (2026-10-21)

Linear HH-183.  PR #208.  Swift and Python, no LaunchAgent, plist or bundle-id change.

## What changed

`CleanRegimenRunner` was fully built and never instantiated, so the regimen's schedule never started.  `HogStore.start()` now starts `CleanRegimenRunner.shared` beside the bandwidth monitor, and the storage panel gets the owner's controls: a toggle, a 1, 4, 12 or 24 hour interval, and Run Now.  The regimen is off by default, and turning it on schedules the first run one interval out.

An unattended run gets no extra authority.  It takes the same `.janitor-keep` markers, the same lock and the same refusals the Python engine does:

- `HousekeeperLock` is the mkdir lock from `scripts/vacuum/lock.py` (120 minute stale window, `HOUSEKEEPER_LOCK_OWNER=1` re-entrancy), so the in-app regimen and the Python reclaim ticks never delete at the same time.
- `KeepSentinel` asks the two questions the Python engine asks.  `isKept` finds a marker on a path or any parent of it.  `containsMarker` finds a marker anywhere inside a tree, which matters because the cleaner deletes whole trees and would take the marker with them.  `DiskCleaner.isHandsOff` asks both, at the scan, at the clean, and in `isSafeToDelete`, the choke point every delete passes through.  A symlink item has its target's children trashed, so the inside question is asked of the resolved target.
- The cleaner refuses a path on an external volume, and refuses `~/apps/lanes` by name, because that tree resolves to the internal disk when the external volume is unmounted.

A scheduled run honors the regimen's own conditions.  `requireIdleMinutes` (30 by default) holds a due run until the Mac has had no keyboard or mouse input for that long, and `requireUserPresent` holds it until the panel is open.  The panel says which one is holding it.  Run Now is a person asking, so it skips both.

A run takes one APFS safety snapshot, with its first chunk, not one per chunk.  If that snapshot cannot be made the run stops, because an unattended delete with no rollback point is not recoverable.  A cancelled run (the app quitting, or the schedule stopped) does not start the interval's clock either.  The runner is process-wide, so `HogStore` holds it by count and the last holder to let go stops it.

A run that steps aside because a build is running or another cleanup holds the lock did not happen, so it does not start the interval's clock.  The runner leaves the stored last run alone and the next 15 minute check retries; the panel shows that retry time.  A run that decided something, including "no rules enabled" and "nothing reclaimable", is a run and starts the clock.

## What the marker walk does not do

`KeepSentinel.containsMarker` is bounded (6 levels, 2,000 entries) and answers "no marker found in what was read" when it hits the bound, the same way it treats an unreadable part of a tree.  The Python engine has no entry cap: it walks the whole tree under a time budget and treats a timeout as "do not delete".  The Swift walk deliberately does not fail closed at the bound, because a tree with more than 2,000 entries is the normal state of an Xcode or package cache, and refusing every such tree would stop both the regimen and a manual clean from ever reclaiming the biggest caches.  A marker in a tree deeper or larger than the bound is therefore not seen.  The right shape is the Python one, a complete walk with a time budget that fails closed on timeout, and it needs a budget shared with the scan.

The stale-lock takeover in `HousekeeperLock` moves the stale directory aside atomically, so two Swift callers cannot both remove and recreate it.  The Python lock (`scripts/vacuum/lock.py`) and `mac-auto-cleanup.sh` still remove and recreate it in two steps, so a takeover that races one of them is narrowed and not closed.

## The controls stay on the Mac

Owner ruling 2026-10-09 is that the iPhone app reaches parity with the desktop app, mutations included.  The automatic clean controls are deliberately not on the phone in this change, and no route, snapshot field or iOS view was added.

- A phone that could turn the regimen on, or change how often it runs, could schedule recurring deletes on the Mac.  That is a wider power than any phone route has today (`POST /v1/clean` runs one confirmed clean).  It needs its own opt-in in Mac Settings > iPhone, a row in the route table in `AGENTS.md`, a confirmation on the phone and a place in `docs/rollouts/2026-10-09-phone-parity-batch-2.md`, and those belong in a change of their own.
- The phone-side change touches the iOS native tree, and a merge that touches it ships a TestFlight build.

So the regimen is Mac-only for now, on purpose, the same way snapshot thinning is.  Phone parity for the toggle and the interval is a follow-up, and it starts from the table in `AGENTS.md`.
