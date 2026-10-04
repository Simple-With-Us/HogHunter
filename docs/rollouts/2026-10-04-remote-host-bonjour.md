# Remote host stays online when Bonjour updates

Sat, Oct 4, 2026

Effort row: `grok-build/hh-remote-offline`, issue #64, pull request #69.  State stays In Progress until that pull request merges.

## Why

A saved Tailscale, IP, or domain host uses an address, not a Bonjour peer id.  Every browse update called reconcile, which marked that Mac offline and dropped the dashboard.  A clean confirmation in flight went with it.

## What changed

- `Sources/Companion/CompanionSnapshot.swift` — `CompanionReach.keepsManualHost`.
- `ios/Sources/CompanionModel.swift` — `noteDiscovery`, `reconcile`, `cancelCode`, and `exitDemoMode`.
- `Tests/HogHunterTests/CompanionTests.swift` — `testManualHostStaysPutWhenBonjourCannotSeeIt`.
- `docs/EFFORT-LOG.md` — the in-progress row for this branch.
- `docs/rollouts/2026-10-04-remote-host-bonjour.md` — this note.

`CompanionReach.keepsManualHost` is true when the saved remote host trims to a non-empty string.  Browse updates do not mark that Mac offline.  Cancel on the pairing sheet still leaves the sheet.  Leaving demo mode drops the sample snapshot and waits for the next fetch.  A Wi-Fi-only saved Mac still goes offline when Bonjour cannot see it.

## Decisions and trade-offs

Tailscale and other manual hosts stay.  Bonjour is not the only way to reach a Mac.  A browse update is not evidence that a manual host died.

A fetch that fails after a snapshot is already on screen keeps that snapshot.  One dropped packet must not blank the dashboard.  The first failed fetch, when there is no snapshot yet, still says the Mac did not answer.

## Verification

`xcodebuild -scheme HogHunter -destination 'platform=macOS' -derivedDataPath /tmp/hh-bonjour-dd test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -only-testing:HogHunterTests/CompanionTests` exited 0 before this cancel-sheet follow-up.  The follow-up is in the iOS companion, which has no unit-test target.  `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' build` is the compile check for that target.
