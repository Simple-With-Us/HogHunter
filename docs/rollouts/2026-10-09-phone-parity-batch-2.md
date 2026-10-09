# Phone parity, batch 2 (2026-10-09)

Board `32919186`.  Issues: #99 (A), #101 (B), #102 (C).  PRs: A #100 (this doc starts here), B (disk cleaner), C #103 (Robotic Vacuum).

## Ruling

Same as batch 1 (`docs/rollouts/2026-10-09-phone-parity-batch-1.md`): on 2026-10-09 the owner ruled that the iPhone app reaches parity with the desktop app, mutations included.  Batch 1 fixed the broken controls and built the safeguards (per-phone tokens, the 401 throttle, controls only from the local network or Tailscale, the edit opt-in).  Batch 2 adds the desktop features the phone still lacks.  Every new mutation goes through those safeguards, sits behind an opt-in that is off by default, and gets a confirmation on the phone when it is destructive.

Mac-only by design, and staying that way: the Infisical credential and sync, the pairing and remote-control toggles themselves, Reveal in Finder, and Open Activity Monitor.

## PR A: scale, network, sparkline, settings, sample

| Feature | Where it lives | Gate |
|---|---|---|
| CPU scale picker (Per Core, Per Machine) | `POST /v1/view` (`cpuScale`, already accepted); the Activity tab | Allow iPhone to Change Exclusions & View |
| Network bandwidth and 24-hour peak | `bandwidth` in the snapshot; the Network tab | read-only, like the snapshot |
| CPU sparkline | `cpuHistory` in the snapshot (last 30 readings); the CPU card | read-only |
| Mac Settings: refresh interval, alerts on or off, CPU threshold, sustained minutes, webhook, Send Test Webhook | `settings` in the snapshot, `POST /v1/settings`; the sliders button on the dashboard | Allow iPhone to Change Exclusions & View |
| Sample for 3 Seconds | `POST /v1/sample?row=<id>`; a row's long-press menu | Allow iPhone to Quit or Tame Apps & Processes |

### Routes

| Route | Credential | Opt-in | Peer must be | Notes |
|---|---|---|---|---|
| `POST /v1/settings` | a phone's own token | Allow iPhone to Change Exclusions & View | local network or Tailscale | JSON body.  Each field optional.  The Mac checks every value and applies none of a request with a bad field. |
| `POST /v1/sample` | a phone's own token | Allow iPhone to Quit or Tame Apps & Processes | local network or Tailscale | Addressed by row id.  Held open until the report is written (a few seconds), off the server queue. |

There is deliberately no new opt-in for either.  Settings are the same kind of change as the lookback and grouping the edit opt-in already covers.  Sample acts on a process, so it sits with Quit and Tame.  Both names are unchanged, so the labels the owner already knows stay put; their descriptions in Settings say what they now cover.

### Request bodies

Until now every phone request was query-only, because the server stopped reading at the first blank line (or 8 KB) and dropped a body that arrived in a later TCP segment.  The server now waits for `Content-Length` bytes (at most 16 KB, answered 413 beyond that), and a client has 15 seconds to deliver a whole request.  A connection that closes before the request is whole is dropped without routing it.  A test sends the headers and the body in two writes a moment apart over a real loopback listener.  The webhook URL travels in the body, never in a query string.

### A bare question mark no longer ends the Mac app

The request parsers took the second piece of a split on `?`, which does not exist when the path ends in the mark, so one `POST /v1/view? HTTP/1.1` from any paired phone trapped and ended the Mac app (found by the review of this batch; the pattern was already on `main` in the exclusions, view and process routes).  All of them now go through `CompanionHTTP.queryString(of:)`, and a test sends every route a bare `?`.

### The webhook is a secret

`hoghunter.alertWebhookURL` is the one secret in `INFISICAL.md`.  So:

