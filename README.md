# Hog Hunter

A Mac menu bar utility that names the processes and apps eating CPU and memory right now, over the past hour, and over the past 24 hours.  Quit a hog from the list after a confirm.  It also shows what is using your disk and your network, and it can clean reclaimable disk clutter.

The Mac app is a direct download.  The iPhone companion has TestFlight builds.  Neither is on the App Store.

## What it shows

- Menu bar: live machine CPU percent.
- Panel meters: CPU and memory.
- **Now** — live snapshot.  100% CPU is one core fully busy (same idea as Activity Monitor).
- **Past Hour** / **Past 24 Hours** — averages from samples Hog Hunter took while it was open.
- **Apps** groups helpers (Chrome, Electron, …) under one row.  **Processes** lists pids.
- **Quit** / **Force Quit** on live rows.  History rows are look-only.

History only covers time the menu bar app has been running.  Turn on **Launch at Login** if you want a real day of data.

## Storage

- Top-25 installed apps by disk usage, split into bundle size and the hidden cost behind it — containers, caches, saved state, logs, cookies, HTTP storage, and Application Support.
- A per-app category breakdown so you can see where the bytes actually live.
- **All installed** / **Running now** filters, and **Total** / **Hidden** / **Bundle** sort orders.
- A disk cleaner for caches, logs, Trash, developer junk, orphaned app leftovers, stale AI agent transcripts and models, and large or old files.  A standard clean preserves recoverability through an APFS snapshot; a deep clean goes further.
- **Robotic Vacuum** — scheduled background cleaning (pressure check every 5 minutes, worktree janitor every 30 minutes, full vacuum every 4 hours) with run history, step toggles, and alerts when a schedule is missed or the background job is unloaded.
- Per-directory walks are capped, and a capped row is flagged as approximate in the UI rather than reported as exact.

## iPhone

Hog Hunter on iPhone shows the same list the Mac is showing, over the Wi-Fi you are both on or over Tailscale, and it can act on that Mac: quit or force quit an app, tame a runaway one, run the safe clean, change cleaner exclusions and the panel view (including the CPU scale), change the refresh interval, alerts and webhook, and run Sample for 3 Seconds on a row.  It also shows the Mac's network speed and 24-hour peak and a CPU sparkline.  Each of those is off until you turn it on in Settings > iPhone on the Mac, the phone asks you to confirm every action, and the Mac accepts them only from your local network or Tailscale.

On the Mac, open Settings and turn on **Share With iPhone**.  Type the pairing code into the phone, or let the phone ask and approve it on the Mac.  Each phone gets a token of its own and is listed under **Paired iPhones**, where **Revoke** cuts it off.  Leave the switch off on a network you do not trust.  Do not forward the port from your router: the link is not encrypted yet.  See `docs/rollouts/2026-10-09-phone-parity-batch-1.md`.

Build the phone app for the simulator with scheme `HogHunterIOS`.  TestFlight builds come from the release workflow; there is no App Store release, and no public install link is published here.

## Build and run

```bash
cd ~/apps/HogHunter
xcodegen generate
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build
open build/Build/Products/Release/HogHunter.app
```

To build, sign, and install to `/Applications/Hog Hunter.app` in one step, use `scripts/install.sh` instead.  It signs Release builds with the "Developer ID Application" identity when one is in the keychain, falling back to an adhoc signature otherwise, then quits any running copy and relaunches the new one.  It installs to `/Applications` by default when a copy already lives there, otherwise to `~/Applications`; pass `--dest PATH` to pick a destination explicitly (for example `--dest ~/Applications`).  Pass `--dry-run` to see what it would do without touching anything, or `--no-launch` to install without opening the app.

No LaunchAgent for CPU and memory sampling.  The menu bar app is the sampler; quitting it stops history.

**Robotic Vacuum** (scheduled disk cleaning) is separate from CPU and memory sampling.  It does not replace Launch at Login for the menu bar app.

## Tests and CI

`HogHunterTests` is an XCTest target covering `CpuMath` and `MemoryMath` conversion math, process `Grouping`, `HistoryStore` aggregation and schema migration, `AlertPolicy` sustain and cooldown decisions, `MetadataResolver` caching, and `HogFormat` string formatting.  Run it locally with:

```bash
xcodegen generate
xcodebuild -scheme HogHunter -destination 'platform=macOS' test
```

GitHub Actions (`.github/workflows/ci.yml`) runs the same test suite on every push to `main` and on every pull request, unsigned (`CODE_SIGNING_ALLOWED=NO`).

Python reclaim and Robotic Vacuum scheduler tests (Linux-safe):

```bash
python3 scripts/test-hoghunter-clean.py
python3 scripts/test-robotic-vacuum.py
```

## License

Apache License 2.0.  See [LICENSE](LICENSE) for details.

## Notes

Theme follows the system by default; Light and Dark are available in Settings.  Headings and buttons are Title Case.  Body copy is sentence case with two spaces between sentences.  The app icon is the Hog Hunter lockup.  The menu bar glyph stays the flame.
