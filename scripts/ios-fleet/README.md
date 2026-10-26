# Fleet iOS ship files for Hog Hunter

A copy of the Mac fleet tooling (the `ios-fleet` directory on the fleet Mac) that `.github/workflows/ios-testflight.yml` runs on a hosted macOS runner, through `scripts/ios-ship-testflight.sh`.  The canonical copy is not tracked in a repository, so this directory is the reviewable record.

- `ship-testflight.sh`, `ExportOptions-appstore.plist`, `ExportOptions-export-ipa.plist`:  from the canonical copy, with the AFC-517 version-scheme port applied (see "Version numbering" below).
- `asc-api.mjs`:  canonical copy with three patches, marked `HogHunter vendor patch (HH-157)`:  the What to Test stamp has no timezone abbreviation and uses lower-case am or pm;  the agent-name filter covers more seats and bracketed seat tags;  and a failed export-compliance PATCH in `ensure-tf-ready` still publishes What to Test before it exits 2.  `scripts/test-ios-release.py` runs the renderer.  It also carries the AFC-517 `latest-marketing-patch` and `build-floor` methods, which feed the ship script's version plan.
- `version-plan.mjs`, `version-plan.test.mjs`:  the version-numbering rules as pure, unit-tested functions (HH-191).  `version-plan.mjs` holds no I/O; `ship-testflight.sh` implements the same rules in bash and `asc-api.mjs` imports the module for the App Store Connect queries.  `node --test scripts/ios-fleet/version-plan.test.mjs` runs the suite.
- `version-number.mjs`, `version-number.test.mjs`, `version-number.sh`:  the committed version record and the one number both ship paths take (HH-191).  `version-number.mjs` reads and writes the record in `project.yml` and refuses a checkout with no readable git history;  `version-number.sh` is the thin entry point `ship-testflight.sh` and `scripts/install.sh` both call.  `node --test scripts/ios-fleet/version-number.test.mjs` runs its suite.
- `scheduled-ship-gate.sh`, `test-scheduled-ship-gate.sh`:  from CodeCaps.
- `asc-key.mjs`:  the App Store Connect key module (AFC-459).  It validates a key, stages it for the Apple tools that can only read a key from disk, and never reads a key file:  a path on disk is not an approved credential source, so `ASC_KEY_PATH` is ignored wherever it appears and the key reaches the client in the environment.
- `test-asc-key.test.mjs`, `test-asc-credentials.sh`, `test-asc-credentials.mjs`:  the credential suites (AFC-459).  `test-asc-key.test.mjs` is the module's own test; the other two are the client and shell precedence tests.
- `apps.json`:  the `hoghunter` row only (`xcodegenDir` is `.`).

## Version numbering

Owner directive 2026-10-26 (HH-191), which replaces the 2026-10-24 scheme (AFC-517 / CT-2444) and the `1.0.<commit_count>` scheme unified in #2801 on 2026-10-18.  The rule lives in `version-plan.mjs` (pure) and `version-number.mjs` (the committed record), and is applied in `ship-testflight.sh` and `scripts/install.sh`:

- **One number, and it is a version string.**  `MARKETING_VERSION` (CFBundleShortVersionString) and `CURRENT_PROJECT_VERSION` (CFBundleVersion) carry the **same** string, so App Store Connect renders `0.1.1 (0.1.1)`.  The repository commit count and every timestamp are retired:  there is no second number anywhere.
- The train is `<major>.<minor>`:  `0.1` for Hog Hunter and the other apps not on the App Store (`0.1.0` now, `0.1.1` next), `1.1` for Congress.Trade, whose past numbers already used the `1.0` train (`1.1.2`).
- The number is one past what the train already holds, so a number is never reused.  The train holds the **committed record** (`project.yml`, the version the last update shipped, read by both ship paths) and, for this path, what App Store Connect holds:  the App Store versions and the TestFlight trains, with the retired `1.0.N (N)` "drift trains" ignored.
- `--version X.Y.Z` is an exact marketing override and `--build N` an exact build override.  Without an override the build number **is** the version.
- App Store Connect is the only record that shipping advances, so an unreachable App Store Connect is fatal unless `--allow-unverified-seq` is passed;  with it, the patch is 0, the train state is unverified and the log says so loudly.
- A checkout with no readable git history fails loudly:  there is no timestamp fallback and no guess.

`ship-testflight.sh` logs the plan on every run:

```
[ios-ship] version plan: record=0.1.0 asc_patch=0 -> version=0.1.1; train builds=0 -> build=0.1.1 (one number)
[ios-ship] marketing=0.1.1 build=0.1.1
[ios-ship] App Store Connect will show this as: 0.1.1 (0.1.1)
[ios-ship] agreement: the Mac app takes the next number from the committed record (0.1.0), which is this one
```

`asc-key.mjs`, the credential block of `asc-api.mjs` and the `load_secrets` layer of `ship-testflight.sh` carry the AFC-459 change:  they are not the canonical copy, so re-copying the canonical `ship-testflight.sh` over this one drops the credential rule.  The same goes for the HH-191 version scheme:  re-copying the canonical `ship-testflight.sh` or `asc-api.mjs` over these drops it, so re-apply the port from `version-plan.mjs` and `version-number.mjs`.

When the canonical copy changes, re-copy the unchanged files and re-apply the three `asc-api.mjs` patches.  Do not set `IOS_TF_MIN_INTERVAL_SEC` or pass `--force-ship` anywhere in the workflow.  Detail:  `docs/rollouts/2026-10-17-ios-auto-ship.md` and `docs/rollouts/2026-10-26-version-scheme-one-number.md`.
