# Phone parity, batch 1 (2026-10-09)

Board `eb0efb86`.  Issue #63.  PRs: A (broken controls) #96, B (hardening) #97, C (this doc and the other doc fixes) #98.

## Ruling

On 2026-10-09 the owner ruled that the iPhone app reaches parity with the desktop app, mutations included.  That replaces the read-only viewer stance in the 2026-09-26 design and in the TestFlight notes.  Batch 1 fixes the phone controls that were broken or silent and builds the safeguards that have to exist before the phone is allowed to do more.  Batch 2 and later widen what the phone can do.

## What the Mac now answers

| Route | Credential | Opt-in (Mac Settings > iPhone) | Peer must be | Notes |
|---|---|---|---|---|
| `GET /v1/snapshot` | a phone's token, or the shared pairing code | Share With iPhone | anywhere | The only route a public address can use. |
| `POST /v1/quit`, `POST /v1/tame` | a phone's own token | Allow iPhone to Quit or Tame Apps & Processes | local network or Tailscale | Addressed by row id, checked per process against its start time. |
| `POST /v1/clean` | a phone's own token | Allow iPhone to Run Disk Cleaner | local network or Tailscale | Answers when the Mac finishes; one clean at a time, a second gets 409. |
| `POST /v1/exclusions`, `POST /v1/view` | a phone's own token | Allow iPhone to Change Exclusions & View | local network or Tailscale | New opt-in in batch 1. |
| `POST /v1/enroll` | the pairing code | Share With iPhone | local network or Tailscale | Trades the code for a token of the phone's own. |
| `POST /v1/pair` | a person at the Mac | Share With iPhone | local network or Tailscale | The Mac shows an alert; Allow hands back a token. |

"Local network or Tailscale" means the address the connection arrived from is loopback, link-local, private (10/8, 172.16/12, 192.168/16), IPv6 unique-local (fc00::/7, which includes Tailscale's fd7a:115c:a1e0::/48), or 100.64.0.0/10 (Tailscale's IPv4 range).  An IPv4-mapped IPv6 address is judged by the IPv4 address inside it.

Wrong credentials are throttled per client address: five free misses, then a lockout that doubles from 2 seconds to 15 minutes, answered 429 with `Retry-After`.  A good request clears the slate and a quiet client is forgiven.  A global cap for rotating outside addresses applies to outside addresses only, so strangers guessing through a forwarded port cannot lock out the phone on the home Wi-Fi.

## Tokens

Pairing issues each phone a token that starts with `hh1_` followed by 192 random bits.  The Mac keeps the phone's name, a SHA-256 hash of the token, and paired and last-seen times in `companionDevices` in UserDefaults.  The token is shown to the phone once and never stored on the Mac.  Settings > iPhone > Paired iPhones lists the phones, and Revoke cuts off one phone at once.  A new pairing code does not disconnect a paired phone.

The 8 character pairing code is about 40 bits.  It now only pairs a new phone and reads the snapshot.  It cannot quit, tame, clean or edit.

## Version skew

| Phone | Mac | Reads | Controls |
|---|---|---|---|
| Old | Old | Yes | Yes, as before |
| Old | New | Yes, with the shared code | No: 403 "still paired with the shared code" until the phone updates |
| New | Old | Yes | Yes: enroll answers 404, so the code stays the credential |
| New | New | Yes | Yes, after the phone quietly swaps its saved code for its own token on first connect |
| New, off the LAN | New | Yes | No, with the reason shown; the swap finishes when the phone is on the LAN or Tailscale |

Existing users must turn on **Allow iPhone to Change Exclusions & View** once.  Before batch 1 the lookback and grouping pickers and the exclusion controls worked without an opt-in.

## What this does not do

- **The link is still plain HTTP.**  Controls are limited to the local network and Tailscale, but on a local network a token still crosses the Wi-Fi in the clear.  Tailscale encrypts its own traffic.
- **A router that rewrites forwarded traffic to its own LAN address (SNAT, hairpin NAT) makes that traffic look local.**  The address check cannot see through that.  Port forwarding is still not safe, and Settings says so.
- **The phone keeps its token in app defaults, not the Keychain.**

## Follow-ups

| Item | Board |
|---|---|
| TLS on the companion link: a self-signed certificate in the Mac Keychain, its fingerprint shown in Settings and carried in the Bonjour TXT record, the phone pinning the fingerprint it saw at pairing, Tailscale exempt | `ca962984` |
| Move the phone's token into the Keychain | `5afb6e7f` |
| Restore Priority cannot work for an ordinary user: Tame sets a nice value and only root can lower one | `d4c36387` |

TLS is not half-done in batch 1 on purpose.  Pinning on iOS needs a migration for already-paired phones and a trust prompt that has to be designed, and a half-version would suggest the link is protected when it is not.

## Verification state

- Mac: `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` passes (357 tests on the last run before PR B merged), including real child processes for the identity checks and a real loopback listener that proves an accepted connection reports a numeric, trusted peer.  `DiskCleanerTests.testScanAPFSSnapshotsFallsBackToAggregateWhenListFails` depends on local Time Machine snapshots: it failed at baseline and on two runs, then passed.
- iOS: no simulator and no local `xcodebuild`, by owner rule for small changes.  `swiftc -typecheck` against the iOS 17 simulator SDK passes for the app target and, separately, the widget target.  The hosted iOS build in CI is the real check, and it passed for #96 and #97.  Nothing here has been run on a phone yet.
- There is no `Package.swift`, so there is no `swift test`.

## Rollback

Each PR reverts on its own.  Reverting B returns control routes to the shared code.  Paired phones are then unknown to the Mac, and a phone holding a token falls back to the pairing screen.  Reverting A brings back the always-visible Quit and Tame, the empty Network tab, and the blocking clean.
