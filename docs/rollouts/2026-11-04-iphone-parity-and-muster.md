# iPhone Parity With The Mac And Server, And The Muster Report

HH-215.  Owner request, Nov 4, 2026:  the iPhone app should have full insight into the server and the Mac and more complete parity with the Mac app, and Hog Hunter's scripts or basic metrics may benefit Muster, so the two should integrate.

This is the umbrella record.  Route detail is in `2026-11-04-iphone-server-status.md` and `2026-11-04-phone-parity-batch-3.md`, and the binding route table is in `AGENTS.md`.

## What Landed

| PR | What it does |
|---|---|
| HogHunter #266 | Read-only Server tab and Flagged Issues on the phone |
| HogHunter #267 | Server process, workload and maintenance controls from the phone |
| HogHunter #269 | Category totals, standard cleanable estimate, custom script list, step toggles, thresholds, temp file minimum, Launch at Login |
| HogHunter #264 | Writes `~/.local/state/fleet-tools/hoghunter-mac.json` for Muster |
| AI-Fleet-Coordinator #1333 | Muster's Operations tab reads that file |

## The Gap List

The audit compared 77 functions before this work.  It found 36 with no gap, 1 display gap, 16 needing snapshot data, 10 needing a route, 4 Mac-only by decision and 10 not meaningful on a phone.  The phone had no server data at all.

| Function | Gap | Now |
|---|---|---|
| Server headline, CPU with cores, load and history | Snapshot | #266 |
| Server memory, swap and pressure | Snapshot | #266 |
| Server devices, databases, directories and daily change | Snapshot | #266 |
| Container storage diagnostics, tools with reasons | Snapshot | #266 |
| Server top processes, Coolify workloads | Snapshot | #266 |
| Snapshot age, loading and error state | Snapshot | #266 |
| Flagged Issues, Mac and server | Snapshot | #266 |
| Quit, force quit, tame, restore and sample a server process | Route | #267 |
| Stop and restart a Coolify workload | Route | #267 |
| Server maintenance scan and run | Route | #267 |
| Installed app category totals | Snapshot | #269 |
| Standard cleanable estimate | Display | #269 |
| Custom scripts list | Snapshot | #269, names only |
| Maintain step toggles | Route | #269, built-in steps only |
| Maintain thresholds | Route | #269 |
| Temp file minimum untouched hours | Route | #269 |
| Launch at Login | Route | #269 |
| Alert delivery to the phone | Snapshot and transport | Left, see below |

## Safeguards

Server status needs its own opt-in, a phone's own token, and a local network or Tailscale peer.  The shared pairing code never receives it.

Server controls need a second opt-in on top of that and are Tailscale only, which is stricter than every other route.  The link is plain HTTP, so a token sniffed on a local network must not reach the server.  The phone sends an opaque row id and an enum, and the Mac builds every argument from its own current snapshot.  Both opt-ins are set in Mac Settings only and never in the pairing alert.

## Muster

Muster lives in AI-Fleet-Coordinator under `muster/`.  It already read the server's status but had no Mac CPU, memory, per-volume disk, top hogs or cleanup state, so that is what it gets.

The shape is one file, written by the running app every 60 seconds and read with Muster's existing report pattern.  A route was rejected because the companion's credentials are phone tokens and its server is off by default.  A CLI was rejected because live CPU, memory, hogs and regimen state exist only in the running app.

Authentication is the operating system's:  the file is mode 0600, the writer refuses a folder that is shared or owned by someone else, and the reader refuses anything that is not a regular file owned by the current user.  There is no route, no control path and no secret.  The file carries no path but mount points, and no argv, step reason, lane name, server host or lock owner record.

The app never creates the folder, so the file stays off any Mac outside this fleet.  When Hog Hunter is closed the file goes stale and Muster reads unknown, which is the honest answer.

Muster does not run Hog Hunter's scripts.  They change the disk, and what Muster needed to see is already in this report.

## Gaps Left On Purpose

- **Regimen controls and status.**  Mac only by the decision in `2026-10-21-automatic-clean-regimen.md`.  A phone that can schedule recurring deletes needs its own opt-in and record.
- **APFS snapshot thinning and non-full Maintain kinds.**  Mac only by the rules in `AGENTS.md`.
- **Enabling a custom script from the phone.**  It runs arbitrary code, so the route refuses those keys.
- **Consent and credentials.**  Opt-ins, pairing, revoke, Infisical and the server's SSH host stay on the Mac, so a phone cannot grant itself more.
- **Mac-bound actions.**  Reveal in Finder, Activity Monitor, Copy PID, menu bar icon choices, software update and Quit Hog Hunter mean nothing on a phone.
- **Push alerts.**  The phone sees Flagged Issues when it reads a snapshot, but nothing wakes it.  That needs an APNs relay, which is a project of its own, tracked in HH-161.

## Open Follow-Ups

- TLS for the phone link, board `ca962984`.  It is why server controls are Tailscale only.
- `POST /v1/clean` can still permanently empty the Mac's Trash after a person confirms.  This work did not change that.
- Mac menus and scheduled runs use separate control instances, so they can overlap a phone action.  The server's lock and the identity checks in `control.py` still apply.
- Test hosts launched from `/Volumes/External` hang in dyld, and building with `SYMROOT` on the internal disk avoids it.  One source-reading test could not run locally for the same reason.

## Verification

CI ran on every pull request:  the Mac unit tests, the iPhone Simulator build and the screenshot capture.  A merged pull request here means those passed.

The Server tab was checked in CI screenshots with demo data:  the top of the tab, disks and databases, processes and workloads, and the Stop Process confirmation.  The sentence gap shows in the confirmation.  The capture only frames the top of each list, so lower rows such as maintenance controls were checked in code and tests, not by eye.

Not verified:

- No real iPhone has called these routes, over Tailscale or a local network.
- Muster's panel and the status file have not been seen in the running apps.  The writer and the reader are covered by tests only.
- Server controls have not stopped a real process or workload.
- No test covers the store passing `vps.isStale` into Flagged Issues, because that check reads the real clock.  `FlaggedIssuesTests` covers the note itself.