- The snapshot carries only `webhookConfigured`, the last two labels of the host ("…slack.com", because some services put the secret endpoint id in a subdomain), and the last delivery status with the URL taken out of it.  The phone can replace or remove the webhook and send a test, never read it back.
- The phone may set only an `https` address with a host.  The URL crosses an unencrypted link, so a plain `http` webhook is a Mac-only setting.  The link is still plain HTTP (TLS is board `ca962984`), so the phone also refuses to send the address at all unless it reached the Mac over Bonjour, a private or Tailscale address, or a `.ts.net` or `.local` name.  The Mac refuses controls from outside the local network, but it has read the request by then.
- Send Test Webhook posts to the webhook the Mac already holds.  The phone never supplies a URL for a test, a request that sets a URL and tests it at once is refused, and tests are spaced 15 seconds apart because they post to the owner's Slack or Discord.

### Settings write through like the Mac's

A phone's settings change goes through the same `HogStore` properties the Settings window uses, so persistence, the timer restart and the Infisical write-through are identical.  If Infisical is configured and the write fails, the Mac keeps the local value, records the failure in Settings > Advanced, and the next successful refresh re-asserts the Infisical value, exactly as for a change made at the Mac.  Turning alerts on from the phone can make macOS ask the Mac for notification permission; that prompt is answered at the Mac.

### Existing opt-ins gain a little

An owner who already allows Quit or Tame now also allows Sample for 3 Seconds.  An owner who already allows Change Exclusions & View now also allows the settings above.  No re-consent happens.  Both descriptions in Settings > iPhone and the pairing alert's checkboxes were reworded to say so.

### Sample for 3 Seconds

The Mac re-checks the row's processes against the live process table (the start time check Quit and Tame use) and samples the first live member it owns.  Hog Hunter itself, another user's process and pid 1 are refused.  One sample runs at a time (409 for a second), and a `sample` that outlives its time is stopped.  The phone asks for a confirmation first, like every other action.  The report is written where the Mac's own Sample writes it, `~/Library/Logs/HogHunter/`, and no window opens on the Mac.  The phone gets the file name, its size and up to twelve lines from the report's "Sort by top of stack" section.  The Mac reads only the last 256 KB of the report to find them.

## PR B: disk cleaner

| Feature | Where it lives | Gate |
|---|---|---|
| Scan for the Standard or Extreme tier | `POST /v1/clean/scan?tier=standard\|extreme[&ack=1]` | Allow iPhone to Run Disk Cleaner |
| Preview the scan, pick items, read cleanup history | `GET /v1/clean/report` | Allow iPhone to Run Disk Cleaner |
| Clean the picked items | `POST /v1/clean/run` with a JSON body (`scanId`, `tier`, `items`, `acknowledgedExtreme`) | Allow iPhone to Run Disk Cleaner |
| Record phone cleans in cleanup history | the same code path as the Mac's cleaner | n/a |

### The phone never names a path

`CleanItem.id` is the item's path, so the phone is not allowed to send one.  The Mac holds the scan under an id (`RemoteCleanScan`), the report lists items with short references (`"3.12"` is the thirteenth item of the fourth category), and a clean sends the scan id and the references back.  `CompanionCleanerReport.plan` resolves them against the Mac's own scan and refuses the whole request on any of: no scan, a different scan id, a scan older than 30 minutes, a tier that does not match the scan, an unknown tier, an unknown reference, Extreme without the acknowledgement, or nothing selected.  A scan is spent by one clean.  `DiskCleaner.clean` then re-applies the current exclusions and `isSafeToDelete` to every item, as it does for the Mac.

### Choosing items has its own route

`POST /v1/clean` takes no body and is always the Standard clean with the Mac's default selection, exactly as an older phone expects.  Choosing items is `POST /v1/clean/run`, a route an older Mac does not have, so a new phone talking to an older Mac gets 404 ("older than this app") instead of having the Mac ignore the body and run its default clean in place of the one the person confirmed.  The phone also drops the scan it is showing whenever the Mac stops vouching for it (404, 403, 401) or the phone forgets the Mac, leaves demo mode or reconnects.

### Snapshot thinning is Mac-only

