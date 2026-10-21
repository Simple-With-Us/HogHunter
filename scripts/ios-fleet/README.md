# Fleet iOS ship files for Hog Hunter

A copy of the Mac fleet tooling (the `ios-fleet` directory on the fleet Mac) that `.github/workflows/ios-testflight.yml` runs on a hosted macOS runner, through `scripts/ios-ship-testflight.sh`.  The canonical copy is not tracked in a repository, so this directory is the reviewable record.

- `ship-testflight.sh`, `ExportOptions-appstore.plist`, `ExportOptions-export-ipa.plist`:  unchanged from the canonical copy.
- `asc-api.mjs`:  canonical copy with three patches, marked `HogHunter vendor patch (HH-157)`:  the What to Test stamp has no timezone abbreviation and uses lower-case am or pm;  the agent-name filter covers more seats and bracketed seat tags;  and a failed export-compliance PATCH in `ensure-tf-ready` still publishes What to Test before it exits 2.  `scripts/test-ios-release.py` runs the renderer.
- `scheduled-ship-gate.sh`, `test-scheduled-ship-gate.sh`:  from CodeCaps.
- `asc-key.mjs`:  the App Store Connect key module (AFC-459).  It validates a key, stages it for the Apple tools that can only read a key from disk, and never reads a key file:  a path on disk is not an approved credential source, so `ASC_KEY_PATH` is ignored wherever it appears and the key reaches the client in the environment.
- `test-asc-key.test.mjs`, `test-asc-credentials.sh`, `test-asc-credentials.mjs`:  the credential suites (AFC-459).  `test-asc-key.test.mjs` is the module's own test; the other two are the client and shell precedence tests.
- `apps.json`:  the `hoghunter` row only (`xcodegenDir` is `.`).

`asc-key.mjs`, the credential block of `asc-api.mjs` and the `load_secrets` layer of `ship-testflight.sh` carry the AFC-459 change:  they are not the canonical copy, so re-copying the canonical `ship-testflight.sh` over this one drops the credential rule.

When the canonical copy changes, re-copy the unchanged files and re-apply the three `asc-api.mjs` patches.  Do not set `IOS_TF_MIN_INTERVAL_SEC` or pass `--force-ship` anywhere in the workflow.  Detail:  `docs/rollouts/2026-10-17-ios-auto-ship.md`.
