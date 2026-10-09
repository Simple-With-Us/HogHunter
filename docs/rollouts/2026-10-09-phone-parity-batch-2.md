# Phone parity, batch 2 (2026-10-09)

Board `32919186`.  Issues: #99 (A).  PRs: A (this doc starts here), B (disk cleaner), C (Robotic Vacuum).

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

## Screenshots

The hosted `test` job already launches the iOS app with `-HogHunterSample` and uploads the frames as the `app-screenshots` artifact.  This batch adds launch flags that put each new surface on screen, and `scripts/capture-app-screenshots.sh` captures them once on the 6.3 inch iPhone as `extra_*.png`: `-HogHunterNetwork` (bandwidth cards), `-HogHunterStorage`, `-HogHunterMacSettings` (the Mac Settings sheet) and `-HogHunterSampleResult` (the sample result sheet), `-HogHunterVacuum` (the Robotic Vacuum screen).  They are best effort: a missing one is a warning, and the five format frames stay the gate.  The Activity frames show the CPU scale picker and the sparkline.

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

## PR C: Robotic Vacuum

Issue #102.  The iPhone shows the Robotic Vacuum's status and can start a full run, on the same terms as every other mutation: an opt-in that is off by default, a confirmation on the phone, and the same network and credential checks.

| Feature | Where it lives | Gate |
|---|---|---|
| Status: health, last and next full clean, background job loaded, running now, bytes the last run freed | `vacuum` in the snapshot; Storage tab > Robotic Vacuum | read-only, like the snapshot |
| What each step of the last run did | `vacuum.steps` in the snapshot; the same screen | Allow iPhone to Run Robotic Vacuum |
| Run Now | `POST /v1/vacuum/run`; the same screen, after a confirmation | Allow iPhone to Run Robotic Vacuum |

### Route

| Route | Credential | Opt-in | Peer must be | Notes |
|---|---|---|---|---|
| `POST /v1/vacuum/run` | a phone's own token | Allow iPhone to Run Robotic Vacuum | local network or Tailscale | Query `kind=full`.  Absent means full; anything else is 400. |

The gates run in this order: a valid credential (401), a trusted peer (403), a phone's own token rather than the shared code (403), the method (405 unless POST), the `kind` (400), the opt-in (403, naming "Allow iPhone to Run Robotic Vacuum"), a handler (501), a run already going (409), and then the start (202).  The `kind` is checked before the opt-in, as the row id is for Sample, so a malformed request is told so whatever the setting.  `scripts/robotic-vacuum.py` also accepts `janitor`, `watch` and `pressure`; none is reachable from the phone, and every `kind` in a repeated query must be `full`.

### The route answers at once

A full run takes minutes.  A clean holds its connection until the Mac finishes, but the vacuum has nothing to hand back that the snapshot does not already carry, so the Mac answers `{"status":"started"}` (202) and the run proceeds there.  While one is going, the answer is 409 `{"status":"busy"}`.  The phone watches `vacuum.isRunning` in the snapshot, which goes true when a run this app started begins and false when it ends (a run the background job started is not seen: Run Now then answers "started", the engine finds its housekeeper lock held and skips, and the status shows that skip), and it fetches a fresh snapshot a moment after the Mac answers.  Closing the app does not stop the run.

The router decides "busy" itself, on the server queue, from a `CompanionLocked<Bool>` the host keeps in line with `RoboticVacuumStore.isRunningNow` (a Combine sink on the store, so a run started from the Mac panel counts too).  Requests are handled one at a time on that queue, so the check and the set cannot interleave: two quick taps start one run, a test pins that.  After it asks the store to start, the host sets the flag back to what the store says, so a request that lost a race with the panel cannot leave it stuck true.

### One store, so one run

`HogStore` owns a single `RoboticVacuumStore` (`let vacuum`).  The Storage tab, the separate Storage window and the phone route all use it.  Before, the tab built its own, so a phone run and a panel run could overlap.  The Python engine also takes a housekeeper lock (`scripts/vacuum/lock.py`), so a race that slipped past would at worst skip a run.  The store reads its files (`status.json`, `history.json`, `config.json`) when it is built, every 30 seconds while the tab is open, and, for the phone, at most every 30 seconds and only when a phone fetches the snapshot (`refreshIfStale`).  The 3 second publish never reads a file.

