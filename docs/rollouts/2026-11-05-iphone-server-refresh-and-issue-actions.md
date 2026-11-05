# iPhone Server Refresh and Flagged Issue Actions

Linear HH-218, following the Server tab (PRs #266 and #267).

## What Changed

Two gaps between the phone and the Mac are closed.

**A forced server refresh.**  The Mac's server card has a Refresh button that calls `VPSStatusStore.fetch(force: true)`.  The phone could only read the Mac's cached reading, which the Mac renews once a minute.  A new route, `POST /v1/server/refresh`, asks the Mac for the same forced read.  The Server tab has a Refresh Server Reading button under the state row, and pulling the list down on the Server tab does the same.  The Mac answers at once with `started`, and the phone polls the snapshot again a few seconds later to pick up the new reading.  On the other tabs a pull re-polls the snapshot only.

**Flagged Issue buttons.**  The Mac's Flagged Issues have Clean, Quit and Retry buttons.  `CompanionServerStatusBuilder.issues` used to drop them.  A Flagged Issue now carries an optional `action` (`clean`, `quit` or `retry`) as a plain string, so an older phone still decodes the snapshot and a kind a later Mac adds shows no button on this phone.  Each kind maps to something the phone already has:

- Retry is the new server refresh.
- Quit opens the phone's existing quit confirmation for the row the issue names.  The phone finds the row by matching `CompanionFlaggedIssue.quitIssueID(forRow:)` against the issue id, which the evaluator now builds with the same helper, so no new field is needed.  The quit route addresses the row id and re-checks each process's start time, as before.
- Clean opens the phone's existing Disk Cleaner screen.

## Safeguards

- The refresh route needs Allow iPhone to See Server Status, off by default and set in Settings only.  It reads and changes nothing on the server, so it does not need Allow iPhone to Control the Server.
- It needs a phone's own token, and the peer must be on the local network or Tailscale, the same gate as the detailed snapshot that carries the server block.  The shared pairing code and an outside address are refused before the handler runs.
- It takes no query and no body.  Either is 400, so no request can name a host, a path or a command.
- One forced read per 15 seconds from every phone together (`CompanionServerRefresh.minimumInterval`).  A sooner request is 429 with a `Retry-After` header and a `retryAfter` field.  Only an accepted refresh starts the interval.
- The reply carries a status and a sentence.  No path, pid, argv, host or credential is new on the wire.  The Mac's log records the device name and the outcome through `CompanionServerActions.audit`.
- A refresh needs no confirmation on the phone, because it changes nothing.  The route table in `AGENTS.md` says so, as the one exception to the rule that the phone confirms each action.
- The Mac sends an issue's `action` only while the matching opt-in is on: Allow iPhone to Quit or Tame Apps & Processes for Quit, Allow iPhone to Run Disk Cleaner for Clean, and Allow iPhone to See Server Status for Retry.  The phone shows the button only when the same opt-in is on in the snapshot and the link is one the Mac takes controls on.
- No new mutation route.  Quit and Clean reach the Mac through the routes and confirmations they always used.

## No New Server Tool

The refresh is the Mac's existing read of the server's status snapshot, over the same SSH fetcher the Mac's own poll uses.  Nothing on the server was added or deployed.  `scripts/server-status/control.py` already covers every server action the phone can take, and this change adds none.

## Tests

`Tests/HogHunterTests/CompanionServerRefreshTests.swift`:

- Each gate refuses: the opt-in off, the shared code, an outside peer, a wrong token, a GET, a body or a query, and a second refresh inside 15 seconds (429 with `Retry-After`), including from a second phone.
- A refresh forces a read through `VPSStatusStore`'s injected fetcher, after showing an ordinary fetch inside the minute is skipped.  No test runs SSH.
- The action kinds map correctly, each is absent when its own opt-in is off, a button on the wrong host does not map, and an unknown kind decodes with no button.

## Not Verified

- The phone's button, pull to refresh and the issue buttons have not been tried on a device against a live Mac.  This Mac has no iOS simulator runtime, so the iOS target was only compiled here.
- The new screenshot frame, `issue-actions` (`-HogHunterIssueActions`), comes from CI's `app-screenshots` artifact as `ios/extra_issue-actions.png`.  It uses demo issues added only for that flag, so the other frames are unchanged.
