# Fleet iOS ship files for Hog Hunter

A copy of the Mac fleet tooling (`/Users/jay/apps/ios-fleet`) that `.github/workflows/ios-testflight.yml` runs on a hosted macOS runner, through `scripts/ios-ship-testflight.sh`.  The canonical copy is not tracked in a repository, so this directory is the reviewable record.

- `ship-testflight.sh`, `ExportOptions-appstore.plist`, `ExportOptions-export-ipa.plist`:  unchanged from the canonical copy.
- `asc-api.mjs`:  canonical copy with two patches, marked `HogHunter vendor patch (HH-157)`:  the What to Test stamp has no timezone abbreviation and uses lower-case am or pm, and the agent-name filter covers more seats and bracketed seat tags.  `scripts/test-ios-release.py` runs the renderer.
- `scheduled-ship-gate.sh`, `test-scheduled-ship-gate.sh`:  from CodeCaps.
- `apps.json`:  the `hoghunter` row only (`xcodegenDir` is `.`).

When the canonical copy changes, re-copy the unchanged files and re-apply the two `asc-api.mjs` patches.  Do not set `IOS_TF_MIN_INTERVAL_SEC` or pass `--force-ship` anywhere in the workflow.  Detail:  `docs/rollouts/2026-10-17-ios-auto-ship.md`.