### The disclosure rule

The coarse status is in the snapshot whenever the Mac has one: health, what the Mac prints for it, whether the background job is loaded, running or not, the last and next full clean, and the last run's end and bytes freed.  The per-step results are in it only while Allow iPhone to Run Robotic Vacuum is on, and then only for a phone's own token on the local network or Tailscale.  A step's reason can name a lane folder or a server, and the snapshot is readable with the shared pairing code from anywhere, so the Mac builds two snapshots: the plain one (what the shared code and any outside address read) and, while the opt-in is on, a detailed one that only a phone's own token from a trusted address is served.  Detail sits behind the same opt-in as the power to run.  Reasons are cut to 120 characters and one line.  Turning the setting off takes the steps out of the next snapshot.

Before the engine has written a `status.json`, a run in progress still shows as running (health `unknown`, "Waiting for first run").  A Mac with no status and no run sends no `vacuum`.  An older Mac sends neither `vacuum` nor `remoteVacuumAllowed`; the phone reads a missing `remoteVacuumAllowed` as "this Mac predates the feature" and says so, and a 404 from the route reads the same.

### Why it has its own opt-in, and is not in the pairing alert

A full run is the widest thing the phone can ask for.  It can retire old merged git worktrees, trim caches and build folders, and run maintenance on remote servers.  None of the existing three switches describes that, and folding it into Change Exclusions & View or the disk cleaner would grant it to every owner who already said yes to something narrower.  So it is a fourth switch, `allowRemoteVacuum` in UserDefaults (a consent toggle, not an Infisical setting), wired everywhere the other three are.  It is left out of the "Pair this iPhone?" alert on purpose: that alert is answered in a moment, for a phone that has only just asked, while a power this wide should be granted deliberately and in Settings.  The description under the switches in Settings now says the alert offers the first three choices only.

### Existing owners

Nothing is granted automatically.  An owner who wants Run Now on the phone turns on Allow iPhone to Run Robotic Vacuum once, in Settings > iPhone > Remote Control.  Until then the phone shows the vacuum's status, greys out Run Now, and says which setting to turn on.

### Tests never run the real vacuum

A real `--run-now full` deletes things on the machine it runs on.  `RoboticVacuumStore` takes a launcher closure; every test passes a stub, and the default launcher throws instead of starting the script when it finds itself inside XCTest.  The tests cover the route's refusal matrix (opt-in off, untrusted address, shared code, wrong token, wrong method, bad kinds), the handler never being reached by a refusal, 409 while running, two quick taps, the opt-in's default and its survival of a restart, the disclosure rule on the wire and in `HogStore`, the status builder, the 30 second read limit, and the gaps in the Mac's replies and the phone screen's strings.  The script was not run, beyond reading its argument list.

### Verification

- `xcodegen generate && xcodebuild -scheme HogHunter -destination 'platform=macOS' test`.
- iOS: no simulator and no local `xcodebuild`, by owner rule.  `swiftc -typecheck` against the iOS 17 simulator SDK passes for the app target and the widget.  The hosted iOS build in CI is the real check.  Nothing here has been run on a phone yet, and no one has pressed Run Now against a real Mac.

### Rollback

PR C reverts on its own.  A phone built after it that talks to a Mac without it sees no `remoteVacuumAllowed`, shows "not available on this Mac", and gets 404 from the route, which it reads as an older Mac.  A Mac that has it and a phone that does not simply never uses it.  `allowRemoteVacuum` stays in UserDefaults and is ignored.

### Not done

| Item | Note |
|---|---|
| Starting the cheaper cadences (`janitor`, `watch`) from the phone | Deliberately absent.  The whitelist is one entry, in `CompanionService.vacuumRunKinds`. |
| Toggling a step from the phone | The step list is read-only.  Steps are switched at the Mac. |
| Stopping a run from the phone | The script has no cancel. |
| One polling timer for two views | The Storage tab and the separate Storage window share the one store, so closing either stops its 30 second refresh for the other.  The phone's refresh is unaffected: it uses `refreshIfStale`. |
| Surfacing `RoboticVacuumStore.lastError` to the phone | A run that fails to start or exits non-zero shows on the Mac; the phone sees it as a run that ended and a changed health word. |
