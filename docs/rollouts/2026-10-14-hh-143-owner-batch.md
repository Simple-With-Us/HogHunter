# Owner Batch: CleanMyMac Option, RAM Figure, Gear, 5s Refresh, Tailscale Pairing (2026-10-14)

Board `25ee51bf`.  Issue HH-143.  Five owner-directed items in one batch.

## What Changed

| Where | Change |
|---|---|
| `scripts/hoghunter-clean` | New `--cleanmymac` flag (opt-in): after this engine's own work, runs the CleanMyMac CLI's non-interactive sweeps (`clean junk --force`, `optimize purgeable`) when the CLI is installed.  Without the flag it is never invoked.  A missing CLI, a spent budget, a timeout, or a non-zero exit is recorded in the `--json` report under `cleanmymac` and logged, and never fails the run.  The stale "CleanMyMac is uninstalled" header now says invoke-only instead. |
| `scripts/vacuum/config.py`, `scripts/vacuum/engine.py` | New `cleanmymac_cli` step (trigger `full`, off by default via `DEFAULT_OFF_STEPS`).  Skips when the CLI is absent, fails with the tail when a sweep exits non-zero or times out.  Dry runs skip it.  The two command lists (cleaner flag, vacuum step) name each other in comments; keep them in sync. |
| `Sources/Storage/MaintainStore.swift` | The Maintain tab's Cleaning Steps list gains "CleanMyMac CLI sweep (when installed)".  `defaultOffSteps` mirrors the engine's off-by-default set so a fresh install reads off, matching what the run does.  Turning it on writes the engine config the same way every other toggle does. |
| `ios/Sources/CompanionViews.swift` | The phone's process rows now swap like the Mac's: sorting by Memory puts the RAM figure on top in the large style, sorting by CPU puts %CPU on top.  The Mac panel already swapped (verified in `Sources/UI/RowView.swift`, present since the 1.1 overhaul); only the phone stayed %CPU-first, which is what the report described. |
| `Sources/UI/HogHunterPanel.swift` | The Settings gear grows from 15 pt in a 22 px frame to 17 pt in a 28 px frame. |
| `Sources/Store/HogStore.swift`, `INFISICAL.md`, `ios/Sources/CompanionModel.swift`, `Tests/HogHunterTests/InfisicalProjectSelectionTests.swift` | Default refresh 5 seconds, finished: the property, Settings, and Infisical defaults were already 5, and the stragglers (the Infisical project-switch reset, the INFISICAL.md inventory row, the phone's sample fixture) now say 5 too.  Four project-selection tests assert the new reset value.  A stored interval is never rewritten: a Mac that already holds 3 keeps 3 until picked otherwise in Settings. |
| `ios/Sources/CompanionModel.swift` | Pairing failures name the failure.  A refused connection (Hog Hunter closed, Share off), an unreachable address (Tailscale down on either end), an unresolvable name (misspelled MagicDNS), and a timeout each get their own sentence instead of "the Mac did not answer".  The remote offline line names the host and the Tailscale check.  The snapshot window grows from 4 to 10 seconds so a first paint over a slow Tailscale relay lands instead of timing out. |
| `ios/Sources/CompanionViews.swift` (Connect by Address) | The footer now says what works: Tailscale, a VPN, or a tunnel that lands on the Mac itself pairs like the local network; a raw router port forward stays out (the link is not encrypted, and Mac Settings says the same); an HTTPS tunnel needs app TLS first. |

## Decisions, On Purpose

1. **Invoke-only, never vendored.**  The CleanMyMac CLI is closed-source MacPaw software (the free public beta, v1.0.0 here).  Fleet recall already ruled it cannot be bundled into a shipped app.  Both new paths check for it on PATH and skip silently when absent, so a Mac without it behaves exactly as before.
2. **Only the non-interactive sweeps.**  `clean junk --force` and `optimize purgeable` need no review step by MacPaw's own design.  `purge`, `analyze`, and anything with a review UI are deliberately out: automation must not answer prompts on the owner's behalf.
3. **Off until turned on, in both engines.**  The vacuum step ships disabled and the Maintain tab reads disabled, mirroring `xcode_device_support`'s precedent.  A full run never surprises the owner with a third-party delete.
4. **No trust-policy change for tunnels.**  The Mac already binds every interface and already trusts Tailscale (100.64/10, fd7a:115c:a1e0::/48, `.ts.net` names) for pairing, controls, and enrollment, and a user tunnel that terminates at the Mac's own loopback (SSH `-L`, a local cloudflared) already arrives trusted.  What does not work is an HTTPS-terminating tunnel, which needs app TLS first (board `ca962984`).  Widening enrollment to untrusted networks would bless raw port forwards over a plaintext link, against the standing rule, so the fix is diagnosis and copy instead: the phone now says which of these is actually wrong.
5. **Stored refresh values are left alone.**  5 seconds is the default for fresh installs and project switches, not a migration.  Rewriting a stored 3 would second-guess an owner who may have picked it on purpose.

## Compatibility

An older Mac sends no `cleanmymac` key in its reclaim JSON and runs no such step; the phone needs nothing new for this batch.  The phone's swapped rows and new error strings need only the new phone build.  The 10 second snapshot window is phone-side only.
