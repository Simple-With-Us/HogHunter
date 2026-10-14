# Remote host stays online when Bonjour updates

Sat, Oct 4, 2026.  Seat GROK-BUILD.  Branch `grok-build/hh-remote-offline`.  Pull request #69.  Issue #64.

## Context & Objective

repo: `Simple-With-Us/HogHunter`.  Pre-work claim posted to `#agent-sync` (topic HogHunter issue #64 manual host offline on Bonjour).

On the same Wi-Fi, the iPhone companion discovers the Mac with Bonjour (`_hoghunter._tcp`).  A phone paired over Tailscale, LAN IP, or custom domain stores `remoteHost` / `remotePort` and reaches the Mac with `NWEndpoint.hostPort` (shipped in PR #75; see `AGENTS.md`).  Every Bonjour browse tick called `reconcile()`, which treated a missing Bonjour peer as offline and cleared the live dashboard—even while fetches over the saved address still worked.  Issue #64.  A second defect re-presented the pairing sheet every three seconds after Cancel when the Mac returned 401 for a rotated code.

Fleet recall (2026-10-09, query *HogHunter iOS companion Bonjour Tailscale manual host*): board lesson `636727035baf4d3dac0beb2c7ebfb578` and contrib `contrib/AG/2026-10-01/6dd52f92` confirm Tailscale / `hostPort` transport is intentional; issue #64 is the Bonjour-flap bug, not a mandate for Bonjour-only transport.

## Changes Made

- `Sources/Companion/CompanionSnapshot.swift` — `CompanionReach.keepsManualHost` helper shared with the iOS target.
- `ios/Sources/CompanionModel.swift` — skip offline reconciliation for address-backed saves in `noteDiscovery` / `reconcile`; `pairingDismissed` so `refresh()` does not re-enter `.code` after Cancel; `cancelCode()` paths for manual host vs Wi-Fi-only saved Mac.
- `Tests/HogHunterTests/CompanionTests.swift` — `testManualHostStaysPutWhenBonjourCannotSeeIt` (RFC 5737 addresses only).
- `docs/EFFORT-LOG.md` — in-progress row for this branch.
- `docs/rollouts/2026-10-04-remote-host-bonjour.md` — this note.

## Decisions & Trade-offs

- **Keep manual hosts.**  Bonjour browse results are not ground truth for a saved `remoteHost`.  `forget()` still clears address-backed saves when the user chooses Forget Mac.
- **Wi-Fi-only saves stay strict.**  When `remoteHost` is nil, losing Bonjour still marks the Mac offline.
- **Pairing sheet loop.**  `pairingDismissed` is set on Cancel and cleared on successful pair or remote connect; while set, 401 responses land in `.offline` with copy instead of re-opening the sheet.
- **Stale snapshot on transient errors.**  After at least one successful fetch, a later network error keeps the last snapshot on screen (unchanged from main).

## Verification State

| Command | Result |
|---------|--------|
| `xcodegen generate` | NOT RUN on Linux cloud agent (macOS CI runs this) |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -only-testing:HogHunterTests/CompanionTests/testManualHostStaysPutWhenBonjourCannotSeeIt` | PENDING — requires GitHub Actions `test` job on push |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` (full macOS unit suite) | PENDING — same CI job |
| `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` | PENDING — CI `build-ios` job |

Last known green (pre-`pairingDismissed` follow-up, local macOS seat): `CompanionTests` filter above exited 0.

## Next Steps & Blockers

- Merge after CI green on macOS unit tests and iOS simulator build.
- Owner smoke on a Tailscale-paired phone: confirm dashboard stays live through Bonjour browse churn; rotate pairing code, tap Cancel once, confirm sheet stays dismissed and status shows code mismatch.
- No TestFlight or credential changes in this pull request.

## Zero-Code Findings

- Kodus “Bonjour-only” findings conflict with product contract (`AGENTS.md`, PR #75, fleet recall above).  This change preserves address-backed transport and only stops Bonjour from falsely marking those sessions offline.
- iOS companion UI has no XCTest target; behavioral fixes are validated via macOS `CompanionReach` tests plus CI iOS compile.