`DiskCleaner.clean` thins every APFS local snapshot in one call whichever row is ticked, and it does so before the safety snapshot is taken.  Ticking one snapshot row therefore removes the rollback point an earlier clean left, and the confirmation ("A snapshot is created first, and if that fails nothing is deleted") would be false.  The Mac has the same behavior, but a phone feature must not ship without its safeguards, so the phone neither lists nor accepts that category.  This is a deliberate gap in parity and is easy to lift once thinning is fixed to be per-item and to run after the safety snapshot.

### Extreme

The notice is one string in `CleanerCopy` (`CompanionSnapshot.swift`), used by the Mac's cleaner view and the phone, so the two cannot drift.  The phone shows it and needs it ticked before a scan; the Mac refuses an Extreme scan (`ack=1`) or clean (`acknowledgedExtreme`) without it, so a phone that forgets cannot run Extreme by accident.  The phone confirms every clean with the Mac's own confirmation wording.

### History

The Mac's cleaner built its history row inside `DiskCleanerStore`; the phone's clean wrote none.  The row is now built by `CleanupHistoryRecord.record(from:source:)`, which both call, and a phone clean is marked `"iPhone"`.  The log's append lock is now shared by every instance (it was per instance, and the Mac cleaner and the phone each own one).  `recentRecords(limit:)` reads a bounded tail, and the report carries the last ten.

### Size and shape

The report lists at most 100 items per category, largest first, and says how many there really are.  Nothing in a category beyond the listed items is selectable from the phone.  A report is fetched when the cleaner screen opens and while a scan runs; it is not part of the snapshot, so the 3 second poll stays small.  A full set of references fits well inside the 16 KB body cap.

### Existing opt-in gains a little

An owner who already allows Run Disk Cleaner now also allows Extreme (with the phone's acknowledgement), item selection, and reading the scan and history.  The Settings description says so.  A bare `POST /v1/clean` from an older phone is unchanged: the Standard clean with the Mac's default selection, and now recorded in history.  A scan that never finishes is replaced by a new one after 15 minutes, and turning the cleaner opt-in off drops the held scan.

### Follow-ups

Nothing beyond batch 1's list.  The rest of a category with more than 100 items cannot be chosen from the phone.

## Screenshots

The hosted `test` job already launches the iOS app with `-HogHunterSample` and uploads the frames as the `app-screenshots` artifact.  This batch adds launch flags that put each new surface on screen, and `scripts/capture-app-screenshots.sh` captures them once on the 6.3 inch iPhone as `extra_*.png`: `-HogHunterNetwork` (bandwidth cards), `-HogHunterStorage`, `-HogHunterMacSettings` (the Mac Settings sheet) and `-HogHunterSampleResult` (the sample result sheet), `-HogHunterCleaner` and `-HogHunterCleanerExtreme` (a finished scan, the second with the Extreme notice ticked).  They are best effort: a missing one is a warning, and the five format frames stay the gate.  The Activity frames show the CPU scale picker and the sparkline.

## Verification

- `xcodegen generate && xcodebuild -scheme HogHunter -destination 'platform=macOS' test`.
- iOS: no simulator and no local `xcodebuild`, by owner rule.  `swiftc -typecheck` against the iOS 17 simulator SDK passes for the app target (now including `Sources/UI/CpuSparklineView.swift`, shared so the phone draws the same sparkline as the menu bar) and, separately, the widget target.  The hosted iOS build in CI is the real check.  Nothing here has been run on a phone yet.

## Rollback

PR A reverts on its own.  A phone built after it that talks to a Mac without it gets 404 on the new routes, which it shows as "This Mac's copy of Hog Hunter is older than this app", and finds no `bandwidth`, `cpuHistory` or `settings` in the snapshot, so it hides those sections.

## Follow-ups

| Item | Board |
|---|---|
| TLS on the companion link (also protects the webhook URL in transit) | `ca962984` |
| Move the phone's token into the Keychain | `5afb6e7f` |
