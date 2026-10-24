# Fleet iOS ship files for Hog Hunter

A copy of the Mac fleet tooling (the `ios-fleet` directory on the fleet Mac) that `.github/workflows/ios-testflight.yml` runs on a hosted macOS runner, through `scripts/ios-ship-testflight.sh`.  The canonical copy is not tracked in a repository, so this directory is the reviewable record.

- `ship-testflight.sh`, `ExportOptions-appstore.plist`, `ExportOptions-export-ipa.plist`:  from the canonical copy, with the AFC-517 version-scheme port applied (see "Version numbering" below).
- `asc-api.mjs`:  canonical copy with three patches, marked `HogHunter vendor patch (HH-157)`:  the What to Test stamp has no timezone abbreviation and uses lower-case am or pm;  the agent-name filter covers more seats and bracketed seat tags;  and a failed export-compliance PATCH in `ensure-tf-ready` still publishes What to Test before it exits 2.  `scripts/test-ios-release.py` runs the renderer.  It also carries the AFC-517 `latest-marketing-patch` and `build-floor` methods, which feed the ship script's version plan.
- `version-plan.mjs`, `version-plan.test.mjs`:  the version-numbering rules as pure, unit-tested functions (AFC-517).  `version-plan.mjs` holds no I/O; `ship-testflight.sh` implements the same rules in bash and `asc-api.mjs` imports the module for the App Store Connect queries.  `node --test scripts/ios-fleet/version-plan.test.mjs` runs the suite.
- `scheduled-ship-gate.sh`, `test-scheduled-ship-gate.sh`:  from CodeCaps.
- `asc-key.mjs`:  the App Store Connect key module (AFC-459).  It validates a key, stages it for the Apple tools that can only read a key from disk, and never reads a key file:  a path on disk is not an approved credential source, so `ASC_KEY_PATH` is ignored wherever it appears and the key reaches the client in the environment.
- `test-asc-key.test.mjs`, `test-asc-credentials.sh`, `test-asc-credentials.mjs`:  the credential suites (AFC-459).  `test-asc-key.test.mjs` is the module's own test; the other two are the client and shell precedence tests.
- `apps.json`:  the `hoghunter` row only (`xcodegenDir` is `.`).

## Version numbering

Owner directive 2026-10-24 (AFC-517 / CT-2444), which replaces the `1.0.<commit_count>` scheme unified in #2801 on 2026-10-18.  The rule lives in `version-plan.mjs` and is applied in `ship-testflight.sh`:

- `MARKETING_VERSION` (CFBundleShortVersionString) is `<prefix>.<P+1>`.  `<prefix>` is the train from `marketingVersionDefault` (`1.0`).  `P` is the highest patch App Store Connect already holds on that train, counting both the App Store versions (`appStoreVersions.versionString`) and the TestFlight trains (`preReleaseVersions.version`) for the app's platform.  A TestFlight train that holds a build named after its own patch (a `1.0.N` train holding build `N`, the "drift train" the retired scheme produced) is ignored, so those uploads no longer push the version forward.  App Store versions are never ignored.
- `CURRENT_PROJECT_VERSION` (CFBundleVersion) is the repo commit count, raised when needed so it is strictly greater than every build already in the target train (the retired 12-digit UTC stamps included) and than the app's highest plain-integer build below 1000000000 on that platform.  On macOS every build counts, because macOS build numbers must grow across all trains.
- The two numbers are **independent**.  The build number never names the marketing version and the marketing version never names the build, which is what stops App Store Connect from rendering `1.0.2358 (2358)`.  The one coupling is a safety rule:  a build that happens to equal the patch number moves one up.
- `--version X.Y.Z` is an exact marketing override and `--build N` an exact build override.  `--build` does not move the marketing version any more.
- App Store Connect is the only record that shipping advances, so an unreachable App Store Connect is fatal unless `--allow-unverified-seq` is passed;  with it, `P` is 0, the floors are 0 and the log says so loudly.

`ship-testflight.sh` logs the plan on every run:

```
[ios-ship] version plan: asc_patch=236 -> marketing=1.0.237; build floors: train=0 app=2358 commit_count=2360 -> build=2360
[ios-ship] marketing=1.0.237 build=2360
[ios-ship] App Store Connect will show this as: 1.0.237 (2360)
```

`asc-key.mjs`, the credential block of `asc-api.mjs` and the `load_secrets` layer of `ship-testflight.sh` carry the AFC-459 change:  they are not the canonical copy, so re-copying the canonical `ship-testflight.sh` over this one drops the credential rule.  The same goes for the AFC-517 version scheme:  re-copying the canonical `ship-testflight.sh` or `asc-api.mjs` over these drops it, so re-apply the port from `version-plan.mjs`.

When the canonical copy changes, re-copy the unchanged files and re-apply the three `asc-api.mjs` patches.  Do not set `IOS_TF_MIN_INTERVAL_SEC` or pass `--force-ship` anywhere in the workflow.  Detail:  `docs/rollouts/2026-10-17-ios-auto-ship.md` and `docs/rollouts/2026-10-24-version-scheme.md`.
