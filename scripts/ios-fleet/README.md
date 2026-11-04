# Fleet iOS ship files for Hog Hunter

A copy of the Mac fleet tooling (the `ios-fleet` directory on the fleet Mac) that `.github/workflows/ios-testflight.yml` runs on a hosted macOS runner, through `scripts/ios-ship-testflight.sh`.  The canonical copy is not tracked in a repository, so this directory is the reviewable record.

- `ship-testflight.sh`, `ExportOptions-appstore.plist`, `ExportOptions-export-ipa.plist`:  from the canonical copy, with the AFC-517 version-scheme port applied (see "Version numbering" below).
- `asc-api.mjs`:  canonical copy with three patches, marked `HogHunter vendor patch (HH-157)`:  the What to Test stamp has no timezone abbreviation and uses lower-case am or pm;  the agent-name filter covers more seats and bracketed seat tags;  and a failed export-compliance PATCH in `ensure-tf-ready` still publishes What to Test before it exits 2.  `scripts/test-ios-release.py` runs the renderer.  It also carries the AFC-517 `latest-marketing-patch` and `build-floor` methods, which feed the ship script's version plan.
- `version-plan.mjs`, `version-plan.test.mjs`:  the version-numbering rules as pure, unit-tested functions (AFC-517).  `version-plan.mjs` holds no I/O; `ship-testflight.sh` implements the same rules in bash and `asc-api.mjs` imports the module for the App Store Connect queries.  `node --test scripts/ios-fleet/version-plan.test.mjs` runs the suite.
- `shared-build.mjs`, `shared-build.test.mjs`:  the fixed-mode build planner as a pure, unit-tested function (owner, Oct 29 2026).  One shared merge-timestamp build per release across iOS and macOS:  build = max(S, M + 1), where S is the merge stamp (the merge commit's Chicago date as YYYYMMDDHHMM) and M is the highest first build component across iOS, the paired macOS app and every extra floor.  Every build counts:  expired builds, all version trains, and old timestamp-style builds on either platform.  `asc-api.mjs` imports the module for the `plan-release-build` query, which the CI plan-build job runs once per release (`next-shared-build` is the same query under its earlier name, and `max-platform-build` backs the fixed-mode `--build` check).  `node --test scripts/ios-fleet/shared-build.test.mjs` runs the suite.
- `scheduled-ship-gate.sh`, `test-scheduled-ship-gate.sh`:  from CodeCaps.
- `asc-key.mjs`:  the App Store Connect key module (AFC-459).  It validates a key, stages it for the Apple tools that can only read a key from disk, and never reads a key file:  a path on disk is not an approved credential source, so `ASC_KEY_PATH` is ignored wherever it appears and the key reaches the client in the environment.
- `test-asc-key.test.mjs`, `test-asc-credentials.sh`, `test-asc-credentials.mjs`:  the credential suites (AFC-459).  `test-asc-key.test.mjs` is the module's own test; the other two are the client and shell precedence tests.
- `apps.json`:  the `hoghunter` row only (`xcodegenDir` is `.`).

## Current Hog Hunter Version Policy

HH-205 ports the current fleet policy: marketing version `0.1.0`, with one independent counter starting at `1000` and incrementing complete observed floors.  Earlier accepted larger build numbers remain lower bounds; no timestamp or git count generates the new counter.

The existing serialized Mac publisher calls `../release-build-policy.mjs` with the existing scoped ASC binding, chooses the counter once, and publishes `release-plan.json` beside the signed archive under a unique build-bearing tag.  The iPhone workflow reuses its exact source SHA and counter.  A pending Mac publication starts no archive or upload; a docs-only descendant can reuse the ancestor plan after verifying ancestry and release-relevant changed paths.  Existing release assets are immutable, so a rerun that reaches an already-published tag fails closed instead of replacing them.

The `hoghunter` row sets `buildNumberPolicy` to `paired-release`.  In `ship-testflight.sh`, `asc_next_shared_build` reads that published source plan, and `assert_paired_release_identity` checks actual uploads even when `--build` is explicit.  An explicit export-only preview computes an unused plan without requiring a published Mac release; it never uploads or advances state.  Both workflows keep the existing upload opt-in, rate gate and scoped credential bindings.

Preserve this HH-specific port when refreshing the shared tools: `shared-build.mjs` adds `nextIncrementalBuild`; `ship-testflight.sh` adds the paired-release planner and upload identity check; `apps.json` selects the policy; and the repository-owned `../release-build-policy.mjs` plus its tests implement the manifest contract.  The older `nextSharedBuild`, merge-stamp planner and `version-plan.mjs` remain for legacy vendor compatibility tests; the Hog Hunter workflow does not select them.

`asc-key.mjs`, the credential block of `asc-api.mjs` and the `load_secrets` layer of `ship-testflight.sh` carry the AFC-459 change:  they are not the canonical copy, so re-copying the canonical `ship-testflight.sh` over this one drops the credential rule.  The same goes for the AFC-517 version scheme:  re-copying the canonical `ship-testflight.sh` or `asc-api.mjs` over these drops it, so re-apply the port from `version-plan.mjs`.

When the canonical copy changes, re-copy the unchanged files and re-apply the three `asc-api.mjs` patches.  Do not set `IOS_TF_MIN_INTERVAL_SEC` or pass `--force-ship` anywhere in the workflow.  Detail:  `docs/rollouts/2026-10-17-ios-auto-ship.md` and `docs/rollouts/2026-10-24-version-scheme.md`.

## Tester Policy

Owner ruling, Nov 3 2026:  the iPhone companion has exactly one beta group, a public one whose link is on, and the same people in it.  No internal group.  Every build whose version is not 0.1.0 is deleted or expired, so the group's build list is the 0.1.0 line and nothing else.

apps.json carries the policy per app, and the default keeps the behaviour every other fleet app has:

| Policy | Groups | Who installs the build | How a build reaches them | Tester list |
|---|---|---|---|---|
| internal-group (default) | one internal all-builds group | App Store Connect users | the internal group carries every build | required (ASC_STANDING_TESTERS) |
| public-group | one external group with the public link on | the standing people, through the public link | the build is assigned to the group and submitted for Beta App Review | optional; the group already holds them |

tester-policy.mjs holds the rules as pure functions and tester-policy.test.mjs tests them (node --test scripts/ios-fleet/tester-policy.test.mjs).  asc-api.mjs reads the policy from --policy <name>, a flag that is stripped from the positional arguments before they are read, so an omitted optional argument can never swallow it.

Three consequences are worth naming.  The readiness check counts the testers who can actually install the build under the app's policy:  counting the internal group for a public-policy app reported zero for an app that was set up correctly.  And under the public policy the sync keeps exactly one external group with its public link on:  the group whose link is already on is the one it keeps, because that is the group that distributes the build, and any other external group with its link on has it turned off.  And the exit-5 message names those testers:  it used to say the build may be stuck on export compliance, which sent the reader after the wrong thing, because export compliance is declared in phase B, before the readiness wait, and a build that reached the wait was never stuck on it.

This is a Hog Hunter port:  re-copying the canonical asc-api.mjs or ship-testflight.sh over these drops the policy, so re-apply it from tester-policy.mjs.
