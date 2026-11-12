# Version scheme: the next patch and an independent build number (2026-10-24)

AFC-517, ported from Congress.Trade (CT-2444).  Owner directive 2026-10-24, which replaces the `1.0.<commit_count>` scheme unified in #2801 on 2026-10-18.  Ship tooling only:  no app source, no project file, no workflow change to a ship path.

## What changed

The fleet's version numbering had two numbers that always carried the same value:  the marketing version was `1.0.<commit_count>` and the build number was `<commit_count>`, so App Store Connect rendered `1.0.2358 (2358)`.  The pair read as one number twice, and a real App Store version (`1.0.235`) never moved the next version forward.

The two numbers are now independent:

- `MARKETING_VERSION` (CFBundleShortVersionString) is `<prefix>.<P+1>`.  `<prefix>` is the train from `marketingVersionDefault` (`1.0` here).  `P` is the highest patch App Store Connect already holds on that train, counting **both** the App Store versions (`appStoreVersions.versionString`) and the TestFlight trains (`preReleaseVersions.version`) for the app's platform.  App Store versions are never ignored:  a version that is on sale counts even when no TestFlight train carries it.
- `CURRENT_PROJECT_VERSION` (CFBundleVersion) is the repo commit count, raised when needed so it is strictly greater than every build already in the target train (the retired 12-digit UTC stamps included, because Apple requires build numbers to grow inside one train) and than the app's highest plain-integer build below 1000000000 on that platform.  On macOS every build counts, because macOS build numbers have to grow across all trains.

A TestFlight train that holds a build named after its own patch (a `1.0.N` train holding build `N`) is a **drift train**:  those are the `1.0.2358 (2358)` uploads the retired scheme produced, and they are ignored when `P` is computed, so they no longer push the version forward.

The one coupling left is a safety rule:  a ship must never look like `1.0.N (N)`, so a build number that happens to equal the patch number moves one up.

`--version X.Y.Z` is an exact marketing override and `--build N` is an exact build override.  `--build` does not move the marketing version any more;  `--version` on its own still leaves the build automatic (the commit count, floored against that train).

An unreachable App Store Connect is fatal:  it is the only record that says which patches the train holds and which build numbers are taken, and guessing either one ships a version that already exists or a build number that is rejected as a duplicate.  `--allow-unverified-seq` still overrides that, and then `P` is 0, the floors are 0, and the log says so loudly.

## Where it lives

- `scripts/ios-fleet/version-plan.mjs` is the rule as pure functions (no I/O, no network, no environment), with `scripts/ios-fleet/version-plan.test.mjs` as its unit suite.  The bash ship script implements the same rules, and `scripts/ios-fleet/asc-api.mjs` imports the module for the App Store Connect queries.
- `scripts/ios-fleet/asc-api.mjs` gained two methods:  `latest-marketing-patch <bundleId> <prefix> [platform]` and `build-floor <bundleId> <version> [platform]`.  The first answers "the highest patch already used on this train";  the second answers "the build number the next ship has to exceed", split into the train floor and the app floor.  `latest-build-seq` is untouched.
- `scripts/ios-fleet/ship-testflight.sh` asks those two questions and resolves the version from them.  The old `resolve_seq_floor` / `local_seq` / `next_build_seq` paths are gone:  the local build-seq counter was already retired, and `project.pbxproj` is no longer a sequencing input (it is only read for the agreement NOTICE).  `ASC_NODE` (default `node`) is the seam that runs the client, so an offline test can answer the App Store Connect queries from a stub.
- Every run prints the plan it worked from:

  ```
  [ios-ship] version plan: asc_patch=236 -> marketing=1.0.237; build floors: train=0 app=2358 commit_count=2360 -> build=2360
  [ios-ship] marketing=1.0.237 build=2360
  [ios-ship] App Store Connect will show this as: 1.0.237 (2360)
  ```

## What did not change

- `--upload-only` still resolves no version of its own:  the IPA already carries one, and the run neither consults nor consumes anything.
- The ship gate still runs **before** any version is resolved, so a rate-limited or same-HEAD run consumes nothing.  The gate ordering and the rate limit are untouched.
- The credential layer (AFC-459) is untouched.  The version queries do not stage a key file:  the client resolves the credential itself from the environment or Infisical, so a read-only query leaves no key material on disk.

## Tests

`node --test scripts/ios-fleet/version-plan.test.mjs` runs in CI (`.github/workflows/ci.yml`, the `release-safety` job).  The suite is pure:  no network, no credentials, no App Store Connect.

## Not touched

The iOS native tree, `project.yml`, the `.xcodeproj`, and every `*ship*.yml` / `*testflight*.yml` / `*release*.yml` workflow are unchanged;  editing a ship workflow triggers a real ship.  `.github/workflows/ios-testflight.yml` still carries the old scheme in its header comment and needs the same wording change in a change that can afford to touch a ship workflow.
