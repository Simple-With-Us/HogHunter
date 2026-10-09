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

Until now every phone request was query-only, because the server stopped reading at the first blank line (or 8 KB) and dropped a body that arrived in a later TCP segment.  The server now waits for `Content-Length` bytes (at most 16 KB, answered 413 beyond that), and a client has 15 seconds to deliver a whole request.  A test sends the headers and the body in two writes a moment apart over a real loopback listener.  The webhook URL travels in the body, never in a query string.

### The webhook is a secret

`hoghunter.alertWebhookURL` is the one secret in `INFISICAL.md`.  So:

- The snapshot carries only `webhookConfigured`, the host, and the last delivery status with the URL taken out of it.  The phone can replace or remove the webhook and send a test, never read it back.
- The phone may set only an `https` address with a host.  The URL crosses an unencrypted link, so a plain `http` webhook is a Mac-only setting.  The link is still plain HTTP (TLS is board `ca962984`), which is why the phone says to set it at home or over Tailscale.
- Send Test Webhook posts to the webhook the Mac already holds.  The phone never supplies a URL for a test.

### Settings write through like the Mac's

A phone's settings change goes through the same `HogStore` properties the Settings window uses, so persistence, the timer restart and the Infisical write-through are identical.  If Infisical is configured and the write fails, the Mac keeps the local value, records the failure in Settings > Advanced, and the next successful refresh re-asserts the Infisical value, exactly as for a change made at the Mac.  Turning alerts on from the phone can make macOS ask the Mac for notification permission; that prompt is answered at the Mac.

### Existing opt-ins gain a little

An owner who already allows Quit or Tame now also allows Sample for 3 Seconds.  An owner who already allows Change Exclusions & View now also allows the settings above.  No re-consent happens.  Both descriptions in Settings > iPhone and the pairing alert's checkboxes were reworded to say so.

### Sample for 3 Seconds

The Mac re-checks the row's processes against the live process table (the start time check Quit and Tame use) and samples the first live member it owns.  Hog Hunter itself, another user's process and pid 1 are refused.  The report is written where the Mac's own Sample writes it, `~/Library/Logs/HogHunter/`, and no window opens on the Mac.  The phone gets the file name, its size and up to twelve lines from the report's "Sort by top of stack" section.  The Mac reads only the last 256 KB of the report to find them.

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
