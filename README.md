# Hog Hunter

A Mac menu bar utility that names the processes and apps eating CPU and memory right now, over the past hour, and over the past 24 hours.  Quit a hog from the list after a confirm.

Local only.  Not on the App Store.  Not TestFlight.

## What it shows

- Menu bar: live machine CPU percent.
- Panel meters: CPU and memory.
- **Now** — live snapshot.  100% CPU is one core fully busy (same idea as Activity Monitor).
- **Past Hour** / **Past 24 Hours** — averages from samples Hog Hunter took while it was open.
- **Apps** groups helpers (Chrome, Electron, …) under one row.  **Processes** lists pids.
- **Quit** / **Force Quit** on live rows.  History rows are look-only.

History only covers time the menu bar app has been running.  Turn on **Launch at Login** if you want a real day of data.

## iPhone

Hog Hunter on iPhone shows the same list the Mac is showing, over the Wi-Fi you are both on.  It cannot quit anything.

On the Mac, open Settings and turn on **Share With iPhone**.  Type the pairing code into the phone.  Leave the switch off on a network you do not trust.

Build the phone app for the simulator with scheme `HogHunterIOS`.  It is not on the App Store.

## Build and run

```bash
cd ~/apps/HogHunter
xcodegen generate
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build
open build/Build/Products/Release/HogHunter.app
```

To build, sign, and install to `/Applications/Hog Hunter.app` in one step, use `scripts/install.sh` instead.  It signs Release builds with the "Developer ID Application" identity when one is in the keychain, falling back to an adhoc signature otherwise, then quits any running copy and relaunches the new one.  It installs to `/Applications` by default when a copy already lives there, otherwise to `~/Applications`; pass `--dest PATH` to pick a destination explicitly (for example `--dest ~/Applications`).  Pass `--dry-run` to see what it would do without touching anything, or `--no-launch` to install without opening the app.

No LaunchAgent.  The app is the sampler.  Quitting it stops history.

## Tests and CI

`HogHunterTests` is an XCTest target covering `CpuMath` and `MemoryMath` conversion math, process `Grouping`, `HistoryStore` aggregation and schema migration, `AlertPolicy` sustain and cooldown decisions, `MetadataResolver` caching, and `HogFormat` string formatting.  Run it locally with:

```bash
xcodegen generate
xcodebuild -scheme HogHunter -destination 'platform=macOS' test
```

GitHub Actions (`.github/workflows/ci.yml`) runs the same test suite on every push to `main` and on every pull request, unsigned (`CODE_SIGNING_ALLOWED=NO`).

## License

Apache License 2.0.  See [LICENSE](LICENSE) for details.

## Notes

Light appearance is the default.  Headings and buttons are Title Case.  Body copy is sentence case with two spaces between sentences.  The app icon is the Hog Hunter lockup.  The menu bar glyph stays the flame.
