# Scheduled Regimen Overdue Override (HH-229)

Date: 2026-11-14. Seat: ZC (CC.2.M). Owner direction: Jay asked for aggressive disk reclaim and for Hog Hunter to keep up everyday cleaning autonomously, and to determine why it had not.

## Why the regimen never ran

The regimen was enabled (blob in the group container, 24 h interval) and due every day since Nov 3, and the panel's waiting flag said why: `requireIdleMinutes` is 30 by default, and this Mac under continuous fleet work is never idle for 30 minutes. `tick()` held the run on every 15-minute check, forever. That is the same failure the 2026-10-02 owner ruling removed for load: a guard whose threshold equals the normal state is an outage, not a guard. The installed Nov 3 build also predated launch-at-login, so after a reboot nothing cleaned until someone opened the app.

Measured 2026-11-14: the internal drive fell to 6.8 GB free mid-afternoon; the engine at band=full applied 2 items (~0.29 GB). The sanctioned rules are already picked clean on this host, which is why daily cleaning freed ~0 GB — the remaining mass is ask-first (Trash 26 GB, `.claude/projects` 9 GB, `botfleet-*` trees ~10 GB, `.codex/.tmp` 2.8 GB, DriveFS 3.4 GB), listed in the HH-229 topic for owner decisions.

## The change

`CleanRegimenRunner.overdueOverrideHours` (6 h). A due run whose interval has been owed it for that long stops waiting on the idle hold and starts in the pressured chunk shape (`pressuredTargetsPerChunk`, `pressuredChunkPauseSeconds`, label "Busy (Overdue)"), because the person the idle gate protects is demonstrably there. An explicit `requireUserPresent` stays binding: overdue never outranks an owner instruction. The panel's hold text says when the override would arrive (`blockerText`). Overdue is measured from `dueDate(lastRunAt:regimen:now:)` — last run plus one interval — not from when the hold was last seen.

## What stayed true

Run Now skips the gate as before; a skipped no-op still does not own the interval clock; the snapshot gate and its backoff are untouched; the Trash is still unreachable from a regimen; the enabled rules, not pressure, still decide scope.

## Tests

`CleanRegimenRunnerTests`: an overdue run starts despite the idle gate; a run inside the window keeps waiting and says when the override lands; `requireUserPresent` keeps holding past the override; an overdue run cleans in chunks of `pressuredTargetsPerChunk` with label Busy (Overdue).

## Launch at login

`HogStore.setLoginItem` registers `SMAppService.mainApp`, which is in-process only. Until the owner flips Settings once, launch-at-login is provided by a legacy System Events login item pointing at the installed bundle, recorded in `MAC-LOCAL-PROCESSES.md`; the app's own toggle reads `SMAppService.mainApp.status`, so it shows off while the legacy entry does the work. Deleting the legacy entry after registering in-app avoids two entries.

## Follow-ups left open

- Emptying the Trash (26 GB) is the owner's call; `neverEmptyTrash` keeps the regimen away from it either way.
- The Mac-triggered remote maintenance path fails over SSH (`/etc/cron.daily/coolify-auto-maintenance` exits 126 as a non-root user); the server's own cron still runs it.
- The git relay has no seat policy row for ZC's workflow verbs (`seat_not_in_policy`), so the PR for this branch must be opened once the grant lands or by the owner (see Fleet GitOPS deficiencies, AFC-664).

## The Trash valve (owner direction 2026-11-15)

Jay asked for Hog Hunter to be able to empty the Trash on its own when space runs low, configured in Settings.  The standing `neverEmptyTrash` policy stays for everything else:  `CleanCategory.trash` still answers to no rule, and the valve is its own setting.

- `CleanRegimen.emptyTrashBelowGB` (optional, default nil = off).  At or below the line, a scheduled run's scan includes the Trash and its selected items are cleaned with the run;  above it, the Trash is neither scanned nor cleaned.
- The valve is never a rule mapping and never widens what rules select;  its items ride beside the rule-selected ones.
- `sanitized()` clamps the line to at least 1 GB and disables it on nonsense values, so a corrupt blob cannot turn into a permanent delete.
- Settings UI lives in the Cleaner tab's regimen section:  Empty Trash When Space Is Low, with a threshold picker (15/25/40/60/80 GB free) and a permanence warning.
- Tests:  off-by-default decode, sanitize clamps, valve opens only at/below its line, an open valve empties the Trash even with no rules enabled, a shut valve leaves the Trash unselected.

## Operations recorded with this change (2026-11-14/15, not repo code)

- The operator inventory (`~/.config/fleet/housekeeper.env`) named a non-root SSH login, so the Mac-triggered `/etc/cron.daily/coolify-auto-maintenance` exited 126 (Permission denied on its root-only log and binary).  The alias now names the root login;  the hop was verified end to end (rc 0, `status: skipped, reason: healthy root filesystem`).  Root login needs no sudo;  the non-root login needs `sudo -n` for root-only files.
- Server stats staleness:  the Mac polls the snapshot every 60 s (`VPSStatusStore`), but the snapshot file was only written every 15 minutes by `/etc/cron.d/vps-storage-watch`, so `isStale` (150 s) lit permanently and the Refresh button re-read the same stale file.  The writer was timed at about 5 s, and the cron moved to a one-minute cadence;  verified firing twice within two minutes.
